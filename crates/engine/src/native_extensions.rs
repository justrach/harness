//! Bounded native panel transport. Project ownership is checked by the RPC host.
use crate::EngineError;
use serde::Deserialize;
use serde_json::Value;
use std::{
    path::{Path, PathBuf},
    time::Duration,
};

const MAX_PANELS: usize = 16;
const MAX_BUILTIN_STDOUT: usize = 64 * 1024;
const GITHUB_RUNNERS_ID: &str = "github-runners";

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Params {
    pub space_id: String,
    pub plugin: Option<String>,
    pub action: Option<String>,
}

pub fn parse(stdout: &[u8], action: bool) -> Result<Value, EngineError> {
    if stdout.len() > 256 * 1024 {
        return Err(EngineError::Other(
            "Native extension response is too large".into(),
        ));
    }
    let value: Value = serde_json::from_slice(stdout)
        .map_err(|_| EngineError::Other("Update graff to use native extension panels".into()))?;
    if value.get("version").and_then(Value::as_u64) != Some(1)
        || (!action
            && value
                .get("panels")
                .and_then(Value::as_array)
                .is_none_or(|p| p.len() > MAX_PANELS))
    {
        return Err(EngineError::Other(
            "Unsupported native extension response".into(),
        ));
    }
    Ok(value)
}

fn valid_id(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('-')
        && s.len() <= 64
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
}

fn invalid_panel() -> EngineError {
    EngineError::Other("Invalid native extension panel".into())
}

pub fn validate_panel(panel: &Value) -> Result<(), EngineError> {
    let obj = panel.as_object().ok_or_else(invalid_panel)?;
    let title = obj
        .get("title")
        .and_then(Value::as_str)
        .ok_or_else(invalid_panel)?;
    if title.is_empty() || title.len() > 120 {
        return Err(invalid_panel());
    }
    let root = obj.get("root").ok_or_else(invalid_panel)?;
    let mut count = 0usize;
    let mut bytes = title.len();
    validate_node(root, 0, &mut count, &mut bytes)
}

fn validate_node(
    node: &Value,
    depth: usize,
    count: &mut usize,
    bytes: &mut usize,
) -> Result<(), EngineError> {
    *count += 1;
    let obj = node.as_object().ok_or_else(invalid_panel)?;
    if depth > 8 || *count > 64 {
        return Err(invalid_panel());
    }
    let kind = obj
        .get("kind")
        .and_then(Value::as_str)
        .ok_or_else(invalid_panel)?;
    match kind {
        "column" | "row" => {
            let children = obj
                .get("children")
                .and_then(Value::as_array)
                .ok_or_else(invalid_panel)?;
            for child in children {
                validate_node(child, depth + 1, count, bytes)?;
            }
        }
        "text" => {
            let text = obj
                .get("text")
                .and_then(Value::as_str)
                .ok_or_else(invalid_panel)?;
            *bytes = bytes.saturating_add(text.len());
        }
        "stat" => {
            let label = obj
                .get("label")
                .and_then(Value::as_str)
                .ok_or_else(invalid_panel)?;
            let value = obj
                .get("value")
                .and_then(Value::as_str)
                .ok_or_else(invalid_panel)?;
            *bytes = bytes
                .saturating_add(label.len())
                .saturating_add(value.len());
        }
        "button" => {
            let label = obj
                .get("label")
                .and_then(Value::as_str)
                .ok_or_else(invalid_panel)?;
            let action = obj
                .get("action")
                .and_then(Value::as_str)
                .ok_or_else(invalid_panel)?;
            if !valid_id(action) {
                return Err(invalid_panel());
            }
            *bytes = bytes.saturating_add(label.len());
        }
        _ => return Err(invalid_panel()),
    }
    if *bytes > 8192 {
        return Err(invalid_panel());
    }
    Ok(())
}

pub fn panel_declares_action(node: &Value, target: &str) -> bool {
    let Some(obj) = node.as_object() else {
        return false;
    };
    if obj.get("kind").and_then(Value::as_str) == Some("button")
        && obj.get("action").and_then(Value::as_str) == Some(target)
    {
        return true;
    }
    obj.get("children")
        .and_then(Value::as_array)
        .is_some_and(|children| {
            children
                .iter()
                .any(|child| panel_declares_action(child, target))
        })
}

