//! graff's MCP servers, edited from Settings → MCP.
//!
//! graff reads two files and Harness runs it with `--yolo`, so every server
//! in them connects in Harness's graff chats: the user-level
//! `~/.codegraff/mcp.json` (or `$GRAFF_MCP_CONFIG`) and a project's
//! `<project>/.mcp.json`, project entries winning on a name clash. Both use
//! `{"mcpServers": {name: {command, args, env} | {url, headers}}}`. This
//! module edits those same files on the computer that runs graff, so `graff
//! mcp list`, a terminal session, and Harness all see one configuration.
//! Running graff sessions pick up added servers on their own; a removed or
//! disabled one leaves with the next chat.
//!
//! graff has no per-server off switch, so a disabled server moves to a
//! sibling `disabledMcpServers` object in the same file: graff ignores it,
//! and enabling moves it back unchanged. Every other key in the file, and
//! its order, is kept.
//!
//! graff also connects servers it imports from other tools' configs for names
//! its own files leave undefined. Only graff knows that merge, so a listing
//! asks it (`graff mcp list --json`, run in the project) and shows those as
//! `imported`: read-only here, and switched off by naming them (`{}`) in the
//! global off-list, which graff honors for imported names too. An older graff
//! without `--json` leaves them out and the listing says so.
//!
//! Env and header VALUES never leave this computer (they are often tokens):
//! listings carry their names only, and an edit that leaves a value out keeps
//! the stored one.

use std::path::{Path, PathBuf};

use indexmap::IndexMap;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// One server's fields, in the file's order.
type Entry = IndexMap<String, Value>;
/// `mcpServers` / `disabledMcpServers`: servers in the file's order.
type Table = IndexMap<String, Entry>;

/// A top-level value. Ordered maps keep a hand-written file's layout when a
/// save touches one server (serde_json's own map sorts keys here).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
enum Node {
    Table(Table),
    Other(Value),
}

type Root = IndexMap<String, Node>;

const SERVERS: &str = "mcpServers";
const DISABLED: &str = "disabledMcpServers";
const GLOBAL_REL: &str = ".codegraff/mcp.json";
const GLOBAL_ENV: &str = "GRAFF_MCP_CONFIG";
const PROJECT_FILE: &str = ".mcp.json";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum McpScope {
    /// Every project on this computer.
    Global,
    /// One project's `.mcp.json`.
    Project,
    /// Another tool's config that graff reads (Claude, Cursor, plugins, …).
    Imported,
}

/// One server as listed: no secret values.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpServerView {
    pub name: String,
    pub scope: McpScope,
    pub enabled: bool,
    /// A project entry that hides a global one of the same name.
    pub overrides_global: bool,
    pub command: Option<String>,
    pub args: Vec<String>,
    pub url: Option<String>,
    /// Names of the env vars (stdio) or headers (http) it sets.
    pub env_keys: Vec<String>,
    pub header_keys: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpListing {
    pub global_path: String,
    pub project_path: Option<String>,
    /// A file that exists but is not `{"mcpServers": {...}}`; its servers are
    /// not listed and it is never rewritten.
    pub invalid_global: bool,
    pub invalid_project: bool,
    /// Why imported servers are missing from `servers`, when graff could not
    /// list them (not found, or too old for `mcp list --json`).
    #[serde(default)]
    pub imported_note: Option<String>,
    pub servers: Vec<McpServerView>,
}

/// An add or an edit. `env`/`headers` values of `None` keep the stored value.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpServerEdit {
    pub name: String,
    #[serde(default)]
    pub command: Option<String>,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub env: Map<String, Value>,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub headers: Map<String, Value>,
    /// The name it had, when an edit renames it.
    #[serde(default)]
    pub previous_name: Option<String>,
}

