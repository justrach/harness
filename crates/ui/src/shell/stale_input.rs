//! Layout shortcuts pressed while the window was frozen (#342).
//!
//! Keys pressed while the main thread is blocked are not lost: macOS queues
//! them and delivers the whole backlog once the thread unblocks. A user who
//! pressed ⌘T or ⌘D a few times because nothing happened then got one empty
//! "New session" tab or split pane per press, all at once.
//!
//! A shortcut that reaches the app at least [`LATE_AFTER`] after it was
//! pressed ([`gpui::input_event_age`]) was buffered during a stall. Within one
//! burst of such late input, each layout command runs once: the first ⌘T of
//! the backlog opens a tab, the repeats behind it are dropped. A fresh press
//! always runs. Platforms that don't report input age are never gated.

use std::time::{Duration, Instant};

use gpui::{Action, App, Global, InteractiveElement, Window};

use super::{NewChatTab, NewTab, SplitChatDown, SplitChatRight};
use crate::terminal::panel::{SplitDown, SplitRight};

/// Input that waited this long for the main thread was buffered in a stall,
/// not pressed just now. Far above any frame or busy-update hitch.
pub(super) const LATE_AFTER: Duration = Duration::from_secs(1);

/// A backlog drains in a few milliseconds per event. Late input this far
/// apart belongs to separate stalls.
const BURST_GAP: Duration = Duration::from_secs(2);

/// Which layout commands already ran from the current burst of late input.
#[derive(Debug, Default)]
pub(super) struct LateCommandGate {
    ran: Vec<&'static str>,
    last_late: Option<Instant>,
}

impl Global for LateCommandGate {}

impl LateCommandGate {
    /// Whether `command`, dispatched at `now` from input that waited `age`,
    /// should run.
    pub(super) fn admit(
        &mut self,
        command: &'static str,
        age: Option<Duration>,
        now: Instant,
    ) -> bool {
        if self
            .last_late
            .is_some_and(|last| now.saturating_duration_since(last) > BURST_GAP)
        {
            self.ran.clear();
        }
        if !age.is_some_and(|age| age >= LATE_AFTER) {
            self.ran.clear();
            self.last_late = None;
            return true;
        }
        self.last_late = Some(now);
        if self.ran.contains(&command) {
            return false;
        }
        self.ran.push(command);
        true
    }
}

fn gate<A: Action>(_: &A, _: &mut Window, cx: &mut App) {
    let age = gpui::input_event_age();
    let command = A::name_for_type();
    if !cx
        .default_global::<LateCommandGate>()
        .admit(command, age, Instant::now())
    {
        tracing::info!(
            command,
            waited_ms = age.map_or(0, |age| age.as_millis() as u64),
            "dropped a repeated shortcut that was buffered while the window was blocked"
        );
        cx.stop_propagation();
    }
}

/// Gate the shell's layout commands (new tab, new chat tab, chat and terminal
/// splits) before their handlers run.
pub(super) fn coalesce_late_layout_commands<E: InteractiveElement>(root: E) -> E {
    root.capture_action(gate::<NewTab>)
        .capture_action(gate::<NewChatTab>)
        .capture_action(gate::<SplitChatRight>)
        .capture_action(gate::<SplitChatDown>)
        .capture_action(gate::<SplitRight>)
        .capture_action(gate::<SplitDown>)
}

#[cfg(test)]
mod tests {
    use super::*;

    const LATE: Option<Duration> = Some(Duration::from_secs(30));

    #[test]
    fn a_backlog_runs_each_layout_command_once() {
        let mut gate = LateCommandGate::default();
        let t0 = Instant::now();
        let at = |ms: u64| t0 + Duration::from_millis(ms);
        assert!(gate.admit("tab", LATE, at(0)));
        assert!(!gate.admit("tab", LATE, at(3)));
        assert!(
            gate.admit("split", LATE, at(6)),
            "a different command still runs"
        );
        assert!(!gate.admit("split", LATE, at(9)));
        assert!(!gate.admit("tab", LATE, at(12)));
    }

    #[test]
    fn fresh_presses_always_run() {
        let mut gate = LateCommandGate::default();
        let t0 = Instant::now();
        let at = |ms: u64| t0 + Duration::from_millis(ms);
        for ms in [0, 40, 80] {
            assert!(gate.admit("tab", None, at(ms)));
            assert!(gate.admit("tab", Some(Duration::from_millis(16)), at(ms + 1)));
        }
        // A backlog, then a fresh press: the press runs, and so does the
        // first command of the next backlog.
        assert!(gate.admit("tab", LATE, at(100)));
        assert!(!gate.admit("tab", LATE, at(101)));
        assert!(gate.admit("tab", Some(Duration::from_millis(5)), at(500)));
        assert!(gate.admit("tab", LATE, at(600)));
    }

