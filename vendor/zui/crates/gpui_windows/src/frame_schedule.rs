//! Demand-driven frames for the Windows backend.
//!
//! Modified by Harness: adapted from the Apache-2.0 GPUI fork
//! https://github.com/longbridge/gpui-fast at 124f79b ("schedule Windows frames on demand")
//! and ec3f4a3 ("avoid redundant Windows frame requests after input"). See vendor/zui/NOTICE.
//! Harness keeps gpui-fast's wake and per-window request, and drives them from zui's
//! `frame_requester` / `pause_frame_requests` hooks instead of re-arming after every present.
//!
//! The VSync worker used to invalidate every window on every vsync, so each window ran a frame
//! callback at the display's refresh rate even when nothing had changed. Now each window holds
//! a [`FrameRequest`], and the worker sleeps on a shared [`FrameWake`] until some window asks
//! for a frame. It then waits for the next vsync and invalidates only the windows that asked.
//!
//! This module is plain Rust, so its rules and tests run on every OS (`tests/frame_schedule.rs`
//! compiles it where the rest of the crate doesn't build).

use std::{
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

/// How long a touchpad contact keeps Direct Manipulation updating before its gesture starts.
pub(crate) const CONTACT_POLL: Duration = Duration::from_secs(1);

/// Without a device-removal notification, the sleeping worker still checks the GPU this often.
pub(crate) const DEVICE_POLL: Duration = Duration::from_secs(1);

/// The VSync worker's wake, shared by every window.
#[derive(Default)]
pub(crate) struct FrameWake {
    pending: Mutex<bool>,
    changed: Condvar,
}

impl FrameWake {
    pub(crate) fn request(&self) {
        *self.pending.lock().unwrap_or_else(|e| e.into_inner()) = true;
        // A replacement worker may start before the previous one exits.
        self.changed.notify_all();
    }

    /// Sleeps until a window asks for a frame or the worker is stopped. Returns false once
    /// stopped. Without device notifications it also returns every [`DEVICE_POLL`], so device
    /// loss is still noticed.
    pub(crate) fn wait(&self, stopped: &AtomicBool, device_notifications: bool) -> bool {
        let mut pending = self.pending.lock().unwrap_or_else(|e| e.into_inner());
        while !*pending && !stopped.load(Ordering::Acquire) {
            if device_notifications {
                pending = self
                    .changed
                    .wait(pending)
                    .unwrap_or_else(|e| e.into_inner());
            } else {
                let (guard, timeout) = self
                    .changed
                    .wait_timeout(pending, DEVICE_POLL)
                    .unwrap_or_else(|e| e.into_inner());
                pending = guard;
                if timeout.timed_out() {
                    break;
                }
            }
        }
        if stopped.load(Ordering::Acquire) {
            return false;
        }
        *pending = false;
        true
    }

    #[cfg(test)]
    fn is_pending(&self) -> bool {
        *self.pending.lock().unwrap()
    }
}

/// One window's demand for a frame. Requests coalesce: however many arrive before the worker's
/// next vsync, the window is invalidated once.
pub(crate) struct FrameRequest {
    pending: AtomicBool,
    wake: Arc<FrameWake>,
}

impl FrameRequest {
    pub(crate) fn new(wake: Arc<FrameWake>) -> Self {
        Self {
            pending: AtomicBool::new(false),
            wake,
        }
    }

    pub(crate) fn request(&self) {
        // A request already pending has woken the worker, which has yet to take it.
        if !self.pending.swap(true, Ordering::AcqRel) {
            self.wake.request();
        }
    }

    /// Takes the pending request; the worker redraws only windows that asked for a frame.
    pub(crate) fn take(&self) -> bool {
        self.pending.swap(false, Ordering::AcqRel)
    }
}

/// What a window's paint handler does with a paint.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Paint {
    /// Run the frame callback.
    Draw,
    /// The frame callback is out: a paint nested inside the current one, or one that arrives
    /// before the window registered its callback. Validate it and ask for the next vsync, so a
    /// nested message loop doesn't spin on the still-invalid region and the frame isn't lost.
    Retry,
    /// Minimized: the callback is parked until restore. Leave the paint to Windows.
    Skip,
}

/// Decides how to handle a paint from whether the frame callback is available.
pub(crate) fn paint(has_frame_callback: bool, minimized: bool) -> Paint {
    if has_frame_callback {
        Paint::Draw
    } else if minimized {
        Paint::Skip
    } else {
        Paint::Retry
    }
}

/// Whether Direct Manipulation needs the next frame: while a gesture or its inertia runs, and
/// for [`CONTACT_POLL`] after a touchpad contact (until then, Direct Manipulation consumes the
/// contact's pointer messages, so nothing else would ask for the frames that run its update).
pub(crate) fn manipulation_wants_frame(running: bool, since_contact: Option<Duration>) -> bool {
    running || since_contact.is_some_and(|elapsed| elapsed < CONTACT_POLL)
}

