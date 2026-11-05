//! A manual entry into a completed turn's file review. Tool records are a cue,
//! not a complete working-tree inventory or an attribution of every edit.
use super::workspace_panels::PanelTab;
use super::*;
use harness_doc::{MessagePart, MessageRole, SessionMessageEntry};
use harness_proto::ToolCall;

/// What the latest turn reports editing. A cue, as above: it says nothing of
/// edits made outside the agent's tools.
#[derive(Debug, Default, PartialEq, Eq)]
struct RecordedEdits {
    /// Edited paths in first-touch order, each once.
    paths: Vec<String>,
    additions: u64,
    deletions: u64,
}

impl RecordedEdits {
    /// "1 file changed" / "3 files changed".
    fn title(&self) -> String {
        match self.paths.len() {
            1 => "1 file changed".to_string(),
            count => format!("{count} files changed"),
        }
    }

    /// Up to three file names (not full paths), then "+N more".
    fn names(&self) -> String {
        let mut names: Vec<&str> = self
            .paths
            .iter()
            .take(3)
            .map(|path| path.rsplit('/').next().unwrap_or(path))
            .collect();
        let more = self.paths.len().saturating_sub(3);
        let more_label = format!("+{more} more");
        if more > 0 {
            names.push(&more_label);
        }
        names.join(", ")
    }
}

fn recorded_edits(entries: &[SessionMessageEntry]) -> RecordedEdits {
    let mut edits = RecordedEdits::default();
    let Some(start) = entries
        .iter()
        .rposition(|entry| entry.role == MessageRole::User)
    else {
        return edits;
    };
    for part in entries[start + 1..].iter().flat_map(|entry| &entry.parts) {
        let MessagePart::Tool {
            call,
            resolved: true,
            is_error: false,
            diff,
            diff_stats,
            ..
        } = part
        else {
            continue;
        };
        let path = match call {
            ToolCall::WriteFile { path, .. } | ToolCall::EditFile { path, .. } => {
                Some(path.clone())
            }
            ToolCall::ApplyPatch { path } => path.clone(),
            _ => continue,
        };
        let mut stats = diff_stats.clone().unwrap_or_default();
        if stats.is_empty()
            && let Some(diff) = diff
        {
            stats.push(harness_doc::diff_stat(diff));
        }
        let mut recorded: Vec<String> = stats.iter().map(|stat| stat.path.clone()).collect();
        if recorded.is_empty() {
            recorded.extend(path);
        }
        for stat in &stats {
            edits.additions = edits.additions.saturating_add(stat.additions);
            edits.deletions = edits.deletions.saturating_add(stat.deletions);
        }
        for path in recorded {
            if !path.is_empty() && !edits.paths.contains(&path) {
                edits.paths.push(path);
            }
        }
    }
    edits
}

fn recorded_edit_paths(entries: &[SessionMessageEntry]) -> Vec<String> {
    recorded_edits(entries).paths
}

