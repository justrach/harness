//! Frame pacing on macOS 14 and later, built on the `CADisplayLink` that
//! `NSView.displayLink(target:selector:)` returns.
//!
//! Compared with the shared `CVDisplayLink` in `display_link.rs` (the
//! fallback for older macOS):
//!
//! * the link belongs to the window's view and follows it from display to
//!   display, so a window moved to a 60 Hz or a 240 Hz screen paces to it;
//! * it fires on the main run loop, so there is no io thread, no dispatch
//!   source, and no teardown race;
//! * idling is `paused = YES` and waking is `paused = NO`, which costs a
//!   property write. A `CVDisplayLink` is stopped when a window goes idle and
//!   started again on the next invalidation, which spins its thread down and
//!   up for every burst (each streamed chunk of text, every frame of a scroll
//!   whose events arrive between frames);
//! * `preferredFrameRateRange` asks for the screen's full rate while frames
//!   are requested, or for GPUI's lower cap when it throttles animation.

use crate::frame_pacing::{FramePacing, FrameRateRange};
use cocoa::base::{id, nil};
use objc::{
    Encode, Encoding, class, msg_send,
    runtime::{BOOL, NO, Sel, YES},
    sel, sel_impl,
};

/// `CAFrameRateRange`: three `float`s.
#[repr(C)]
#[derive(Clone, Copy)]
pub(crate) struct CAFrameRateRange {
    pub minimum: f32,
    pub maximum: f32,
    pub preferred: f32,
}

impl From<FrameRateRange> for CAFrameRateRange {
    fn from(range: FrameRateRange) -> Self {
        Self {
            minimum: range.minimum,
            maximum: range.maximum,
            preferred: range.preferred,
        }
    }
}

unsafe impl Encode for CAFrameRateRange {
    fn encode() -> Encoding {
        unsafe { Encoding::from_str("{CAFrameRateRange=fff}") }
    }
}

#[link(name = "Foundation", kind = "framework")]
unsafe extern "C" {
    pub(crate) static NSRunLoopCommonModes: id;
}

/// A window view's `CADisplayLink`, scheduled on the main run loop in common
/// modes (so it keeps firing during live resize and menu tracking).
pub(crate) struct ViewDisplayLink {
    /// Retained `CADisplayLink`.
    link: id,
    paused: bool,
    /// The last range sent to the link.
    range: Option<FrameRateRange>,
}

impl ViewDisplayLink {
    /// Creates a paused link that sends `selector` to `view` once per frame.
    /// Returns `None` before macOS 14, where `NSView` has no display link.
    ///
    /// # Safety
    /// `view` must be a live `NSView` that implements `selector` taking one
    /// object argument. Call on the main thread.
    pub(crate) unsafe fn new(view: id, selector: Sel) -> Option<Self> {
        unsafe {
            if view.is_null() {
                return None;
            }
            let supported: BOOL =
                msg_send![view, respondsToSelector: sel!(displayLinkWithTarget:selector:)];
            if supported == NO {
                return None;
            }
            // The link retains its target until it's invalidated in `drop`.
            let link: id = msg_send![view, displayLinkWithTarget: view selector: selector];
            if link.is_null() {
                return None;
            }
            let link: id = msg_send![link, retain];
            let _: () = msg_send![link, setPaused: YES];
            let run_loop: id = msg_send![class!(NSRunLoop), mainRunLoop];
            let _: () = msg_send![link, addToRunLoop: run_loop forMode: NSRunLoopCommonModes];
            Some(Self {
                link,
                paused: true,
                range: None,
            })
        }
    }

    /// Applies `pacing`, touching the link only for what changed.
    pub(crate) fn set_pacing(&mut self, pacing: FramePacing) {
        unsafe {
            match pacing {
                FramePacing::Paused => {
                    if !self.paused {
                        let _: () = msg_send![self.link, setPaused: YES];
                        self.paused = true;
                    }
                }
                FramePacing::Running(range) => {
                    if self.range != Some(range) {
                        let ca_range = CAFrameRateRange::from(range);
                        let _: () = msg_send![self.link, setPreferredFrameRateRange: ca_range];
                        self.range = Some(range);
                    }
                    if self.paused {
                        let _: () = msg_send![self.link, setPaused: NO];
                        self.paused = false;
                    }
                }
            }
        }
    }

    pub(crate) fn is_running(&self) -> bool {
        !self.paused
    }
}

impl Drop for ViewDisplayLink {
    fn drop(&mut self) {
        unsafe {
            // Removes the link from the run loop and releases its target (the
            // view); no callback runs after this.
            let _: () = msg_send![self.link, invalidate];
            let _: () = msg_send![self.link, release];
        }
        self.link = nil;
    }
}
