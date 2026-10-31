//! `graff mcp status | reconnect | enable | disable | login` as a child the
//! engine can run for the MCP servers page and the TUI's `/mcp`. Resolution
//! matches a chat run, so the page reports the servers that graff will start.

use std::path::Path;

use crate::HarnessError;
use crate::process::Command;

/// The verbs the MCP servers page drives. Anything else is refused before
/// graff is resolved, so a request can never become an arbitrary command.
pub const VERBS: &[&str] = &["status", "reconnect", "enable", "disable", "login"];

/// A ready-to-spawn `graff mcp <verb> [names…] --json` run in `cwd` (the
/// project whose `.mcp.json` counts). `names` empty with `reconnect` means
/// every switched-on server.
pub async fn mcp_command(
    verb: &str,
    names: &[String],
    cwd: Option<&Path>,
) -> Result<Command, HarnessError> {
    if !VERBS.contains(&verb) {
        return Err(HarnessError::Protocol(format!(
            "not a graff mcp verb: {verb}"
        )));
    }
    if let Some(bad) = names.iter().find(|n| n.is_empty() || n.starts_with('-')) {
        return Err(HarnessError::Protocol(format!(
            "not an MCP server name: {bad:?}"
        )));
    }
    let (program, _) = super::AcpHarness::graff().resolve_program(false).await?;
    let mut cmd = Command::new(&program);
    crate::apply_run_environment(&mut cmd, None);
    crate::compose_child_path(&mut cmd, &program);
    cmd.arg("mcp").arg(verb);
    if verb == "reconnect" && names.is_empty() {
        cmd.arg("--all");
    }
    cmd.args(names);
    // `login` is interactive (it opens the sign-in page); the rest answer JSON.
    if verb != "login" {
        cmd.arg("--json");
    }
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    cmd.env("NO_COLOR", "1");
    Ok(cmd)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn only_the_page_verbs_and_plain_names_are_launchable() {
        // Checked before graff is even resolved, so no install is needed.
        for bad in ["", "add", "serve", "install", "--help", "status; rm"] {
            let err = mcp_command(bad, &[], None).await.unwrap_err();
            assert!(
                matches!(&err, HarnessError::Protocol(m) if m.contains("not a graff mcp verb")),
                "{bad:?} -> {err}"
            );
        }
        for bad in ["", "--all", "-x"] {
            let err = mcp_command("reconnect", &[bad.to_string()], None)
                .await
                .unwrap_err();
            assert!(
                matches!(&err, HarnessError::Protocol(m) if m.contains("not an MCP server name")),
                "{bad:?} -> {err}"
            );
        }
    }
}
