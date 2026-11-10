//! `graff bot --user …` as a child the engine can run: the user's own bots
//! in graff's home (codegraff ADR 0333, 0334). graff owns that store and the
//! wording of every prompt; the engine only runs the command. Resolution
//! matches a chat run, so a bot is read by the graff that will run it.

use crate::HarnessError;
use crate::process::Command;

/// The commands the engine drives. Anything else is refused before graff is
/// resolved, so a request can never become an arbitrary command. `run`,
/// `tick` and `trigger` are absent on purpose: the engine starts a bot's run
/// as a chat, never as a headless child.
pub const VERBS: &[&str] = &[
    "state", "show", "prompt", "create", "rm", "set", "remember", "forget", "about", "missed",
    "due", "routine", "enable", "disable",
];

/// A ready-to-spawn `graff bot --user <args…>`. `args[0]` is the verb.
pub async fn bot_command(args: &[String]) -> Result<Command, HarnessError> {
    let verb = args.first().map(String::as_str).unwrap_or_default();
    if !VERBS.contains(&verb) {
        return Err(HarnessError::Protocol(format!(
            "not a graff bot command: {verb}"
        )));
    }
    let (program, _) = super::AcpHarness::graff().resolve_program(false).await?;
    let mut cmd = Command::new(&program);
    crate::apply_run_environment(&mut cmd, None);
    crate::compose_child_path(&mut cmd, &program);
    cmd.arg("bot").arg("--user").args(args);
    cmd.env("NO_COLOR", "1");
    Ok(cmd)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn only_the_store_commands_are_launchable() {
        // Checked before graff is even resolved, so no install is needed.
        for bad in ["", "run", "tick", "trigger", "--help", "state; rm"] {
            let err = bot_command(&[bad.to_string()]).await.unwrap_err();
            assert!(
                matches!(&err, HarnessError::Protocol(m) if m.contains("not a graff bot command")),
                "{bad:?} -> {err}"
            );
        }
    }
}