/// Whether a window asks for the frame after the one it just ran. zui's frame loop calls
/// `pause_frame_requests` when the window has nothing left to draw, present, or call back, so a
/// frame that ended without pausing (an animation, a throttled frame, the presentation hold
/// after high-rate input) wants the next vsync too.
pub(crate) fn wants_next_frame(paused: bool, manipulation: bool) -> bool {
    !paused || manipulation
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{sync::mpsc, thread};

    // Ported from gpui-fast 124f79b (`fast::frame_schedule::tests`).
    #[test]
    fn requests_coalesce_without_invalidating_other_windows() {
        let wake = Arc::new(FrameWake::default());
        let first = FrameRequest::new(wake.clone());
        let second = FrameRequest::new(wake.clone());
        first.request();
        first.request();
        assert!(first.take());
        assert!(!first.take());
        assert!(!second.take());
        assert!(wake.wait(&AtomicBool::new(false), true));
        assert!(!wake.is_pending());
    }

    // Ported from gpui-fast 124f79b.
    #[test]
    fn stop_wakes_a_sleeping_worker() {
        let wake = Arc::new(FrameWake::default());
        let stop = Arc::new(AtomicBool::new(false));
        let (tx, rx) = mpsc::channel();
        let worker = {
            let wake = wake.clone();
            let stop = stop.clone();
            thread::spawn(move || {
                tx.send(wake.wait(&stop, true)).unwrap();
            })
        };
        assert!(matches!(
            rx.recv_timeout(Duration::from_millis(20)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        stop.store(true, Ordering::Release);
        wake.request();
        assert!(!rx.recv_timeout(Duration::from_secs(2)).unwrap());
        worker.join().unwrap();
    }

    // Ported from gpui-fast 124f79b.
    #[test]
    fn replacement_worker_cannot_consume_the_old_workers_stop() {
        let wake = Arc::new(FrameWake::default());
        let old_stop = Arc::new(AtomicBool::new(false));
        let new_stop = Arc::new(AtomicBool::new(false));
        let (tx, rx) = mpsc::channel();
        let workers = [(true, old_stop.clone()), (false, new_stop)].map(|(old, stop)| {
            let wake = wake.clone();
            let tx = tx.clone();
            thread::spawn(move || {
                tx.send((old, wake.wait(&stop, true))).unwrap();
            })
        });
        old_stop.store(true, Ordering::Release);
        wake.request();
        let mut results = [
            rx.recv_timeout(Duration::from_secs(2)).unwrap(),
            rx.recv_timeout(Duration::from_secs(2)).unwrap(),
        ];
        results.sort_by_key(|(old, _)| *old);
        assert_eq!(results, [(false, true), (true, false)]);
        for worker in workers {
            worker.join().unwrap();
        }
    }

    #[test]
    fn an_idle_worker_sleeps_until_a_window_asks() {
        let wake = Arc::new(FrameWake::default());
        let window = Arc::new(FrameRequest::new(wake.clone()));
        let stop = Arc::new(AtomicBool::new(false));
        let (tx, rx) = mpsc::channel();
        // The real worker waits for the next vsync between waking and taking requests.
        let (vsync_tx, vsync_rx) = mpsc::channel::<()>();
        let worker = {
            let (wake, window, stop) = (wake.clone(), window.clone(), stop.clone());
            thread::spawn(move || {
                while wake.wait(&stop, true) {
                    if vsync_rx.recv().is_err() {
                        break;
                    }
                    tx.send(window.take()).unwrap();
                }
            })
        };
        // Nothing asked: no frame.
        assert!(rx.recv_timeout(Duration::from_millis(50)).is_err());
        // Many requests before the next vsync are one frame.
        for _ in 0..240 {
            window.request();
        }
        vsync_tx.send(()).unwrap();
        assert!(rx.recv_timeout(Duration::from_secs(2)).unwrap());
        // Nothing asked since: the worker sleeps rather than waiting on another vsync.
        assert!(!wake.is_pending());
        assert!(rx.recv_timeout(Duration::from_millis(50)).is_err());
        stop.store(true, Ordering::Release);
        wake.request();
        drop(vsync_tx);
        worker.join().unwrap();
    }

    #[test]
    fn without_device_notifications_the_worker_polls() {
        let wake = FrameWake::default();
        let started = std::time::Instant::now();
        assert!(wake.wait(&AtomicBool::new(false), false));
        assert!(started.elapsed() >= DEVICE_POLL - Duration::from_millis(50));
    }

    /// The scheduling rule, as the paint handler and the VSync worker apply it.
    #[test]
    fn frames_run_only_while_something_asks() {
        // A paint with the callback draws; a nested one retries at the next vsync; a minimized
        // window leaves the paint to Windows.
        assert_eq!(paint(true, false), Paint::Draw);
        assert_eq!(paint(true, true), Paint::Draw);
        assert_eq!(paint(false, false), Paint::Retry);
        assert_eq!(paint(false, true), Paint::Skip);

        // The frame loop paused: idle, no next frame.
        assert!(!wants_next_frame(true, false));
        // It didn't pause (animating, throttled, holding presentation): next vsync.
        assert!(wants_next_frame(false, false));
        // A touchpad gesture keeps frames coming even when the app is idle.
        assert!(wants_next_frame(true, true));

        assert!(manipulation_wants_frame(true, None));
        assert!(manipulation_wants_frame(
            false,
            Some(Duration::from_millis(10))
        ));
        assert!(!manipulation_wants_frame(false, Some(CONTACT_POLL)));
        assert!(!manipulation_wants_frame(false, None));
    }

    /// Simulates a vsync loop over two windows: only the window with demand is invalidated,
    /// and once both are paused the worker invalidates nothing.
    #[test]
    fn only_windows_with_demand_are_invalidated() {
        let wake = Arc::new(FrameWake::default());
        let windows = [FrameRequest::new(wake.clone()), FrameRequest::new(wake)];
        let mut paused = [false, true];
        let mut invalidated = [0usize; 2];
        windows[0].request();
        for _vsync in 0..10 {
            for (index, window) in windows.iter().enumerate() {
                if window.take() {
                    invalidated[index] += 1;
                    // The paint runs the frame; the first window animates for three frames.
                    if invalidated[index] == 3 {
                        paused[index] = true;
                    }
                    if wants_next_frame(paused[index], false) {
                        window.request();
                    }
                }
            }
        }
        assert_eq!(invalidated, [3, 0]);
    }
}
