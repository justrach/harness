//! Explicit native extension UI requests, never arbitrary CLI arguments.
use crate::{HarnessError, process::Command};
use std::path::Path;

pub fn identifier(value: &str) -> bool {
    !value.is_empty()
        && !value.starts_with('-')
        && value.len() <= 64
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
}

pub fn arguments(plugin: Option<&str>, action: Option<&str>) -> Result<Vec<String>, HarnessError> {
    match (plugin, action) {
        (None, None) => Ok(vec!["extensions".into(), "list".into(), "--json".into()]),
        (Some(id), Some(action)) if identifier(id) && identifier(action) => Ok(vec![
            "extensions".into(),
            "invoke".into(),
            id.into(),
            action.into(),
        ]),
        _ => Err(HarnessError::Protocol(
            "Invalid native extension action".into(),
        )),
    }
}

pub async fn command(
    cwd: &Path,
    plugin: Option<&str>,
    action: Option<&str>,
) -> Result<Command, HarnessError> {
    let args = arguments(plugin, action)?;
    let (program, _) = super::AcpHarness::graff().resolve_program(false).await?;
    let mut command = Command::new(&program);
    crate::apply_run_environment(&mut command, None);
    crate::compose_child_path(&mut command, &program);
    command.args(args).current_dir(cwd).env("NO_COLOR", "1");
    Ok(command)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_extension_arguments_cannot_become_shell_or_cli_flags() {
        assert_eq!(
            arguments(None, None).unwrap(),
            ["extensions", "list", "--json"]
        );
        assert_eq!(
            arguments(Some("checks"), Some("refresh")).unwrap(),
            ["extensions", "invoke", "checks", "refresh"]
        );
        for bad in ["", "--help", "a b", "a;sh", "../escape", "$(run)"] {
            assert!(arguments(Some(bad), Some("refresh")).is_err());
        }
        assert!(arguments(Some("checks"), None).is_err());
    }
}