pub fn merge_panels(target: &mut Vec<Value>, extra: &[Value]) {
    for panel in extra {
        if target.len() >= MAX_PANELS {
            break;
        }
        let Some(id) = panel.get("plugin").and_then(Value::as_str) else {
            continue;
        };
        if id.is_empty()
            || target
                .iter()
                .any(|existing| existing.get("plugin").and_then(Value::as_str) == Some(id))
        {
            continue;
        }
        target.push(panel.clone());
    }
}

pub fn has_local_github_runners(home: &Path) -> bool {
    home.join(".github-runners/harness-1/.runner").is_file()
        || home.join(".github-runners/harness-2/.runner").is_file()
}

pub fn resolve_github_runners_bin_from(home: &Path, current_exe: Option<&Path>) -> Option<PathBuf> {
    if let Some(exe) = current_exe {
        let exe = exe.canonicalize().unwrap_or_else(|_| exe.to_path_buf());
        if let Some(bundled) = exe
            .parent()
            .and_then(Path::parent)
            .map(|c| c.join("Resources/bin/harness-github-runners"))
            .filter(|p| p.is_file())
        {
            return Some(bundled);
        }
        if let Some(sibling) = exe
            .parent()
            .map(|d| d.join("harness-github-runners"))
            .filter(|p| p.is_file())
        {
            return Some(sibling);
        }
    }
    let fallback = home.join(".github-runners/bin/harness-github-runners");
    fallback.is_file().then_some(fallback)
}

async fn run_graff(
    home: &Path,
    dir: &Path,
    plugin: Option<&str>,
    action: Option<&str>,
) -> Result<Value, EngineError> {
    let mut command = harness_adapters::graff_extensions_command(dir, plugin, action).await?;
    command
        .stdin(harness_adapters::process::Stdio::null())
        .kill_on_drop(true);
    #[cfg(unix)]
    command.env("HOME", home);
    #[cfg(not(unix))]
    let _ = home;
    // Up to sixteen explicitly trusted callbacks, each capped at ten seconds.
    let output = tokio::time::timeout(Duration::from_secs(180), command.output())
        .await
        .map_err(|_| EngineError::Other("Native extension request timed out".into()))??;
    if !output.status.success() {
        return Err(EngineError::Other(
            "Native extension failed; check its trusted configuration and hard policies".into(),
        ));
    }
    parse(&output.stdout, action.is_some())
}

async fn run_builtin_binary(
    home: &Path,
    bin: &Path,
    event: &str,
    data: Value,
) -> Result<Value, EngineError> {
    let envelope = serde_json::json!({
        "version": 1,
        "plugin": GITHUB_RUNNERS_ID,
        "event": event,
        "data": data,
    })
    .to_string();
    let mut command = harness_adapters::process::Command::new(bin);
    command
        .arg(envelope)
        .stdin(harness_adapters::process::Stdio::null())
        .kill_on_drop(true)
        .env("NO_COLOR", "1");
    #[cfg(unix)]
    command.env("HOME", home);
    #[cfg(not(unix))]
    let _ = home;
    let output = tokio::time::timeout(Duration::from_secs(15), command.output())
        .await
        .map_err(|_| EngineError::Other("Native extension request timed out".into()))??;
    if !output.status.success() {
        return Err(EngineError::Other(
            "Native extension failed; check its trusted configuration and hard policies".into(),
        ));
    }
    if output.stdout.len() > MAX_BUILTIN_STDOUT {
        return Err(EngineError::Other(
            "Native extension response is too large".into(),
        ));
    }
    let value: Value = serde_json::from_slice(&output.stdout)
        .map_err(|_| EngineError::Other("Unsupported native extension response".into()))?;
    if value.get("version").and_then(Value::as_u64) != Some(1) {
        return Err(EngineError::Other(
            "Unsupported native extension response".into(),
        ));
    }
    Ok(value)
}