pub fn global_path() -> Result<PathBuf, String> {
    if let Some(over) = std::env::var_os(GLOBAL_ENV).map(PathBuf::from)
        && over.is_absolute()
    {
        return Ok(over);
    }
    let home = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .ok_or("no home directory")?;
    Ok(PathBuf::from(home).join(GLOBAL_REL))
}

fn project_path(cwd: &str) -> Result<PathBuf, String> {
    let dir = Path::new(cwd);
    if !dir.is_absolute() || !dir.is_dir() {
        return Err(format!("not a project folder on this computer: {cwd}"));
    }
    Ok(dir.join(PROJECT_FILE))
}

fn path_for(scope: McpScope, cwd: Option<&str>) -> Result<PathBuf, String> {
    match scope {
        // An imported server is switched off in the global off-list.
        McpScope::Global | McpScope::Imported => global_path(),
        McpScope::Project => project_path(cwd.ok_or("a project server needs its folder")?),
    }
}

/// The file's root object: `Ok(None)` when absent, `Err` when unusable.
fn read_root(path: &Path) -> Result<Option<Root>, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("reading {}: {e}", path.display())),
    };
    let tables_ok = |root: &Root| {
        [SERVERS, DISABLED]
            .iter()
            .all(|k| !matches!(root.get(*k), Some(Node::Other(_))))
    };
    match serde_json::from_str::<Root>(&text) {
        Ok(root) if tables_ok(&root) => Ok(Some(root)),
        _ => Err(format!(
            "{} isn't an MCP config ({{\"mcpServers\": {{…}}}}); fix it by hand first",
            path.display()
        )),
    }
}

fn write_root(path: &Path, root: &Root) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("creating {}: {e}", dir.display()))?;
    }
    let mut text = serde_json::to_string_pretty(root).map_err(|e| e.to_string())?;
    text.push('\n');
    // Write then rename, so a crash never leaves graff a half-written config.
    let tmp = path.with_extension(format!("json.{}.tmp", std::process::id()));
    std::fs::write(&tmp, text).map_err(|e| format!("writing {}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("saving {}: {e}", path.display())
    })
}

fn table<'a>(root: &'a mut Root, key: &str) -> &'a mut Table {
    let slot = root
        .entry(key.to_string())
        .or_insert_with(|| Node::Table(Table::new()));
    if let Node::Other(_) = slot {
        // read_root refuses a file whose tables are not objects.
        *slot = Node::Table(Table::new());
    }
    match slot {
        Node::Table(table) => table,
        Node::Other(_) => unreachable!(),
    }
}

fn table_ref<'a>(root: &'a Root, key: &str) -> Option<&'a Table> {
    match root.get(key) {
        Some(Node::Table(table)) => Some(table),
        _ => None,
    }
}

fn view(name: &str, entry: &Entry, scope: McpScope, enabled: bool) -> McpServerView {
    let str_of = |key: &str| entry.get(key).and_then(Value::as_str).map(str::to_string);
    let keys_of = |key: &str| {
        entry
            .get(key)
            .and_then(Value::as_object)
            .map(|m| m.keys().cloned().collect())
            .unwrap_or_default()
    };
    McpServerView {
        name: name.to_string(),
        scope,
        enabled,
        overrides_global: false,
        command: str_of("command"),
        args: entry
            .get("args")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default(),
        url: str_of("url"),
        env_keys: keys_of("env"),
        header_keys: keys_of("headers"),
    }
}

fn views(root: &Root, scope: McpScope) -> Vec<McpServerView> {
    let mut out = Vec::new();
    for (key, enabled) in [(SERVERS, true), (DISABLED, false)] {
        if let Some(servers) = table_ref(root, key) {
            out.extend(
                servers
                    .iter()
                    // A bare `{}` off-list entry names an imported server.
                    .filter(|(_, entry)| enabled || !entry.is_empty())
                    .map(|(name, entry)| view(name, entry, scope, enabled)),
            );
        }
    }
    out
}

