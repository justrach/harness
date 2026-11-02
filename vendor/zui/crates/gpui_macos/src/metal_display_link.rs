//! Frame pacing on macOS 14 and later, built on `CAMetalDisplayLink`.
//!
//! Modified by Harness: adapted from upstream Zed commit 0373366f43
//! ("gpui_macos: Fix animations running at 30 fps on M5 Macs", #65472,
//! Apache-2.0). See vendor/zui/NOTICE.
//!
//! A `CADisplayLink` (`view_display_link.rs`) only says when to draw; the
//! renderer then asks the layer for a drawable with `nextDrawable`, which
//! blocks the main thread until the compositor releases one. On macOS 26 and
//! later that wait can take most of a frame (it held Harness's main thread in
//! `-[CAMetalLayer nextDrawable]` for about a fifth of the time while text
//! streamed), and input that arrives meanwhile waits too. A
//! `CAMetalDisplayLink` on the window's layer hands each update a drawable
//! that's already free, early enough to reach the display on time, so the
//! renderer draws into it instead and never waits.
//!
//! Pacing is the same as the view link's: `preferredFrameRateRange` asks for
//! the screen's full rate while frames are requested, or for GPUI's lower cap
//! when it throttles animation, and `paused = YES` while the window is idle,
//! so an idle window acquires no drawables.
//!
//! While a link drives the layer the renderer must not call `nextDrawable`
//! (see [`crate::renderer::MetalRenderer::set_display_link_attached`]): a
//! synchronous draw outside the link's update (activation, `displayLayer:`)
//! drops the link first and makes a new one afterwards.

use crate::{
    frame_pacing::{FramePacing, FrameRateRange},
    view_display_link::{CAFrameRateRange, NSRunLoopCommonModes},
};
use cocoa::base::{id, nil};
use objc::{
    class, msg_send,
    runtime::{Class, NO, YES},
    sel, sel_impl,
};

/// A window layer's `CAMetalDisplayLink`, scheduled on the main run loop in
/// common modes (so it keeps firing during live resize and menu tracking).
pub(crate) struct MetalDisplayLink {
    /// Retained `CAMetalDisplayLink`.
    link: id,
    paused: bool,
    /// The last range sent to the link.
    range: Option<FrameRateRange>,
}

impl MetalDisplayLink {
    /// Whether this system has `CAMetalDisplayLink` (macOS 14 and later).
    pub(crate) fn is_available() -> bool {
        Class::get("CAMetalDisplayLink").is_some()
    }

    /// Creates a paused link on `layer` whose updates go to `delegate`'s
    /// `metalDisplayLink:needsUpdate:`. Returns `None` before macOS 14.
    ///
    /// # Safety
    /// `layer` must be a live `CAMetalLayer` and `delegate` a live object that
    /// implements `metalDisplayLink:needsUpdate:` and outlives the link (the
    /// link holds its delegate weakly). Call on the main thread.
    pub(crate) unsafe fn new(layer: id, delegate: id) -> Option<Self> {
        unsafe {
            if layer.is_null() || delegate.is_null() {
                warn_once("the window has no layer or view yet");
                return None;
            }
            let class = Class::get("CAMetalDisplayLink")?;
            let link: id = msg_send![class, alloc];
            let link: id = msg_send![link, initWithMetalLayer: layer];
            if link.is_null() {
                warn_once("initWithMetalLayer: returned nil");
                return None;
            }
            let _: () = msg_send![link, setDelegate: delegate];
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

/// Says once a run why a link couldn't be made: a window that falls back retries each time
/// its frames start.
fn warn_once(reason: &str) {
    static WARNED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    if !WARNED.swap(true, std::sync::atomic::Ordering::Relaxed) {
        log::warn!("CAMetalDisplayLink not made: {reason}; using the view display link");
    }
}

impl Drop for MetalDisplayLink {
    fn drop(&mut self) {
        unsafe {
            // Removes the link from the run loop; no update arrives after this,
            // and the layer goes back to vending drawables through
            // `nextDrawable`.
            let _: () = msg_send![self.link, invalidate];
            let _: () = msg_send![self.link, release];
        }
        self.link = nil;
    }
}