pub async fn append_builtin_github_runners(home: &Path, bin: &Path, panels: &mut Vec<Value>) {
    if panels.len() >= MAX_PANELS
        || panels
            .iter()
            .any(|p| p.get("plugin").and_then(Value::as_str) == Some(GITHUB_RUNNERS_ID))
        || !has_local_github_runners(home)
    {
        return;
    }
    let Ok(resp) = run_builtin_binary(home, bin, "ui", Value::Null).await else {
        return;
    };
    let Some(panel) = resp.get("panel") else {
        return;
    };
    if validate_panel(panel).is_err() {
        return;
    }
    let Some(mut obj) = panel.as_object().cloned() else {
        return;
    };
    obj.insert("plugin".into(), Value::String(GITHUB_RUNNERS_ID.into()));
    panels.push(Value::Object(obj));
}

pub async fn invoke_builtin_github_runners(
    home: &Path,
    bin: &Path,
    action: &str,
) -> Result<Value, EngineError> {
    if !valid_id(action) || !has_local_github_runners(home) {
        return Err(EngineError::Other("Invalid native extension action".into()));
    }
    let ui_resp = run_builtin_binary(home, bin, "ui", Value::Null).await?;
    let panel = ui_resp.get("panel").ok_or_else(invalid_panel)?;
    validate_panel(panel)?;
    if !panel_declares_action(&panel["root"], action) {
        return Err(EngineError::Other("Invalid native extension action".into()));
    }
    let resp =
        run_builtin_binary(home, bin, "action", serde_json::json!({ "action": action })).await?;
    if let Some(updated) = resp.get("panel").filter(|p| !p.is_null()) {
        validate_panel(updated)?;
    }
    Ok(resp)
}

