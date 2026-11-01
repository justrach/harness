//! Keep the Mac awake while agents work (Settings → Agents). While the setting
//! is on and any chat on this device is working, the engine holds a
//! "prevent idle system sleep" power assertion — what `caffeinate -i` does —
//! and drops it the moment every chat goes idle. The display may still sleep,
//! and closing a laptop's lid still sleeps it.
//!
//! A chat parked on a question (AwaitingInput) does not count: nothing runs
//! until the user answers.

use harness_proto::{Session, SessionStatus};
use tokio::sync::watch;
use tokio::task::JoinHandle;

/// Whether this build can hold the assertion (macOS only for now). Clients
/// hide the setting where it would do nothing.
pub const SUPPORTED: bool = cfg!(target_os = "macos");

/// Whether `sessions` warrant keeping the machine awake.
pub fn agents_working(sessions: &[Session]) -> bool {
    sessions
        .iter()
        .any(|session| session.status == SessionStatus::Working)
}

/// Follow the session list and the setting, holding the assertion exactly
/// while both say so. Aborting the task drops (releases) a held assertion.
pub fn spawn(
    mut sessions: watch::Receiver<Vec<Session>>,
    mut enabled: watch::Receiver<bool>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut held: Option<platform::Assertion> = None;
        loop {
            let want =
                *enabled.borrow_and_update() && agents_working(&sessions.borrow_and_update());
            if want && held.is_none() {
                held = platform::Assertion::acquire();
            } else if !want {
                held = None;
            }
            tokio::select! {
                changed = sessions.changed() => if changed.is_err() { break },
                changed = enabled.changed() => if changed.is_err() { break },
            }
        }
    })
}

#[cfg(target_os = "macos")]
mod platform {
    use core_foundation::base::TCFType;
    use core_foundation::string::{CFString, CFStringRef};

    const ASSERTION_LEVEL_ON: u32 = 255;
    const IO_RETURN_SUCCESS: i32 = 0;

    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOPMAssertionCreateWithName(
            assertion_type: CFStringRef,
            level: u32,
            name: CFStringRef,
            id: *mut u32,
        ) -> i32;
        fn IOPMAssertionRelease(id: u32) -> i32;
    }

    /// A held IOKit power assertion; released on drop (and by the OS if the
    /// process dies).
    pub struct Assertion(u32);

    impl Assertion {
        pub fn acquire() -> Option<Self> {
            let kind = CFString::from_static_string("PreventUserIdleSystemSleep");
            let name = CFString::from_static_string("Harness: agents are working");
            let mut id = 0;
            // SAFETY: both CFStrings outlive the call; `id` is a valid out-pointer.
            let status = unsafe {
                IOPMAssertionCreateWithName(
                    kind.as_concrete_TypeRef(),
                    ASSERTION_LEVEL_ON,
                    name.as_concrete_TypeRef(),
                    &mut id,
                )
            };
            if status != IO_RETURN_SUCCESS {
                tracing::warn!(status, "keep-awake power assertion failed");
                return None;
            }
            tracing::info!("keeping the Mac awake while agents work");
            Some(Self(id))
        }
    }

    impl Drop for Assertion {
        fn drop(&mut self) {
            // SAFETY: `self.0` came from a successful create and is released once.
            unsafe { IOPMAssertionRelease(self.0) };
            tracing::info!("agents idle; the Mac may sleep again");
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    pub struct Assertion;

    impl Assertion {
        pub fn acquire() -> Option<Self> {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(status: SessionStatus) -> Session {
        Session {
            last_completed_turn: None,
            last_completed_peer_only: false,
            chat_id: "c".into(),
            device_id: "d".into(),
            status,
            started_at: None,
            updated_at: chrono::Utc::now(),
        }
    }

    #[test]
    fn only_a_working_chat_keeps_the_machine_awake() {
        assert!(!agents_working(&[]));
        assert!(!agents_working(&[
            session(SessionStatus::Idle),
            session(SessionStatus::AwaitingInput),
        ]));
        assert!(agents_working(&[
            session(SessionStatus::Idle),
            session(SessionStatus::Working),
        ]));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn the_assertion_follows_the_setting_and_working_chats() {
        let listed = || {
            let out = std::process::Command::new("pmset")
                .args(["-g", "assertions"])
                .output()
                .expect("pmset");
            let me = format!("pid {}(", std::process::id());
            String::from_utf8_lossy(&out.stdout)
                .lines()
                .any(|line| line.contains(&me) && line.contains("Harness: agents are working"))
        };
        let held = platform::Assertion::acquire().expect("assertion");
        assert!(listed());
        drop(held);
        assert!(!listed());

        // The task holds it only while the setting is on and a chat works.
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap();
        runtime.block_on(async {
            let settle = || tokio::time::sleep(std::time::Duration::from_millis(50));
            let (sessions_tx, sessions) = watch::channel(vec![session(SessionStatus::Idle)]);
            let (enabled_tx, enabled) = watch::channel(true);
            let task = spawn(sessions, enabled);
            settle().await;
            assert!(!listed(), "idle chats leave sleep alone");
            sessions_tx.send_replace(vec![session(SessionStatus::Working)]);
            settle().await;
            assert!(listed(), "a working chat keeps the Mac awake");
            enabled_tx.send_replace(false);
            settle().await;
            assert!(!listed(), "turning the setting off releases it");
            enabled_tx.send_replace(true);
            settle().await;
            assert!(listed());
            task.abort();
            let _ = task.await;
            assert!(!listed(), "engine shutdown releases it");
        });
    }

    #[tokio::test]
    async fn the_task_ends_when_the_engine_drops_its_channels() {
        let (sessions_tx, sessions) = watch::channel(vec![session(SessionStatus::Working)]);
        let (enabled_tx, enabled) = watch::channel(false);
        let task = spawn(sessions, enabled);
        drop(sessions_tx);
        drop(enabled_tx);
        tokio::time::timeout(std::time::Duration::from_secs(5), task)
            .await
            .expect("task ended")
            .expect("task did not panic");
    }
}
