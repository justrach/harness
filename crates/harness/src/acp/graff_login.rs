//! `graff login <provider>` as a child the engine can drive. The account
//! screen shows the sign-in link and code itself; graff writes the credential
//! when the user approves. Resolution matches a chat run, so a sign-in never
//! launches a different binary than the agent would.

use std::path::Path;

use crate::HarnessError;
use crate::process::Command;

/// A ready-to-spawn `graff login <provider>`.
///
/// graff opens the sign-in page itself, while the app opens it on the machine
/// the user is sitting at (the engine may belong to another device). So
/// graff's own open is muted: `GRAFF_NO_BROWSER` for the sign-ins that honour
/// it, and `no_open_dir` (holding no-op `open` / `xdg-open` stand-ins, put
/// first on the child's PATH) for the ones that do not.
pub async fn login_command(
    provider: &str,
    no_open_dir: Option<&Path>,
) -> Result<Command, HarnessError> {
    if !harness_proto::GRAFF_LOGIN_PROVIDERS
        .iter()
        .any(|(id, _)| *id == provider)
    {
        return Err(HarnessError::Protocol(format!(
            "not a graff sign-in provider: {provider}"
        )));
    }
    let (program, _) = super::AcpHarness::graff().resolve_program(false).await?;
    let mut cmd = Command::new(&program);
    match no_open_dir {
        Some(dir) => crate::compose_child_path_with_prefix(&mut cmd, &program, dir),
        None => crate::compose_child_path(&mut cmd, &program),
    }
    cmd.arg("login").arg(provider).env("NO_COLOR", "1");
    if provider == "chatgpt-new" {
        // This PKCE flow can complete only on the host's loopback callback.
        cmd.env_remove("GRAFF_NO_BROWSER");
    } else {
        cmd.env("GRAFF_NO_BROWSER", "1");
    }
    Ok(cmd)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn only_graffs_own_sign_in_providers_are_launchable() {
        // Checked before graff is even resolved, so no install is needed.
        for bad in ["", "codegraff", "codex", "--help", "xai --yolo", "../xai"] {
            let err = login_command(bad, None).await.unwrap_err();
            assert!(
                matches!(&err, HarnessError::Protocol(m) if m.contains("not a graff sign-in provider")),
                "{bad:?} -> {err}"
            );
        }
    }
}
