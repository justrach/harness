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
use tokio_util::task::AbortOnDropHandle;

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
    sessions: watch::Receiver<Vec<Session>>,
    enabled: watch::Receiver<bool>,
) -> AbortOnDropHandle<()> {
    spawn_with(sessions, enabled, platform::Assertion::acquire)
}

fn spawn_with<A: Send + 'static>(
    mut sessions: watch::Receiver<Vec<Session>>,
    mut enabled: watch::Receiver<bool>,
    mut acquire: impl FnMut() -> Option<A> + Send + 'static,
) -> AbortOnDropHandle<()> {
    AbortOnDropHandle::new(tokio::spawn(async move {
        let mut held: Option<A> = None;
        loop {
            let want =
                *enabled.borrow_and_update() && agents_working(&sessions.borrow_and_update());
            if want && held.is_none() {
                held = acquire();
            } else if !want {
                held = None;
            }
            tokio::select! {
                changed = sessions.changed() => if changed.is_err() { break },
                changed = enabled.changed() => if changed.is_err() { break },
            }
        }
    }))
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
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

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

    struct FakeAssertion(Arc<AtomicUsize>);

    impl FakeAssertion {
        fn acquire(held: &Arc<AtomicUsize>) -> Option<Self> {
            held.fetch_add(1, Ordering::SeqCst);
            Some(Self(held.clone()))
        }
    }

    impl Drop for FakeAssertion {
        fn drop(&mut self) {
            self.0.fetch_sub(1, Ordering::SeqCst);
        }
    }

    async fn until(value: &AtomicUsize, expected: usize) {
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            while value.load(Ordering::SeqCst) != expected {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("watcher processes the transition");
    }

    #[test]
    fn keep_awake_only_counts_working_chats() {
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

    // Exercise real watcher transitions with a fake power-assertion handle.
    // Tests never change the computer's sleep settings or acquire an IOKit assertion.
    #[tokio::test]
    async fn keep_awake_follows_work_setting_and_owner_lifetime() {
        let held = Arc::new(AtomicUsize::new(0));
        let acquisitions = Arc::new(AtomicUsize::new(0));
        let (sessions_tx, sessions) = watch::channel(vec![session(SessionStatus::Working)]);
        let (enabled_tx, enabled) = watch::channel(false);
        let count = held.clone();
        let attempts = acquisitions.clone();
        let task = spawn_with(sessions, enabled, move || {
            attempts.fetch_add(1, Ordering::SeqCst);
            FakeAssertion::acquire(&count)
        });
        tokio::task::yield_now().await;
        assert_eq!(held.load(Ordering::SeqCst), 0, "off by default");
        enabled_tx.send_replace(true);
        until(&held, 1).await;
        sessions_tx.send_replace(vec![
            session(SessionStatus::Working),
            session(SessionStatus::Working),
        ]);
        tokio::task::yield_now().await;
        assert_eq!(
            acquisitions.load(Ordering::SeqCst),
            1,
            "one assertion covers concurrent work"
        );
        sessions_tx.send_replace(vec![session(SessionStatus::AwaitingInput)]);
        until(&held, 0).await;
        sessions_tx.send_replace(vec![session(SessionStatus::Working)]);
        until(&held, 1).await;
        enabled_tx.send_replace(false);
        until(&held, 0).await;
        enabled_tx.send_replace(true);
        until(&held, 1).await;
        drop(task);
        until(&held, 0).await;
    }

    #[tokio::test]
    async fn keep_awake_releases_when_either_source_closes() {
        for close_sessions in [false, true] {
            let held = Arc::new(AtomicUsize::new(0));
            let (sessions_tx, sessions) = watch::channel(vec![session(SessionStatus::Working)]);
            let (enabled_tx, enabled) = watch::channel(true);
            let count = held.clone();
            let task = spawn_with(sessions, enabled, move || FakeAssertion::acquire(&count));
            until(&held, 1).await;
            if close_sessions {
                drop(sessions_tx);
            } else {
                drop(enabled_tx);
            }
            tokio::time::timeout(std::time::Duration::from_secs(1), task)
                .await
                .expect("closed source ends task")
                .expect("task exits cleanly");
            assert_eq!(held.load(Ordering::SeqCst), 0);
        }
    }

    #[tokio::test]
    async fn keep_awake_failed_acquisition_retries_on_the_next_state_change() {
        let held = Arc::new(AtomicUsize::new(0));
        let attempts = Arc::new(AtomicUsize::new(0));
        let (sessions_tx, sessions) = watch::channel(vec![session(SessionStatus::Working)]);
        let (_enabled_tx, enabled) = watch::channel(true);
        let count = held.clone();
        let tried = attempts.clone();
        let task = spawn_with(sessions, enabled, move || {
            if tried.fetch_add(1, Ordering::SeqCst) == 0 {
                None
            } else {
                FakeAssertion::acquire(&count)
            }
        });
        until(&attempts, 1).await;
        assert_eq!(held.load(Ordering::SeqCst), 0);
        sessions_tx.send_replace(vec![session(SessionStatus::Working)]);
        until(&held, 1).await;
        task.abort();
        let _ = task.await;
        assert_eq!(held.load(Ordering::SeqCst), 0);
    }
}