/// graff's own merged listing (`graff mcp list --json` in `dir`): its imported
/// servers, or why they could not be read.
fn imported_from_graff(graff: Option<&Path>, dir: &Path) -> Result<Vec<McpServerView>, String> {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct GraffServer {
        name: String,
        source: String,
        enabled: bool,
        command: Option<String>,
        #[serde(default)]
        args: Vec<String>,
        url: Option<String>,
        #[serde(default)]
        env_keys: Vec<String>,
        #[serde(default)]
        header_keys: Vec<String>,
    }
    #[derive(Deserialize)]
    struct GraffListing {
        servers: Vec<GraffServer>,
    }
    let graff = graff.ok_or("graff isn't installed on this computer")?;
    let output = run_with_timeout(
        std::process::Command::new(graff)
            .args(["mcp", "list", "--json"])
            .current_dir(dir),
        std::time::Duration::from_secs(20),
    )?;
    let listing: GraffListing = serde_json::from_slice(&output).map_err(|_| {
        "update graff (graff update) to see the servers it imports from other tools".to_string()
    })?;
    Ok(listing
        .servers
        .into_iter()
        .filter(|s| s.source == "imported")
        .map(|s| McpServerView {
            name: s.name,
            scope: McpScope::Imported,
            enabled: s.enabled,
            overrides_global: false,
            command: s.command,
            args: s.args,
            url: s.url,
            env_keys: s.env_keys,
            header_keys: s.header_keys,
        })
        .collect())
}

/// stdout of `cmd`, or an error once it fails or outlives `timeout`.
fn run_with_timeout(
    cmd: &mut std::process::Command,
    timeout: std::time::Duration,
) -> Result<Vec<u8>, String> {
    use std::io::Read;
    let mut child = cmd
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("running graff: {e}"))?;
    let mut stdout = child.stdout.take().expect("piped");
    let reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stdout.read_to_end(&mut buf);
        buf
    });
    let deadline = std::time::Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("graff didn't answer in time".into());
            }
        }
    }
    reader
        .join()
        .map_err(|_| "reading graff's output".to_string())
}

/// Global servers, then (when `cwd` names a project) that project's, then the
/// ones graff imports from other tools (`graff` is its binary, when found).
pub fn list(cwd: Option<&str>, graff: Option<&Path>) -> Result<McpListing, String> {
    let mut listing = list_files(cwd)?;
    let dir = match cwd {
        Some(cwd) => PathBuf::from(cwd),
        // No project: graff reads only user-level configs from home.
        None => std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir),
    };
    match imported_from_graff(graff, &dir) {
        Ok(imported) => listing.servers.extend(imported),
        Err(note) => listing.imported_note = Some(note),
    }
    Ok(listing)
}

/// The two graff files alone.
fn list_files(cwd: Option<&str>) -> Result<McpListing, String> {
    let global = global_path()?;
    let (global_servers, invalid_global) = match read_root(&global) {
        Ok(root) => (
            root.map(|r| views(&r, McpScope::Global))
                .unwrap_or_default(),
            false,
        ),
        Err(_) => (Vec::new(), true),
    };
    let project = cwd.map(project_path).transpose()?;
    let (mut project_servers, invalid_project) = match project.as_deref().map(read_root) {
        None => (Vec::new(), false),
        Some(Ok(root)) => (
            root.map(|r| views(&r, McpScope::Project))
                .unwrap_or_default(),
            false,
        ),
        Some(Err(_)) => (Vec::new(), true),
    };
    for server in &mut project_servers {
        server.overrides_global = server.enabled
            && global_servers
                .iter()
                .any(|g| g.enabled && g.name == server.name);
    }
    let mut servers = global_servers;
    servers.extend(project_servers);
    Ok(McpListing {
        global_path: global.display().to_string(),
        project_path: project.map(|p| p.display().to_string()),
        invalid_global,
        invalid_project,
        imported_note: None,
        servers,
    })
}

