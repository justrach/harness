//! ⌘Q sits next to ⌘W, and quitting stops the chats running on this computer.
//! While a chat is running, the key has to be held to quit, so a slip costs
//! nothing. Only the keyboard is guarded: choosing Quit from the menu or the
//! Dock is already deliberate, and a system shutdown must not wait for anyone.
use std::{cell::Cell, rc::Rc, time::Duration};

use gpui::{App, Global};

/// Long enough that a slip is over, short enough not to feel like a wait.
pub(crate) const HOLD: Duration = Duration::from_millis(800);
const POLL: Duration = Duration::from_millis(30);
/// A tap has to be able to say why nothing happened.
const HINT_AFTER_RELEASE: Duration = Duration::from_millis(1500);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct KeyPress {
    pub(crate) code: u16,
    pub(crate) repeat: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum QuitPress {
    Now,
    StartHold(u16),
    Ignore,
}

/// What a Quit request does. `press` is the key behind it, if a key was.
pub(crate) fn quit_press(press: Option<KeyPress>, chat_running: bool, holding: bool) -> QuitPress {
    match press {
        Some(press) if chat_running => {
            // A held key repeats. Those repeats aren't new requests, and must
            // not start another hold once this one has finished or been refused.
            if holding || press.repeat {
                QuitPress::Ignore
            } else {
                QuitPress::StartHold(press.code)
            }
        }
        _ => QuitPress::Now,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum HoldStep {
    Wait,
    Quit,
    Cancel,
}

pub(crate) fn hold_step(held_for: Duration, key_down: bool) -> HoldStep {
    if !key_down {
        HoldStep::Cancel
    } else if held_for >= HOLD {
        HoldStep::Quit
    } else {
        HoldStep::Wait
    }
}

#[derive(Default)]
struct QuitHold {
    holding: bool,
    hint: bool,
    /// Which press the hint belongs to, so an old press can't hide a new one's.
    press: u64,
}

impl Global for QuitHold {}

pub(crate) fn holding(cx: &App) -> bool {
    cx.try_global::<QuitHold>().is_some_and(|hold| hold.holding)
}

pub(crate) fn hint_visible(cx: &App) -> bool {
    cx.try_global::<QuitHold>().is_some_and(|hold| hold.hint)
}

pub(crate) fn chat_is_running(cx: &App) -> bool {
    cx.try_global::<crate::ReopenState>()
        .is_some_and(|reopen| reopen.state.read(cx).any_chat_running(chrono::Utc::now()))
}

/// Show the hint and watch the key: `quit` runs once it has been held for
/// [`HOLD`]; letting go cancels and leaves the hint up long enough to read.
pub(crate) fn begin(
    cx: &mut App,
    key_down: impl Fn() -> bool + 'static,
    quit: impl FnOnce(&mut App) + 'static,
) {
    let hold = cx.default_global::<QuitHold>();
    hold.holding = true;
    hold.hint = true;
    hold.press += 1;
    let press = hold.press;
    cx.refresh_windows();
    let quit = Rc::new(Cell::new(Some(quit)));
    cx.spawn(async move |cx| {
        let mut held_for = Duration::ZERO;
        let step = loop {
            cx.background_executor().timer(POLL).await;
            held_for += POLL;
            match hold_step(held_for, key_down()) {
                HoldStep::Wait => {}
                step => break step,
            }
        };
        let _ = cx.update(|cx| {
            let hold = cx.default_global::<QuitHold>();
            hold.holding = false;
            if step == HoldStep::Quit {
                hold.hint = false;
                cx.refresh_windows();
                if let Some(quit) = quit.take() {
                    quit(cx);
                }
            }
        });
        if step == HoldStep::Cancel {
            cx.background_executor().timer(HINT_AFTER_RELEASE).await;
            let _ = cx.update(|cx| {
                let hold = cx.default_global::<QuitHold>();
                if hold.press == press && !hold.holding {
                    hold.hint = false;
                    cx.refresh_windows();
                }
            });
        }
    })
    .detach();
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: u16 = 12;

    fn press(repeat: bool) -> Option<KeyPress> {
        Some(KeyPress { code: KEY, repeat })
    }

    #[test]
    fn only_a_key_press_during_a_running_chat_has_to_be_held() {
        assert_eq!(
            quit_press(press(false), true, false),
            QuitPress::StartHold(KEY)
        );
        assert_eq!(quit_press(press(false), false, false), QuitPress::Now);
        // The menu, the Dock and a shutdown aren't slips.
        assert_eq!(quit_press(None, true, false), QuitPress::Now);
        assert_eq!(quit_press(None, false, false), QuitPress::Now);
    }

    #[test]
    fn a_held_key_repeating_is_not_a_new_request() {
        assert_eq!(quit_press(press(true), true, true), QuitPress::Ignore);
        assert_eq!(quit_press(press(false), true, true), QuitPress::Ignore);
        // The hold ended, and the key is still going: a save prompt that
        // refused the quit must not be asked again and again.
        assert_eq!(quit_press(press(true), true, false), QuitPress::Ignore);
    }

    #[test]
    fn letting_go_always_cancels_even_at_the_last_moment() {
        assert_eq!(hold_step(Duration::ZERO, true), HoldStep::Wait);
        assert_eq!(hold_step(HOLD - POLL, true), HoldStep::Wait);
        assert_eq!(hold_step(HOLD, true), HoldStep::Quit);
        assert_eq!(hold_step(Duration::ZERO, false), HoldStep::Cancel);
        assert_eq!(hold_step(HOLD * 2, false), HoldStep::Cancel);
    }

    /// The hold counts its polls, so the fake clock has to pass through each one.
    fn advance(cx: &mut gpui::TestAppContext, by: Duration) {
        for _ in 0..by.as_millis() / POLL.as_millis() {
            cx.executor().advance_clock(POLL);
            cx.run_until_parked();
        }
    }

    fn start(cx: &mut gpui::TestAppContext) -> (Rc<Cell<bool>>, Rc<Cell<usize>>) {
        let down = Rc::new(Cell::new(true));
        let quits = Rc::new(Cell::new(0));
        cx.update(|cx| {
            let key = down.clone();
            let count = quits.clone();
            begin(cx, move || key.get(), move |_| count.set(count.get() + 1));
            assert!(holding(cx));
            assert!(hint_visible(cx));
        });
        (down, quits)
    }

    #[gpui::test]
    fn holding_the_key_long_enough_quits_once(cx: &mut gpui::TestAppContext) {
        let (_down, quits) = start(cx);
        advance(cx, HOLD - POLL * 2);
        assert_eq!(quits.get(), 0, "not yet");
        advance(cx, POLL * 4);
        assert_eq!(quits.get(), 1);
        cx.update(|cx| {
            assert!(!holding(cx));
            assert!(!hint_visible(cx));
        });
        advance(cx, HOLD * 2);
        assert_eq!(quits.get(), 1, "once");
    }

    #[gpui::test]
    fn a_tap_never_quits_and_the_hint_stays_long_enough_to_read(cx: &mut gpui::TestAppContext) {
        let (down, quits) = start(cx);
        advance(cx, POLL);
        down.set(false);
        advance(cx, POLL);
        cx.update(|cx| {
            assert!(!holding(cx));
            assert!(hint_visible(cx), "the tap has to say why nothing happened");
        });
        advance(cx, HINT_AFTER_RELEASE + HOLD);
        assert_eq!(quits.get(), 0);
        cx.update(|cx| assert!(!hint_visible(cx)));
    }

    #[gpui::test]
    fn an_old_tap_does_not_hide_a_new_taps_hint(cx: &mut gpui::TestAppContext) {
        let (first, _) = start(cx);
        first.set(false);
        advance(cx, POLL);
        advance(cx, HINT_AFTER_RELEASE - HOLD);
        let (second, _) = start(cx);
        second.set(false);
        advance(cx, POLL);
        // Past the end of the first tap's hint, well inside the second's.
        advance(cx, HOLD + POLL);
        cx.update(|cx| assert!(hint_visible(cx)));
        advance(cx, HINT_AFTER_RELEASE);
        cx.update(|cx| assert!(!hint_visible(cx)));
    }
}
