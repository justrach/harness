//! ACP process ownership, including descendants that outlive their adapter.
use std::ops::{Deref, DerefMut};

use crate::process::{Child as ProcessChild, Command};

pub(super) fn configure(command: &mut Command) {
    #[cfg(unix)]
    command.process_group(0);
    for key in [
        "CLAUDECODE",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_SSE_PORT",
        "CLAUDE_AGENT_SDK_VERSION",
    ] {
        command.env_remove(key);
    }
}

pub(super) struct Child {
    inner: ProcessChild,
    #[cfg(unix)]
    group: Option<i32>,
}

impl Child {
    pub(super) fn new(inner: ProcessChild) -> Self {
        Self {
            #[cfg(unix)]
            group: Some(-(inner.id().expect("newly spawned ACP child") as i32)),
            inner,
        }
    }

    pub(super) fn terminate_group(&mut self) {
        #[cfg(unix)]
        if let Some(group) = self.group.take() {
            crate::send_signal(&group, crate::Signal::Kill);
        }
    }
}

impl Deref for Child {
    type Target = ProcessChild;
    fn deref(&self) -> &Self::Target {
        &self.inner
    }
}

impl DerefMut for Child {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.inner
    }
}

impl Drop for Child {
    fn drop(&mut self) {
        // Tokio's kill_on_drop covers the direct child. Keep the group id
        // even after wait() has reaped it, so descendants cannot escape cleanup.
        self.terminate_group();
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn acp_environment_removes_nested_claude_markers() {
        let mut command = Command::new("unused");
        configure(&mut command);
        let removed: Vec<_> = command
            .as_std()
            .get_envs()
            .filter(|(_, value)| value.is_none())
            .map(|(key, _)| key.to_str().unwrap())
            .collect();
        assert_eq!(
            removed,
            vec![
                "CLAUDECODE",
                "CLAUDE_AGENT_SDK_VERSION",
                "CLAUDE_CODE_ENTRYPOINT",
                "CLAUDE_CODE_SSE_PORT"
            ]
        );
    }
}
