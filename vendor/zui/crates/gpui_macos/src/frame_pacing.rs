//! The frame-rate rule for a window's display link. It has no AppKit calls so
//! tests can call it directly.
//!
//! A window asks for frames while something is invalidated (scrolling,
//! momentum, animation, streaming text) and stops asking once a frame finds
//! nothing to draw. While it asks, the link runs at the screen's full rate
//! (120 Hz on ProMotion, 240 Hz on a 240 Hz monitor), or at a lower cap that
//! GPUI sets for animation-only frames (an inactive window, thermal
//! pressure). When it stops asking, the link pauses: no callbacks, no wakeups.

use std::time::Duration;

/// Used when a screen doesn't report its rate (`maximumFramesPerSecond` is 0
/// for some virtual and mirrored displays).
pub(crate) const FALLBACK_MAX_FPS: u32 = 60;

/// The `CAFrameRateRange` a display link should request, in frames per second.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct FrameRateRange {
    pub minimum: f32,
    pub maximum: f32,
    pub preferred: f32,
}

/// What a window's display link should do.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum FramePacing {
    /// Nothing is invalidated: deliver no callbacks.
    Paused,
    /// Deliver callbacks in this range.
    Running(FrameRateRange),
}

/// Picks the display link's pacing.
///
/// * `frame_requested`: whether the window has invalidated content waiting
///   for a frame (or is animating).
/// * `screen_max_fps`: `NSScreen.maximumFramesPerSecond` of the window's
///   screen; 0 or less means unknown.
/// * `min_frame_interval`: the shortest interval GPUI wants between frames,
///   if it throttles this window (for example 33 ms for an animation in an
///   inactive window). `None` means no throttle.
pub(crate) fn frame_pacing(
    frame_requested: bool,
    screen_max_fps: i64,
    min_frame_interval: Option<Duration>,
) -> FramePacing {
    if !frame_requested {
        return FramePacing::Paused;
    }
    let screen_max = if screen_max_fps > 0 {
        screen_max_fps as f32
    } else {
        FALLBACK_MAX_FPS as f32
    };
    let maximum = match min_frame_interval {
        Some(interval) if !interval.is_zero() => {
            // Round to whole frames per second so 33.333 ms asks for 30 Hz.
            let cap = (1.0 / interval.as_secs_f64()).round() as f32;
            cap.clamp(1.0, screen_max)
        }
        _ => screen_max,
    };
    FramePacing::Running(FrameRateRange {
        // Not lower: given a range, a CADisplayLink whose frames sometimes
        // wait for a drawable settles at its bottom (measured: 120 fps on a
        // 240 Hz display with a minimum of 120). Low Power Mode and thermal
        // limits still override this.
        minimum: maximum,
        maximum,
        preferred: maximum,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn running(fps: f32) -> FramePacing {
        FramePacing::Running(FrameRateRange {
            minimum: fps,
            maximum: fps,
            preferred: fps,
        })
    }

    #[test]
    fn idle_window_pauses_the_link() {
        for max_fps in [0, 60, 120, 240] {
            assert_eq!(frame_pacing(false, max_fps, None), FramePacing::Paused);
            assert_eq!(
                frame_pacing(false, max_fps, Some(Duration::from_millis(33))),
                FramePacing::Paused
            );
        }
    }

    #[test]
    fn active_window_asks_for_the_screens_full_rate() {
        assert_eq!(frame_pacing(true, 60, None), running(60.0));
        assert_eq!(frame_pacing(true, 120, None), running(120.0));
        assert_eq!(frame_pacing(true, 144, None), running(144.0));
        assert_eq!(frame_pacing(true, 240, None), running(240.0));
    }

    #[test]
    fn unknown_screen_rate_falls_back_to_60() {
        assert_eq!(frame_pacing(true, 0, None), running(60.0));
        assert_eq!(frame_pacing(true, -1, None), running(60.0));
    }

    #[test]
    fn throttled_animation_asks_for_the_cap_not_the_screen_rate() {
        // An inactive window's animation: GPUI draws every 33.3 ms.
        let inactive = Some(Duration::from_micros(33_333));
        assert_eq!(frame_pacing(true, 240, inactive), running(30.0));
        assert_eq!(frame_pacing(true, 120, inactive), running(30.0));
        // Thermal pressure: every 16.7 ms.
        let thermal = Some(Duration::from_micros(16_667));
        assert_eq!(frame_pacing(true, 240, thermal), running(60.0));
        // A cap above the screen's rate is the screen's rate.
        assert_eq!(
            frame_pacing(true, 60, Some(Duration::from_millis(4))),
            running(60.0)
        );
        // A zero interval is no cap.
        assert_eq!(
            frame_pacing(true, 120, Some(Duration::ZERO)),
            running(120.0)
        );
    }
}
