//! A focused window's animation frames run at the display's full rate only while someone is
//! typing, clicking or scrolling; ambient motion (a working agent's spinner) is held to 60 Hz.
//! On a 240 Hz display that motion otherwise redrew the whole window 240 times a second.
use gpui::{AMBIENT_AFTER_INPUT, AMBIENT_FRAME_INTERVAL, frame_interval_cap};
use std::time::Duration;

const MS: fn(u64) -> Duration = Duration::from_millis;

#[test]
fn ambient_animation_in_a_focused_window_is_held_to_60hz() {
    // A spinner, nobody using the app: 60 Hz, also before any input at all.
    assert_eq!(
        frame_interval_cap(true, true, false, Some(MS(5_000))),
        Some(AMBIENT_FRAME_INTERVAL)
    );
    assert_eq!(
        frame_interval_cap(true, true, false, None),
        Some(AMBIENT_FRAME_INTERVAL)
    );
    assert_eq!(AMBIENT_FRAME_INTERVAL, Duration::from_micros(16667));
}

#[test]
fn input_and_its_springs_keep_the_full_rate() {
    // Scrolling or typing a moment ago: full rate, through the springs and glides it starts.
    assert_eq!(frame_interval_cap(true, true, false, Some(MS(0))), None);
    assert_eq!(
        frame_interval_cap(true, true, false, Some(AMBIENT_AFTER_INPUT - MS(1))),
        None
    );
    assert_eq!(
        frame_interval_cap(true, true, false, Some(AMBIENT_AFTER_INPUT)),
        Some(AMBIENT_FRAME_INTERVAL)
    );
}

#[test]
fn only_animation_frames_are_capped_and_the_older_caps_hold() {
    // A frame for new content (no animation asked for it) is never held back.
    assert_eq!(frame_interval_cap(false, true, false, None), None);
    assert_eq!(frame_interval_cap(false, false, true, None), None);
    // An inactive window stays at 30 Hz, a hot machine at 60 Hz, input or not.
    assert_eq!(
        frame_interval_cap(true, false, false, Some(MS(0))),
        Some(Duration::from_micros(33333))
    );
    assert_eq!(
        frame_interval_cap(true, true, true, Some(MS(0))),
        Some(Duration::from_micros(16667))
    );
}
