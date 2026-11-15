//! Bounded native panel transport. Project ownership is checked by the RPC host.
use crate::EngineError;
use serde::Deserialize;
use serde_json::Value;
use std::{path::Path, time::Duration};

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
                .is_none_or(|p| p.len() > 16))
    {
        return Err(EngineError::Other(
            "Unsupported native extension response".into(),
        ));
    }
    Ok(value)
}

pub async fn run(
    home: &Path,
    cwd: &Path,
    plugin: Option<&str>,
    action: Option<&str>,
) -> Result<Value, EngineError> {
    let mut command = harness_adapters::graff_extensions_command(cwd, plugin, action).await?;
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
}