pub async fn run(
    home: &Path,
    cwd: &Path,
    plugin: Option<&str>,
    action: Option<&str>,
) -> Result<Value, EngineError> {
    let has_home_cfg = home != cwd && home.join(".harness").join("settings.json").is_file();
    match (plugin, action) {
        (None, None) => {
            let mut base = run_graff(home, cwd, None, None).await?;
            if has_home_cfg
                && let Ok(home_val) = run_graff(home, home, None, None).await
                && let (Some(target), Some(extra)) = (
                    base.get_mut("panels").and_then(Value::as_array_mut),
                    home_val.get("panels").and_then(Value::as_array),
                )
            {
                merge_panels(target, extra);
            }
            #[cfg(target_os = "macos")]
            if let Some(bin) =
                resolve_github_runners_bin_from(home, std::env::current_exe().ok().as_deref())
                && let Some(target) = base.get_mut("panels").and_then(Value::as_array_mut)
            {
                append_builtin_github_runners(home, &bin, target).await;
            }
            Ok(base)
        }
        (Some(plugin_id), Some(act)) => {
            let cwd_err = match run_graff(home, cwd, Some(plugin_id), Some(act)).await {
                Ok(val) => return Ok(val),
                Err(err) => err,
            };
            if has_home_cfg && let Ok(val) = run_graff(home, home, Some(plugin_id), Some(act)).await
            {
                return Ok(val);
            }
            #[cfg(target_os = "macos")]
            if plugin_id == GITHUB_RUNNERS_ID
                && let Some(bin) =
                    resolve_github_runners_bin_from(home, std::env::current_exe().ok().as_deref())
                && has_local_github_runners(home)
            {
                return invoke_builtin_github_runners(home, &bin, act).await;
            }
            Err(cwd_err)
        }
        _ => run_graff(home, cwd, plugin, action).await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_extension_protocol_rejects_old_or_unbounded_replies() {
        assert!(parse(br#"{"version":1,"panels":[]}"#, false).is_ok());
        assert!(parse(br#"{"version":1,"panel":{"title":"Synthetic"}}"#, true).is_ok());
        assert!(parse(b"usage", false).is_err());
        assert!(parse(br#"{"version":2,"panels":[]}"#, false).is_err());
        assert!(parse(br#"{"version":1}"#, false).is_err());
        assert!(parse(&vec![b' '; 256 * 1024 + 1], false).is_err());
    }

    #[test]
    fn merges_home_panels_without_duplicating_project_ids() {
        let mut target = vec![serde_json::json!({
            "plugin": "checks",
            "title": "Project Checks",
            "root": { "kind": "text", "text": "project" }
        })];
        let extra = vec![
            serde_json::json!({
                "plugin": "checks",
                "title": "Home Checks",
                "root": { "kind": "text", "text": "home" }
            }),
            serde_json::json!({
                "plugin": "github-runners",
                "title": "Runners",
                "root": { "kind": "text", "text": "online" }
            }),
        ];
        merge_panels(&mut target, &extra);
        assert_eq!(target.len(), 2);
        assert_eq!(target[0]["title"], "Project Checks");
        assert_eq!(target[1]["plugin"], "github-runners");
    }

    #[test]
    fn resolves_bundled_and_fallback_github_runners_binary() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();

        let fallback = home.join(".github-runners/bin/harness-github-runners");
        std::fs::create_dir_all(fallback.parent().unwrap()).unwrap();
        std::fs::write(&fallback, b"").unwrap();
        let exe = home.join("App.app/Contents/MacOS/harness");
        std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
        std::fs::write(&exe, b"").unwrap();

        let resolved_fb = resolve_github_runners_bin_from(home, Some(&exe)).unwrap();
        assert_eq!(
            resolved_fb,
            home.join(".github-runners/bin/harness-github-runners")
        );

        let sibling = home.join("App.app/Contents/MacOS/harness-github-runners");
        std::fs::write(&sibling, b"").unwrap();
        let resolved_sib = resolve_github_runners_bin_from(home, Some(&exe)).unwrap();
        assert_eq!(resolved_sib.file_name().unwrap(), "harness-github-runners");
        assert!(resolved_sib.ends_with("Contents/MacOS/harness-github-runners"));

        let bundled = home.join("App.app/Contents/Resources/bin/harness-github-runners");
        std::fs::create_dir_all(bundled.parent().unwrap()).unwrap();
        std::fs::write(&bundled, b"").unwrap();
        let resolved_bnd = resolve_github_runners_bin_from(home, Some(&exe)).unwrap();
        assert!(resolved_bnd.ends_with("Contents/Resources/bin/harness-github-runners"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn builtin_github_runners_lists_and_enforces_declared_actions() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();
        let runner = home.join(".github-runners/harness-1/.runner");
        std::fs::create_dir_all(runner.parent().unwrap()).unwrap();
        std::fs::write(&runner, b"{}").unwrap();

        let bin = home.join("mock-github-runners");
        std::fs::write(
            &bin,
            r#"#!/bin/sh
case "$1" in
  *'"event":"ui"'*)
    printf '%s\n' '{"version":1,"panel":{"title":"Synthetic Runners","root":{"kind":"column","children":[{"kind":"stat","label":"Online","value":"2 / 2"},{"kind":"button","label":"Refresh","action":"refresh"}]}}}'
    ;;
  *'"action":"refresh"'*)
    printf '%s\n' '{"version":1,"panel":{"title":"Synthetic Runners","root":{"kind":"text","text":"refreshed"}}}'
    ;;
  *)
    exit 1
    ;;
esac
"#,
        )
        .unwrap();
        let mut perms = std::fs::metadata(&bin).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&bin, perms).unwrap();

        let mut panels = Vec::new();
        append_builtin_github_runners(home, &bin, &mut panels).await;
        assert_eq!(panels.len(), 1);
        assert_eq!(panels[0]["plugin"], "github-runners");
        assert_eq!(panels[0]["title"], "Synthetic Runners");

        // Idempotent when plugin already present.
        append_builtin_github_runners(home, &bin, &mut panels).await;
        assert_eq!(panels.len(), 1);

        let ok = invoke_builtin_github_runners(home, &bin, "refresh")
            .await
            .unwrap();
        assert_eq!(ok["panel"]["root"]["text"], "refreshed");

        let denied = invoke_builtin_github_runners(home, &bin, "shell").await;
        assert!(denied.is_err());
    }
}