impl Shell {
    pub(super) fn render_turn_changes_card(&self, cx: &Context<Self>) -> Option<AnyElement> {
        let state = self.state.read(cx);
        let chat = state.selected_chat_row()?;
        chat.cwd.as_ref()?;
        if matches!(
            state.indicator_for(&chat.id, Utc::now()),
            Indicator::Working | Indicator::AwaitingInput
        ) || self.composer.read(cx).is_sending()
        {
            return None;
        }
        let edits = recorded_edits(&state.transcript);
        if edits.paths.is_empty() {
            return None;
        }
        let theme = Theme::of(cx);
        Some(
            div()
                .id("turn-changes-review")
                .role(gpui::Role::Button)
                .aria_label("Review all uncommitted changes, including your edits")
                .debug_selector(|| "turn-changes-review".to_owned())
                .absolute()
                .top(px(-54.0))
                // Match the inner composer surface, not its padded wrapper.
                .left(px(Theme::SPACE_LG))
                .right(px(Theme::SPACE_LG))
                .h(px(46.0))
                .px(px(12.0))
                .rounded(px(10.0))
                .border_1()
                .border_color(theme.border)
                .bg(theme.surface_raised)
                .hover(|s| s.bg(theme.surface_raised_hover))
                .flex()
                .items_center()
                .gap(px(10.0))
                .cursor_pointer()
                .child(
                    icon(icons::DOCUMENT)
                        .size(px(18.0))
                        .text_color(theme.text_muted),
                )
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .gap(px(2.0))
                        .child(
                            div()
                                .debug_selector(|| "turn-changes-title".to_owned())
                                .text_size(px(13.0))
                                .text_color(theme.text)
                                .child(edits.title()),
                        )
                        .child(
                            div()
                                .debug_selector(|| "turn-changes-names".to_owned())
                                .truncate()
                                .text_size(px(11.0))
                                .text_color(theme.text_muted)
                                .child(edits.names()),
                        ),
                )
                .when(edits.additions > 0 || edits.deletions > 0, |card| {
                    card.child(
                        div()
                            .debug_selector(|| "turn-changes-counts".to_owned())
                            .flex_none()
                            .flex()
                            .gap(px(6.0))
                            .font_family(theme.font_mono.clone())
                            .text_size(px(12.0))
                            .child(
                                div()
                                    .text_color(theme.success)
                                    .child(format!("+{}", edits.additions)),
                            )
                            .child(
                                div()
                                    .text_color(theme.danger)
                                    .child(format!("-{}", edits.deletions)),
                            ),
                    )
                })
                .child(
                    icon(icons::ALT_ARROW_RIGHT)
                        .size(px(16.0))
                        .text_color(theme.text_muted),
                )
                .tab_index(0)
                .focus_visible(|style| style.border_color(theme.accent))
                .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, _, cx| {
                    if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                        cx.stop_propagation();
                        this.show_turn_changes(cx);
                    }
                }))
                .on_click(cx.listener(|this, _, _, cx| {
                    this.show_turn_changes(cx);
                }))
                .into_any_element(),
        )
    }

    /// Always select the whole working tree, including when reusing a tab that
    /// was showing Branch or Latest turn. Pinned history/commit tabs stay put.
    pub(super) fn show_turn_changes(&mut self, cx: &mut Context<Self>) -> Option<u64> {
        let chat_id = self.state.read(cx).selected_chat.clone()?;
        let key = self.panel_key(cx);
        let existing = self
            .right_tabs
            .get(&key)
            .into_iter()
            .flatten()
            .find_map(|surface| {
                let RightSurface::Diff(id) = surface else {
                    return None;
                };
                self.diffs
                    .get(id)
                    .filter(|changes| changes.read(cx).can_review_working_tree(&chat_id, cx))
                    .map(|changes| (*id, changes.clone()))
            });
        if let Some((id, changes)) = existing {
            changes.update(cx, |changes, cx| changes.review_working_tree(chat_id, cx));
            self.set_right_active(RightSurface::Diff(id), cx);
            Some(id)
        } else {
            let changes = cx.new(|cx| {
                let mut changes = Changes::new(self.state.clone(), cx);
                changes.review_working_tree(chat_id, cx);
                changes
            });
            self.register_diff_surface(changes, cx);
            Some(self.diff_seq)
        }
    }

    /// Closing a tab, panel or window follows the same rule as Done: the user
    /// must save or cancel a nonempty note. Reveal its review so the existing
    /// footer explains why closing was stopped.
    pub(super) fn retain_pending_review_draft(&mut self, id: u64, cx: &mut Context<Self>) -> bool {
        if !self
            .diffs
            .get(&id)
            .is_some_and(|changes| changes.read(cx).has_pending_review_draft(cx))
        {
            return false;
        }
        let surface = RightSurface::Diff(id);
        let owner = self
            .right_tabs
            .iter()
            .find_map(|(owner, tabs)| tabs.contains(&surface).then(|| owner.clone()));
        if let Some(owner) = owner {
            self.panels.update(&owner, |panel| {
                panel.changes_open = true;
                panel.right_active = surface;
            });
            if let Some(session) = owner.strip_prefix("workspace:") {
                self.activate_workspace_session(session, cx);
            } else if owner.is_empty() {
                self.apply_nav(NavEntry::Chat(owner.clone()), cx);
            } else {
                self.open_chat_preserving_tabs(owner.clone(), cx);
            }
            self.reveal_workspace_surface(owner, surface, cx);
        }
        cx.notify();
        true
    }

    pub(super) fn finish_changes_review(
        &mut self,
        id: u64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.retain_pending_review_draft(id, cx) {
            return;
        }
        let origin = self
            .diffs
            .get(&id)
            .and_then(|changes| changes.read(cx).context_chat_id(cx));
        let location = self.panel_layout(cx).and_then(|layout| layout.panels.iter().find_map(|panel| {
            panel.tabs.iter().find(|tab| matches!(tab, PanelTab::Surface { surface: RightSurface::Diff(tab_id), .. } if *tab_id == id))
                .map(|tab| (panel.id, tab.clone()))
        }));
        if let Some((panel, tab)) = location {
            // Keep the origin selected while its review closes; do not briefly
            // select a blank canvas and restart the chat's feeds.
            if let Some(origin) = origin.as_ref() {
                let origin_tab = PanelTab::Chat(origin.clone());
                let target = self.panel_layout(cx).and_then(|layout| {
                    layout
                        .panels
                        .iter()
                        .find(|panel| panel.tabs.contains(&origin_tab))
                        .map(|panel| panel.id)
                });
                if let Some(target) = target {
                    self.focus_workspace_tab(target, origin_tab, window, cx);
                }
            }
            self.close_workspace_tab(panel, tab, window, cx);
            if self.panel_layout(cx).is_some_and(|layout| {
                layout.panels.len() > 1
                    && layout
                        .panels
                        .iter()
                        .any(|candidate| candidate.id == panel && candidate.tabs.is_empty())
            }) {
                self.close_workspace_panel(panel, window, cx);
            }
            if let Some(origin) = origin {
                let tab = PanelTab::Chat(origin.clone());
                let target = self.panel_layout(cx).and_then(|layout| {
                    layout
                        .panels
                        .iter()
                        .find(|panel| panel.tabs.contains(&tab))
                        .map(|panel| panel.id)
                });
                if let Some(target) = target {
                    self.focus_workspace_tab(target, tab, window, cx);
                } else {
                    self.reveal_workspace_chat(origin, cx);
                    let target = self.panel_layout(cx).unwrap().focused;
                    self.focus_workspace_tab(target, tab, window, cx);
                }
            }
        }
    }

    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_turn_review_card_center(&self, cx: &App) -> Point<Pixels> {
        let bounds = self
            .composer
            .read(cx)
            .surface_bounds()
            .get()
            .expect("review composer has been painted");
        gpui::point(bounds.center().x, bounds.top() - px(31.0))
    }

    /// Native fixture phases include a real comment editor and locally staged
    /// note. No destructive RPC or model request is sent by this fixture.
    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_turn_changes_review(
        &mut self,
        phase: u8,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if phase == 0 {
            if !self
                .chat_tabs
                .iter()
                .any(|session| session.id == "fixture-design-session")
            {
                self.fixture_session_hierarchy(0, window, cx);
            } else {
                self.activate_workspace_session("fixture-design-session", cx);
            }
            let layout = self.panel_layout_mut(cx);
            layout.panels.truncate(1);
            layout.panels[0].tabs = vec![PanelTab::Chat("launch-0".into())];
            layout.panels[0].active = 0;
            layout.panels[0].share = 1.0;
            layout.focused = layout.panels[0].id;
            layout.expanded = None;
            let panel = layout.focused;
            self.focus_workspace_tab(panel, PanelTab::Chat("launch-0".into()), window, cx);
            self.state.update(cx, |state, cx| {
                state.purge_review_comments("launch-0");
                if let Some(chat) = state.chats.iter_mut().find(|chat| chat.id == "launch-0") {
                    chat.checkout_id = Some("fixture-review".into());
                }
                let entries = serde_json::from_value(serde_json::json!([
                    {"id":"review-prompt","role":"user","parts":[{"id":"p","kind":"text","text":"Make the welcome message warmer and adjust the spacing."}],"createdAt":1792620000000_i64,"deviceId":"fixture","status":"complete"},
                    {"id":"review-reply","role":"assistant","parts":[
                        {"kind":"tool","id":"edit-greeting","call":ToolCall::EditFile { path:"src/greeting.rs".into(), old_string:None, new_string:None },"resolved":true,"isError":false},
                        {"kind":"tool","id":"edit-theme","call":ToolCall::EditFile { path:"src/theme.rs".into(), old_string:None, new_string:None },"resolved":true,"isError":false},
                        {"id":"r","kind":"text","text":"The welcome message is warmer, and the spacing is more comfortable. You can review the files before continuing."}
                    ],"createdAt":1792620000001_i64,"deviceId":"fixture","status":"complete"}
                ])).expect("synthetic review transcript");
                state.fixture_review_transcript(entries, cx);
            });
            self.composer.update(cx, |composer, cx| {
                composer.fixture_set_draft("", cx);
                composer.focus_pending = false;
            });
        } else if phase == 1 {
            // The native harness clicks the painted card before entering this phase.
            let id = self.diff_seq;
            assert!(
                self.diffs.contains_key(&id),
                "clicking Review changes must open the real Diff tab"
            );
            {
                let chat = self.state.read(cx).chat_row("launch-0").unwrap().clone();
                let patch = "diff --git a/src/greeting.rs b/src/greeting.rs\n--- a/src/greeting.rs\n+++ b/src/greeting.rs\n@@ -1,3 +1,3 @@\n pub fn welcome() -> &'static str {\n-    \"Welcome\"\n+    \"Welcome back. Let's make something good.\"\n }\ndiff --git a/src/theme.rs b/src/theme.rs\n--- a/src/theme.rs\n+++ b/src/theme.rs\n@@ -1,3 +1,3 @@\n-pub const CONTENT_GAP: f32 = 8.0;\n+pub const CONTENT_GAP: f32 = 12.0;\n pub const CARD_RADIUS: f32 = 10.0;\n pub const BODY_SIZE: f32 = 14.0;\n";
                let files = ["src/greeting.rs", "src/theme.rs"]
                    .into_iter()
                    .map(|path| harness_proto::DiffFileSummary {
                        path: path.into(),
                        old_path: None,
                        status: "modified".into(),
                        additions: 1,
                        deletions: 1,
                        binary: false,
                    })
                    .collect();
                let diff = harness_proto::CheckoutDiff {
                    checkout_id: "fixture-review".into(),
                    device_id: chat.device_id,
                    cwd: chat.cwd.unwrap(),
                    patch: patch.into(),
                    files,
                    additions: 2,
                    deletions: 2,
                    truncated: false,
                    checksum: "fixture-review-v1".into(),
                    updated_at: Utc::now(),
                };
                self.diffs
                    .get(&id)
                    .unwrap()
                    .clone()
                    .update(cx, |changes, cx| changes.fixture_review_diff(diff, cx));
            }
        } else if phase == 2 {
            if let Some(changes) = self.diffs.get(&self.diff_seq) {
                self.discard_working_tree = changes
                    .read(cx)
                    .discard_request(cx)
                    .map(DiscardWorkingTreeFlow::Confirm);
            }
        } else if phase == 3 {
            self.discard_working_tree = None;
            self.finish_changes_review(self.diff_seq, window, cx);
        } else if matches!(phase, 4 | 5) {
            self.diffs
                .get(&self.diff_seq)
                .unwrap()
                .clone()
                .update(cx, |changes, cx| {
                    changes.fixture_review_comment(phase == 5, window, cx);
                });
            assert_eq!(
                self.state.read(cx).review_comments("launch-0").len(),
                usize::from(phase == 5)
            );
        } else if phase == 6 {
            self.finish_changes_review(self.diff_seq, window, cx);
            assert!(
                self.diffs
                    .get(&self.diff_seq)
                    .is_some_and(|changes| { changes.read(cx).has_pending_review_draft(cx) }),
                "Done must keep the unfinished comment open"
            );
        } else if phase == 7 {
            let location = self.panel_layout(cx).and_then(|layout| {
                layout.panels.iter().find_map(|panel| {
                    panel.tabs.iter().find(|tab| matches!(tab, PanelTab::Surface { surface: RightSurface::Diff(id), .. } if *id == self.diff_seq))
                        .map(|tab| (panel.id, tab.clone()))
                })
            }).expect("review tab is open");
            self.close_workspace_tab(location.0, location.1, window, cx);
            assert!(
                self.diffs
                    .get(&self.diff_seq)
                    .is_some_and(|changes| { changes.read(cx).has_pending_review_draft(cx) }),
                "Closing the tab must keep the unfinished comment open"
            );
        }
        if phase == 8 {
            assert!(
                self.discard_working_tree.is_none(),
                "Cancel must dismiss the discard dialog"
            );
            assert!(
                self.diffs.contains_key(&self.diff_seq),
                "Cancel must retain the review"
            );
            assert!(self.panel_layout(cx).is_some_and(|layout| layout.panels.iter().any(|panel| {
                matches!(panel.selected(), Some(PanelTab::Surface { surface: RightSurface::Diff(id), .. }) if *id == self.diff_seq)
            })), "Cancel must leave the review visible");
            assert_eq!(
                self.state.read(cx).review_comments("launch-0").len(),
                1,
                "Cancel must preserve the staged note"
            );
        }
        window.blur();
        cx.notify();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn entry(role: &str, parts: Vec<MessagePart>) -> SessionMessageEntry {
        let mut entry: SessionMessageEntry = serde_json::from_value(
            serde_json::json!({"id":"e","role":role,"parts":[],"createdAt":0,"deviceId":"d"}),
        )
        .unwrap();
        entry.parts = parts;
        entry
    }
    fn tool(path: &str, resolved: bool, error: bool) -> MessagePart {
        serde_json::from_value(serde_json::json!({"kind":"tool","id":path,"call":ToolCall::EditFile { path: path.into(), old_string:None, new_string:None },"resolved":resolved,"isError":error})).unwrap()
    }
    #[test]
    fn turn_review_counts_only_successful_recorded_edits_in_latest_turn() {
        let entries = vec![
            entry("user", vec![]),
            entry("assistant", vec![tool("old.rs", true, false)]),
            entry("user", vec![]),
            entry(
                "assistant",
                vec![
                    tool("a.rs", true, false),
                    tool("a.rs", true, false),
                    tool("failed.rs", true, true),
                    tool("pending.rs", false, false),
                ],
            ),
        ];
        assert_eq!(recorded_edit_paths(&entries), vec!["a.rs"]);
    }
    #[test]
    fn turn_review_does_not_infer_files_from_commands_or_missing_prompt() {
        assert!(
            recorded_edit_paths(&[entry("assistant", vec![tool("a.rs", true, false)])]).is_empty()
        );
        let exec = serde_json::from_value(serde_json::json!({"kind":"tool","id":"x","call":ToolCall::Exec { command:"touch unseen.rs".into() },"resolved":true,"isError":false})).unwrap();
        assert!(
            recorded_edit_paths(&[entry("user", vec![]), entry("assistant", vec![exec])])
                .is_empty()
        );
    }
    #[gpui::test]
    fn turn_review_reuses_tab_and_done_only_closes_review(cx: &mut gpui::TestAppContext) {
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
            settings::init(settings::UiSettings::default(), dir.path(), cx);
        });
        let shell = cx.add_window(|_, cx| {
            let state = cx.new(|_| {
                let mut state = AppState::new();
                state.chats.push(
                    serde_json::from_value(serde_json::json!({
                        "id":"review-chat", "deviceId":"local", "archived":false,
                        "cwd":"/synthetic/project", "createdAt":"2026-11-01T00:00:00Z"
                    }))
                    .unwrap(),
                );
                state.selected_chat = Some("review-chat".into());
                state
            });
            Shell::new(
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
            )
        });
        shell
            .update(cx, |shell, window, cx| {
                shell.ensure_workspace_sessions(cx);
                shell.sync_panel_workspace(cx);
                let first = shell.show_turn_changes(cx).unwrap();
                let reused = shell.show_turn_changes(cx).unwrap();
                assert_eq!(first, reused);
                assert_eq!(shell.diffs.len(), 1);
                let review = shell.diffs.get(&first).unwrap().clone();
                review.update(cx, |changes, cx| {
                    changes.test_open_review_draft("Keep this note", window, cx)
                });
                shell.finish_changes_review(first, window, cx);
                assert!(
                    shell.diffs.contains_key(&first),
                    "Done must retain an unfinished note"
                );
                let (review_panel, review_tab) = shell
                    .panel_layout(cx)
                    .unwrap()
                    .panels
                    .iter()
                    .find_map(|panel| {
                        panel.tabs.iter().find_map(|tab| {
                            matches!(tab, PanelTab::Surface { surface: RightSurface::Diff(id), .. } if *id == first)
                                .then(|| (panel.id, tab.clone()))
                        })
                    })
                    .unwrap();
                let panel_tabs = |shell: &Shell, cx: &App| {
                    shell.panel_layout(cx).unwrap().panels.iter()
                        .map(|panel| (panel.id, panel.tabs.clone()))
                        .collect::<Vec<_>>()
                };
                let panels_before = panel_tabs(shell, cx);
                shell.close_workspace_tab(review_panel, review_tab.clone(), window, cx);
                assert!(shell.diffs.contains_key(&first), "Tab close must retain an unfinished note");
                shell.focus_workspace_tab(review_panel, review_tab, window, cx);
                assert!(shell.workspace_close_focused(window, cx), "Command-W must consume the close");
                assert!(shell.diffs.contains_key(&first), "Command-W must retain an unfinished note");
                shell.close_workspace_panel(review_panel, window, cx);
                assert!(shell.diffs.contains_key(&first), "Panel close must retain an unfinished note");
                assert_eq!(panel_tabs(shell, cx), panels_before);
                shell.close_right_surface(RightSurface::Diff(first), window, cx);
                assert!(shell.diffs.contains_key(&first), "Legacy surface close must retain an unfinished note");
                assert!(!shell.prepare_window_close(cx), "Window close must retain an unfinished note");
                assert!(!shell.prepare_quit(cx), "Quit must retain an unfinished note");
                assert!(shell.pending_exit.is_none(), "Blocked close must not run later automatically");
                assert!(review.read(cx).has_pending_review_draft(cx));
                review.update(cx, |changes, cx| {
                    changes.test_open_review_draft("", window, cx)
                });
                shell.finish_changes_review(first, window, cx);
                assert!(shell.diffs.is_empty());
                assert!(shell.diff_subs.is_empty());
                assert_eq!(
                    shell.panel_layout(cx).unwrap().panels.len(),
                    1,
                    "closing review removes only its empty panel"
                );
                assert!(shell.discard_working_tree.is_none());
                assert!(shell.discard_working_tree_task.is_none());
                let state = shell.state.read(cx);
                assert_eq!(state.selected_chat.as_deref(), Some("review-chat"));
                assert_eq!(state.chats.len(), 1);
                assert!(!state.chats[0].archived);
            })
            .unwrap();
    }

    #[test]
    fn the_card_names_three_files_then_counts_the_rest() {
        let edits = |paths: &[&str]| RecordedEdits {
            paths: paths.iter().map(|path| (*path).to_string()).collect(),
            ..Default::default()
        };
        assert_eq!(edits(&["src/a.rs"]).title(), "1 file changed");
        assert_eq!(edits(&["src/a.rs"]).names(), "a.rs");
        let many = edits(&["src/a.rs", "b.rs", "x/y/c.rs", "d.rs", "e.rs"]);
        assert_eq!(many.title(), "5 files changed");
        assert_eq!(many.names(), "a.rs, b.rs, c.rs, +2 more");
    }

    #[test]
    fn the_card_adds_up_line_counts_without_overflowing() {
        let counted = |additions: u64, deletions: u64| {
            let mut part = tool("a.rs", true, false);
            if let MessagePart::Tool { diff_stats, .. } = &mut part {
                *diff_stats = Some(vec![harness_doc::ToolDiffStat {
                    path: "a.rs".into(),
                    additions,
                    deletions,
                }]);
            }
            part
        };
        let user = entry("user", vec![]);
        let reply = entry("assistant", vec![counted(u64::MAX, 2), counted(5, 3)]);
        let edits = recorded_edits(&[user, reply]);
        assert_eq!(edits.paths, ["a.rs"]);
        assert_eq!((edits.additions, edits.deletions), (u64::MAX, 5));
    }
}