    /// The #342 replay through the real keymap and shell listeners: three ⌘T
    /// and three ⌘D buffered behind a stall open one tab and one split; a
    /// fresh ⌘T afterwards still opens a tab.
    #[gpui::test]
    fn buffered_new_tab_and_split_shortcuts_run_once(cx: &mut gpui::TestAppContext) {
        use super::super::{EngineBootConfig, Shell};
        use crate::settings::{self, ShortcutId, platform_combo};
        use crate::state::AppState;
        use crate::theme::Theme;
        use gpui::AppContext as _;

        let dir = tempfile::tempdir().unwrap();
        cx.update(|cx| {
            gpui_base::init(cx);
            cx.set_global(Theme::default());
            crate::app_menus::init(cx);
            crate::history::init(
                Default::default(),
                Default::default(),
                Default::default(),
                Default::default(),
                cx,
            );
            settings::init(settings::UiSettings::expanded(), dir.path(), cx);
        });
        let window = cx.add_window(|_, cx| {
            let state = cx.new(|_| AppState::new());
            let mut shell = Shell::new(
                state,
                EngineBootConfig {
                    data_dir: dir.path().into(),
                    ipc_port: 0,
                    edge_url: "http://127.0.0.1:1".into(),
                    edge_token: None,
                    org_id: None,
                    codegraff_client_id: None,
                    default_harness: harness_proto::HarnessId::Mock,
                },
                cx,
            );
            shell.settings.space_filter = None;
            shell.state.update(cx, |state, cx| {
                state.local_device_id = Some("local".into());
                state.workspace_scope = Some(harness_proto::WorkspaceScope::Local);
                state.chats = vec![
                    serde_json::from_value(serde_json::json!({
                        "id": "current", "deviceId": "local", "archived": false,
                        "createdAt": chrono::Utc::now(),
                    }))
                    .unwrap(),
                ];
                state.select_chat(Some("current".into()), cx);
            });
            shell
        });
        let press = |combo: &str, age: Option<Duration>, cx: &mut gpui::TestAppContext| {
            let keystroke = gpui::Keystroke::parse(&platform_combo(combo)).unwrap();
            cx.update_window(window.into(), |_, window, cx| {
                window.draw(cx).clear();
                gpui::with_input_event_age(age, || {
                    window.dispatch_event(
                        gpui::PlatformInput::KeyDown(gpui::KeyDownEvent {
                            keystroke: keystroke.clone(),
                            is_held: false,
                            prefer_character_input: false,
                        }),
                        cx,
                    );
                    window.dispatch_event(
                        gpui::PlatformInput::KeyUp(gpui::KeyUpEvent { keystroke }),
                        cx,
                    );
                });
            })
            .unwrap();
            cx.run_until_parked();
        };
        let layout = |cx: &mut gpui::TestAppContext| {
            window
                .update(cx, |shell, _, cx| {
                    shell.panel_layout(cx).map_or((0, 1), |layout| {
                        (
                            layout.panels.iter().map(|panel| panel.tabs.len()).sum(),
                            layout.panels.len(),
                        )
                    })
                })
                .unwrap()
        };
        let new_tab = ShortcutId::NewSession.default_combo();
        let (tabs, panels) = layout(cx);

        // The backlog: ⌘T ⌘T ⌘T ⌘D ⌘D ⌘D, all pressed during the freeze.
        for _ in 0..3 {
            press(new_tab, LATE, cx);
        }
        assert_eq!(layout(cx), (tabs + 1, panels), "one tab, not one per press");
        let split = if cfg!(target_os = "macos") {
            "mod-d"
        } else {
            "ctrl-shift-o"
        };
        for _ in 0..3 {
            press(split, LATE, cx);
        }
        let (split_tabs, split_panels) = layout(cx);
        assert_eq!(split_panels, panels + 1, "one split, not one per press");

        // After the stall, a fresh press opens a tab as always.
        press(new_tab, Some(Duration::from_millis(4)), cx);
        assert_eq!(layout(cx), (split_tabs + 1, split_panels));
    }

    #[test]
    fn a_later_stall_starts_a_new_burst() {
        let mut gate = LateCommandGate::default();
        let t0 = Instant::now();
        assert!(gate.admit("tab", LATE, t0));
        assert!(!gate.admit("tab", LATE, t0 + Duration::from_millis(5)));
        // No fresh layout command in between, but minutes later: a new stall.
        assert!(gate.admit("tab", LATE, t0 + Duration::from_secs(120)));
    }
}