fn check_name(name: &str) -> Result<(), String> {
    let ok = !name.is_empty()
        && name.len() <= 64
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'));
    ok.then_some(())
        .ok_or_else(|| "a server name uses letters, digits, '-', '_' or '.' (up to 64)".into())
}

/// Where a server lives in `root`: its table key, if any.
fn locate(root: &Root, name: &str) -> Option<&'static str> {
    [SERVERS, DISABLED]
        .into_iter()
        .find(|key| table_ref(root, key).is_some_and(|t| t.contains_key(name)))
}

/// Merge `edits` over `stored`: a string sets the value, null keeps the
/// stored one (dropped if there is none), and names left out are removed.
fn merge_secrets(
    stored: Option<&Value>,
    edits: &Map<String, Value>,
) -> Result<Map<String, Value>, String> {
    let stored = stored.and_then(Value::as_object);
    let mut out = Map::new();
    for (key, value) in edits {
        if key.is_empty() {
            return Err("an env var or header needs a name".into());
        }
        match value {
            Value::String(_) => {
                out.insert(key.clone(), value.clone());
            }
            Value::Null => {
                if let Some(kept) = stored.and_then(|s| s.get(key)) {
                    out.insert(key.clone(), kept.clone());
                }
            }
            _ => return Err(format!("{key}: a value is text")),
        }
    }
    Ok(out)
}

/// Add a server, or replace one (renaming it when `previous_name` differs).
/// It keeps its enabled state; a new one is enabled.
pub fn upsert(scope: McpScope, cwd: Option<&str>, edit: McpServerEdit) -> Result<(), String> {
    refuse_imported(scope)?;
    check_name(&edit.name)?;
    let path = path_for(scope, cwd)?;
    let mut root = read_root(&path)?.unwrap_or_default();
    let old_name = edit.previous_name.as_deref().unwrap_or(&edit.name);
    let old_table = locate(&root, old_name);
    if old_name != edit.name && locate(&root, &edit.name).is_some() {
        return Err(format!(
            "{} already has a server named {}",
            path.display(),
            edit.name
        ));
    }
    let old_entry = old_table.and_then(|t| table(&mut root, t).shift_remove(old_name));

    let command = edit
        .command
        .as_deref()
        .map(str::trim)
        .filter(|c| !c.is_empty());
    let url = edit.url.as_deref().map(str::trim).filter(|u| !u.is_empty());
    let mut entry = Entry::new();
    match (command, url) {
        (Some(command), None) => {
            entry.insert("command".into(), command.into());
            entry.insert(
                "args".into(),
                edit.args.iter().map(|a| Value::from(a.as_str())).collect(),
            );
            let env = merge_secrets(old_entry.as_ref().and_then(|e| e.get("env")), &edit.env)?;
            if !env.is_empty() {
                entry.insert("env".into(), Value::Object(env));
            }
        }
        (None, Some(url)) => {
            if !(url.starts_with("http://") || url.starts_with("https://")) {
                return Err("a server URL starts with http:// or https://".into());
            }
            entry.insert("url".into(), url.into());
            let headers = merge_secrets(
                old_entry.as_ref().and_then(|e| e.get("headers")),
                &edit.headers,
            )?;
            if !headers.is_empty() {
                entry.insert("headers".into(), Value::Object(headers));
            }
        }
        _ => return Err("a server runs a command or connects to a URL (one of them)".into()),
    }
    table(&mut root, old_table.unwrap_or(SERVERS)).insert(edit.name, entry);
    write_root(&path, &root)
}

fn refuse_imported(scope: McpScope) -> Result<(), String> {
    if scope == McpScope::Imported {
        return Err("an imported server is edited in the tool whose config defines it".into());
    }
    Ok(())
}

pub fn remove(scope: McpScope, cwd: Option<&str>, name: &str) -> Result<(), String> {
    refuse_imported(scope)?;
    let path = path_for(scope, cwd)?;
    let Some(mut root) = read_root(&path)? else {
        return Ok(());
    };
    if let Some(from) = locate(&root, name) {
        table(&mut root, from).shift_remove(name);
        if table(&mut root, DISABLED).is_empty() {
            root.shift_remove(DISABLED);
        }
        write_root(&path, &root)?;
    }
    Ok(())
}

pub fn set_enabled(
    scope: McpScope,
    cwd: Option<&str>,
    name: &str,
    enabled: bool,
) -> Result<(), String> {
    let path = path_for(scope, cwd)?;
    let mut root = read_root(&path)?.unwrap_or_default();
    if scope == McpScope::Imported {
        // Off = named in the global off-list; on = not named there.
        check_name(name)?;
        let off = table(&mut root, DISABLED);
        if enabled {
            if off.get(name).is_some_and(|e| e.is_empty()) {
                off.shift_remove(name);
            }
        } else {
            off.entry(name.to_string()).or_default();
        }
    } else {
        let (from, to) = if enabled {
            (DISABLED, SERVERS)
        } else {
            (SERVERS, DISABLED)
        };
        let Some(entry) = table(&mut root, from).shift_remove(name) else {
            // Already in the asked-for state (or gone): nothing to write.
            return if locate(&root, name).is_some() {
                Ok(())
            } else {
                Err(format!("no server named {name}"))
            };
        };
        table(&mut root, to).insert(name.to_string(), entry);
    }
    if table(&mut root, DISABLED).is_empty() {
        root.shift_remove(DISABLED);
    }
    write_root(&path, &root)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// Tests that point `GRAFF_MCP_CONFIG` somewhere take this first: the
    /// environment is process-wide and tests run in parallel.
    static ENV: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn with_global<T>(file: &Path, body: impl FnOnce() -> T) -> T {
        let _guard = ENV
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        // SAFETY: serialized by ENV; nothing else in this crate reads it.
        unsafe { std::env::set_var(GLOBAL_ENV, file) };
        let out = body();
        unsafe { std::env::remove_var(GLOBAL_ENV) };
        out
    }

    fn edit(value: Value) -> McpServerEdit {
        serde_json::from_value(value).unwrap()
    }

    fn project() -> (tempfile::TempDir, String) {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path().display().to_string();
        (dir, cwd)
    }

    fn file(cwd: &str) -> Value {
        serde_json::from_str(&std::fs::read_to_string(Path::new(cwd).join(PROJECT_FILE)).unwrap())
            .unwrap()
    }

    #[test]
    fn add_edit_disable_enable_remove_round_trip_keeps_other_keys() {
        let (_dir, cwd) = project();
        std::fs::write(
            Path::new(&cwd).join(PROJECT_FILE),
            r#"{"note":"mine","mcpServers":{"keep":{"command":"/bin/keep"}}}"#,
        )
        .unwrap();
        let dir = cwd.clone();
        let cwd = Some(cwd.as_str());
        upsert(
            McpScope::Project,
            cwd,
            edit(json!({
                "name": "files", "command": "/bin/files", "args": ["--root", "."],
                "env": {"TOKEN": "secret"}
            })),
        )
        .unwrap();
        let listed = list_files(cwd).unwrap();
        let files = listed.servers.iter().find(|s| s.name == "files").unwrap();
        assert_eq!(files.env_keys, vec!["TOKEN"]);
        assert!(
            !serde_json::to_string(&listed).unwrap().contains("secret"),
            "values never listed"
        );

        // An edit that leaves the value out keeps it.
        upsert(
            McpScope::Project,
            cwd,
            edit(json!({
                "name": "files", "command": "/bin/files", "args": [], "env": {"TOKEN": null}
            })),
        )
        .unwrap();
        assert_eq!(file(&dir)["mcpServers"]["files"]["env"]["TOKEN"], "secret");

        set_enabled(McpScope::Project, cwd, "files", false).unwrap();
        let on_disk = file(&dir);
        assert!(on_disk["mcpServers"].get("files").is_none());
        assert_eq!(
            on_disk["disabledMcpServers"]["files"]["command"],
            "/bin/files"
        );
        assert!(
            !list_files(cwd)
                .unwrap()
                .servers
                .iter()
                .find(|s| s.name == "files")
                .unwrap()
                .enabled
        );

        set_enabled(McpScope::Project, cwd, "files", true).unwrap();
        let on_disk = file(&dir);
        assert_eq!(on_disk["mcpServers"]["files"]["env"]["TOKEN"], "secret");
        assert!(
            on_disk.get("disabledMcpServers").is_none(),
            "an empty disabled table goes away"
        );

        remove(McpScope::Project, cwd, "files").unwrap();
        let on_disk = file(&dir);
        assert_eq!(on_disk["note"], "mine");
        assert_eq!(on_disk["mcpServers"]["keep"]["command"], "/bin/keep");
        assert!(on_disk["mcpServers"].get("files").is_none());
    }

    #[test]
    fn a_save_keeps_the_files_own_order() {
        let (_dir, cwd) = project();
        let path = Path::new(&cwd).join(PROJECT_FILE);
        std::fs::write(
            &path,
            r#"{"zz":1,"mcpServers":{"zeta":{"command":"/bin/z","args":["-v"]},"alpha":{"url":"https://a/mcp"}},"aa":2}"#,
        )
        .unwrap();
        set_enabled(McpScope::Project, Some(&cwd), "alpha", false).unwrap();
        set_enabled(McpScope::Project, Some(&cwd), "alpha", true).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        let at = |needle: &str| text.find(needle).unwrap();
        assert!(at("\"zz\"") < at("\"mcpServers\"") && at("\"mcpServers\"") < at("\"aa\""));
        assert!(at("\"zeta\"") < at("\"alpha\""));
        assert!(at("\"command\"") < at("\"args\""));
    }

    #[test]
    fn http_servers_rename_and_refuse_bad_input() {
        let (_dir, cwd) = project();
        let dir = cwd.clone();
        let cwd = Some(cwd.as_str());
        upsert(McpScope::Project, cwd, edit(json!({
            "name": "docs", "url": "https://example.com/mcp", "headers": {"Authorization": "Bearer x"}
        })))
        .unwrap();
        upsert(
            McpScope::Project,
            cwd,
            edit(json!({
                "name": "docs2", "previousName": "docs", "url": "https://example.com/mcp",
                "headers": {"Authorization": null}
            })),
        )
        .unwrap();
        let on_disk = file(&dir);
        assert!(on_disk["mcpServers"].get("docs").is_none());
        assert_eq!(
            on_disk["mcpServers"]["docs2"]["headers"]["Authorization"],
            "Bearer x"
        );

        for bad in [
            json!({"name": "", "command": "x"}),
            json!({"name": "has space", "command": "x"}),
            json!({"name": "both", "command": "x", "url": "https://e"}),
            json!({"name": "neither"}),
            json!({"name": "ftp", "url": "ftp://e"}),
        ] {
            assert!(
                upsert(McpScope::Project, cwd, edit(bad.clone())).is_err(),
                "{bad}"
            );
        }
    }

    #[test]
    fn a_broken_file_is_reported_and_never_rewritten() {
        let (_dir, cwd) = project();
        let path = Path::new(&cwd).join(PROJECT_FILE);
        std::fs::write(&path, "{not json").unwrap();
        let cwd = Some(cwd.as_str());
        assert!(list_files(cwd).unwrap().invalid_project);
        assert!(
            upsert(
                McpScope::Project,
                cwd,
                edit(json!({"name": "a", "command": "x"}))
            )
            .is_err()
        );
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "{not json");
        assert!(list_files(Some("relative/dir")).is_err());
    }

    #[test]
    fn a_project_entry_marks_the_global_one_it_hides() {
        let (_dir, cwd) = project();
        let global = tempfile::tempdir().unwrap();
        let global_file = global.path().join("mcp.json");
        std::fs::write(
            &global_file,
            r#"{"mcpServers":{"docs":{"url":"https://g/mcp"}}}"#,
        )
        .unwrap();
        std::fs::write(
            Path::new(&cwd).join(PROJECT_FILE),
            r#"{"mcpServers":{"docs":{"command":"/bin/docs"}}}"#,
        )
        .unwrap();
        let listed = with_global(&global_file, || list_files(Some(&cwd)).unwrap());
        let project_docs = listed
            .servers
            .iter()
            .find(|s| s.scope == McpScope::Project)
            .unwrap();
        assert!(project_docs.overrides_global);
        assert_eq!(listed.servers.len(), 2);
    }

    #[test]
    fn imported_servers_switch_off_through_the_global_off_list() {
        let global = tempfile::tempdir().unwrap();
        let file = global.path().join("mcp.json");
        std::fs::write(&file, r#"{"mcpServers":{"docs":{"url":"https://g/mcp"}}}"#).unwrap();
        with_global(&file, || {
            set_enabled(McpScope::Imported, None, "from-claude", false).unwrap();
            let on_disk: Value =
                serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
            assert_eq!(on_disk["disabledMcpServers"]["from-claude"], json!({}));
            // A bare off-list name is not a global server of its own.
            let listed = list_files(None).unwrap();
            assert_eq!(
                listed
                    .servers
                    .iter()
                    .map(|s| s.name.as_str())
                    .collect::<Vec<_>>(),
                ["docs"]
            );
            assert!(
                upsert(
                    McpScope::Imported,
                    None,
                    edit(json!({"name": "from-claude", "command": "x"}))
                )
                .is_err()
            );
            set_enabled(McpScope::Imported, None, "from-claude", true).unwrap();
            let on_disk: Value =
                serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
            assert!(on_disk.get("disabledMcpServers").is_none());
        });
    }

    #[cfg(unix)]
    fn fake_graff(dir: &Path, output: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let path = dir.join("graff");
        std::fs::write(&path, format!("#!/bin/sh\ncat <<'EOF'\n{output}\nEOF\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    #[cfg(unix)]
    #[test]
    fn imported_servers_come_from_graff_and_an_old_graff_is_named() {
        let (_dir, cwd) = project();
        let bin = tempfile::tempdir().unwrap();
        let global = tempfile::tempdir().unwrap();
        let file = global.path().join("mcp.json");
        let current = fake_graff(
            bin.path(),
            r#"{"servers":[{"name":"mine","source":"project","enabled":true,"command":"/bin/mine"},
                {"name":"claude-docs","source":"imported","enabled":false,"url":"https://c/mcp","headerKeys":["Authorization"]}]}"#,
        );
        let listed = with_global(&file, || list(Some(&cwd), Some(&current)).unwrap());
        let imported: Vec<_> = listed
            .servers
            .iter()
            .filter(|s| s.scope == McpScope::Imported)
            .collect();
        assert_eq!(
            imported.len(),
            1,
            "graff's own files are read directly, not from graff"
        );
        assert_eq!(imported[0].name, "claude-docs");
        assert!(!imported[0].enabled);
        assert_eq!(imported[0].header_keys, ["Authorization"]);
        assert!(listed.imported_note.is_none());

        let old_dir = tempfile::tempdir().unwrap();
        let old = fake_graff(old_dir.path(), "2 MCP server(s):\n  mine: /bin/mine");
        let listed = with_global(&file, || list(Some(&cwd), Some(&old)).unwrap());
        assert!(
            listed
                .imported_note
                .as_deref()
                .is_some_and(|n| n.contains("update graff"))
        );
        let listed = with_global(&file, || list(Some(&cwd), None).unwrap());
        assert!(listed.imported_note.is_some());
    }
}
