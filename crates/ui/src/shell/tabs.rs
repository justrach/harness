//! Session navigation — the horizontal tab strip is gone (wing 2026-08-10):
//! the activity sidebar IS the session list, and the titlebar names the
//! selected session (harness brand icon + title). A `+` new-session button
//! lives in the titlebar's left control cluster while an existing session is
//! selected. `UiSettings.open_tabs` is legacy — no longer read or written.

use super::*;

/// The chat one step from `selected` in the sidebar `order`, wrapping at both
/// ends. Pure.
///
/// With nothing selected — the new-session canvas — cycling enters the list at
/// the end it would have wrapped to: the first row going forward, the last
/// going back. A selection that has since left the list (archived from another
/// device mid-cycle) is treated the same way rather than dead-ending.
pub(super) fn cycle_target(
    order: &[String],
    selected: Option<&str>,
    forward: bool,
) -> Option<String> {
    if order.is_empty() {
        return None;
    }
    let at = selected.and_then(|id| order.iter().position(|c| c == id));
    let next = match (at, forward) {
        (Some(at), true) => (at + 1) % order.len(),
        (Some(at), false) => (at + order.len() - 1) % order.len(),
        (None, true) => 0,
        (None, false) => order.len() - 1,
    };
    Some(order[next].clone())
}

pub(super) fn right_pane_expand_icon(expanded: bool) -> &'static str {
    if expanded {
        icons::COLLAPSE_ARROWS
    } else {
        icons::EXPAND_ARROWS
    }
}

struct PanelTitlebarWidths {
    surface_reveal: f32,
    files_controls: f32,
}

/// The two fixed right-edge anchors: the explorer toggle and the pane toggle
/// (28px each) with the same 4px gap the surface strip keeps between its
/// controls, so the two never render as one fused block.
const PANEL_TOGGLE_GAP: f32 = 4.0;
const PANEL_TOGGLE_SLOTS: f32 = 28.0 * 2.0 + PANEL_TOGGLE_GAP;

fn panel_titlebar_widths(
    surfaces_visible: f32,
    files_visible: f32,
    available: f32,
    right_pad: f32,
) -> PanelTitlebarWidths {
    // Caption controls occupy the far-right panel first. Subtract their
    // clearance once across the combined header, then split it at Files.
    // The explorer and pane toggles keep their slots even when closed.
    let files_controls = (files_visible - right_pad).max(PANEL_TOGGLE_SLOTS);
    let surfaces = surfaces_visible + files_visible - right_pad - files_controls;
    PanelTitlebarWidths {
        surface_reveal: surfaces.min(available - files_controls).max(0.0),
        files_controls,
    }
}

impl Shell {
    /// Navigation requests focus once the destination composer renders.
    pub(super) fn focus_composer(&mut self, cx: &mut Context<Self>) {
        self.composer.update(cx, |composer, cx| {
            composer.focus_pending = true;
            cx.notify();
        });
    }

    /// Ctrl+Tab / Ctrl+Shift+Tab: step through the sidebar's Sessions list in
    /// the order it is drawn. Selection is immediate (no MRU overlay held open
    /// on the modifier) — one press, one session.
    ///
    /// Chat-scoped chrome, like the panel toggles: gpui dispatches a matched
    /// binding before any `on_key_down`, so an unscoped cycle would fire
    /// underneath Settings (yanking the user off the page mid-record, since
    /// these are the very keys the shortcuts table invites them to press) or
    /// underneath the add-space palette, stranding the overlay over a session
    /// they never picked.
    pub(super) fn cycle_session(
        &mut self,
        forward: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !matches!(self.route, Route::Chat) || self.overlay_owns_keyboard(cx) {
            return;
        }
        // The same list `render_active_rows` draws and the jump shortcuts
        // count — one function, so neither can drift from the screen.
        let rows = self.workspace_session_sidebar_rows(cx);
        let order: Vec<_> = rows
            .iter()
            .filter(|row| self.session_row_in_sidebar(row))
            .map(|row| row.id.clone())
            .collect();
        let selected = self.chat_tabs.get(self.chat_tab).map(|tab| tab.id.clone());
        if let Some(target) = cycle_target(&order, selected.as_deref(), forward) {
            self.activate_workspace_session(&target, cx);
            window.focus(&self.composer.focus_handle(cx), cx);
        }
    }

    /// Boot landing: the most recently active visible chat once the first
    /// chats frame has synced (manual selection wins; no chats → the
    /// new-session canvas shows).
    pub(super) fn boot_select_chat(&mut self, cx: &mut Context<Self>) {
        // First synced frame: reopen what was open at quit (its chat and
        // split layout), unless a deep link or manual pick already landed.
        if !self.boot_restored
            && self.state.read(cx).chats_synced
            && self.state.read(cx).spaces_synced
        {
            self.boot_restored = true;
            let has_draft = {
                let composer = self.composer.read(cx);
                !composer.input.read(cx).is_empty()
                    || !composer.staged().is_empty()
                    || !composer.staged_appshots().is_empty()
            };
            if has_draft && self.state.read(cx).selected_chat.is_none() {
                // Content entered before sync is new-session intent too.
                self.state.update(cx, |state, _| state.auto_selected = true);
            }
            if self.state.read(cx).selected_chat.is_none() && !self.state.read(cx).auto_selected && self.restore_project_tabs(cx) {
                return;
            }
            let restore = {
                let state = self.state.read(cx);
                // Missing metadata may belong to an offline device. Preserve
                // saved identities; confirmed deletion removes them explicitly.
                let live = |_id: &str| true;
                (state.selected_chat.is_none() && !state.auto_selected).then(|| {
                    (
                        self.settings.last_chat_id.clone().filter(|id| live(id)),
                        self.settings
                            .chat_layout
                            .as_ref()
                            .and_then(|saved| chat_split::ChatSplit::from_saved(saved, live)),
                    )
                })
            };
            if let Some((last, layout)) = restore {
                let restored_layout = layout.is_some();
                let restored_panels = layout.as_ref().map(|split| {
                    workspace_session_persistence::legacy_workspace_panels(split, last.as_deref())
                });
                self.chat_split = layout;
                self.chat_split_selected = last.clone();
                self.sync_chat_panes(cx);
                if last.is_some() || restored_layout {
                    self.focus_composer(cx);
                    self.state.update(cx, |s, cx| {
                        // A restored blank canvas is a choice too: keep the
                        // most-recent fallback below from overriding it.
                        s.auto_selected = true;
                        s.select_chat(last, cx)
                    });
                    if let Some(panels) = restored_panels {
                        self.ensure_workspace_sessions(cx);
                        let session = self.chat_tabs[self.chat_tab].id.clone();
                        self.restore_workspace_panels(&session, &panels, cx);
                        self.persist_chat_tabs(cx);
                    }
                    return;
                }
            } else {
                // Persist the manual selection/draft's actual layout, not
                // the rejected saved layout that could return next launch.
                self.sync_chat_panes(cx);
            }
        }
        let first = {
            let state = self.state.read(cx);
            if !self.boot_restored
                || !state.chats_synced
                || state.selected_chat.is_some()
                || state.auto_selected
            {
                return;
            }
            state
                .overview_chats(Utc::now())
                .first()
                .map(|(_, c)| c.id.clone())
        };
        if let Some(first) = first {
            self.focus_composer(cx);
            self.state
                .update(cx, |s, cx| s.select_chat(Some(first), cx));
        }
    }

    /// Replace the current tab/pane's session, as `/resume` requests.
    pub(crate) fn open_chat(&mut self, chat_id: String, cx: &mut Context<Self>) {
        self.open_chat_preserving_tabs(chat_id, cx);
    }

    /// ⌘W's last rung: with nothing else to close, leave the open chat for a
    /// new session. False on the new-session canvas (nothing to close) or off
    /// the chat route.
    pub(crate) fn close_chat_to_new_session(&mut self, cx: &mut Context<Self>) -> bool {
        if !matches!(self.route, Route::Chat) || self.state.read(cx).selected_chat.is_none() {
            return false;
        }
        let tab = self.park_chat_tab(cx);
        self.remember_closed_chat_tab(tab, self.chat_tab, cx);
        self.chat_tab_id = uuid::Uuid::new_v4();
        self.open_new_session(cx);
        self.remember_last_tab_canvas(cx);
        true
    }

    /// The new-session action: open the canvas in place. A set sidebar filter
    /// re-homes the canvas onto that project; under "All" the current pick
    /// (the last selected project, restored from composer defaults) stands.
    ///
    /// A new chat always starts with the terminal hidden: when the drawer is
    /// open it just hides (detach, not close — the source chat's tabs and
    /// PTYs survive for the return trip).
    pub(super) fn open_new_session(&mut self, cx: &mut Context<Self>) {
        self.create_workspace_session(cx);
    }

    /// Project context and pane actions below the shared sidebar/tab header.
    pub(super) fn render_session_title_bar(
        &mut self,
        viewport_height: Pixels,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme = Theme::of(cx).clone();
        let target = {
            let state = self.state.read(cx);
            state.selected_chat_row().map(|chat| {
                SharedString::from(transcript::single_line(&crate::state::chat_label(
                    chat,
                    &state.provisional_title(),
                    "New conversation",
                )))
            })
        };
        let on_canvas = target.is_none();
        let sidebar_now = self.sidebar_now();
        let content_left = (sidebar_now + Theme::SPACE_LG).max(self.title_bar_content_start(cx));

        // Each pane keeps its own controls aligned with its content below.
        let right_pane_open = !on_canvas && self.right_pane_open(cx);
        let takeover = right_pane_open && self.right_pane_expanded;
        let row_left = if takeover {
            (sidebar_now - 8.0).max(self.title_bar_content_start(cx))
        } else {
            content_left
        };
        let row_gap = 8.0;
        let files_width = self.files_visible_width(cx);
        let right_pad = self.titlebar_right_pad(if theme.is_harp() {
            TITLEBAR_CLUSTER_PAD
        } else {
            TITLEBAR_ACTION_EDGE_INSET
        });
        // The title row's gaps are outside the fixed-width panel controls.
        let gap_budget = if takeover { row_gap } else { row_gap * 3.0 };
        let right_visible = self.right_visible_width(cx);
        let widths = panel_titlebar_widths(
            right_visible,
            files_width,
            self.viewport_width - row_left - right_pad - gap_budget,
            right_pad,
        );
        // The trailing strip always carries the explorer slot with its two
        // toggles; the surface tabs reveal to their left only while the surface
        // host is open.
        let trailing_width = if on_canvas {
            0.0
        } else {
            let surface = if right_pane_open {
                widths.surface_reveal
            } else {
                0.0
            };
            surface + widths.files_controls
        };
        let available_titlebar_width =
            (self.viewport_width - row_left - right_pad - trailing_width - row_gap * 3.0).max(0.0);

        let trailing: Option<gpui::AnyElement> = if on_canvas {
            None
        } else {
            let mut controls = div()
                .id("right-titlebar-controls")
                .flex_none()
                .h_full()
                .flex()
                .flex_row()
                .items_center();
            if right_pane_open {
                // The right pane's SURFACE TABS (t3 RightPanelTabs) — the diff
                // options that used to live here moved into the pane's own
                // second row; expand stays in this band (user request).
                let tabs = self.render_right_tab_strip(cx);
                // The toggle is the fixed right-edge anchor, like the left
                // sidebar control. Only the tabs + expand section reveals to
                // its left; including the toggle in this animated width
                // compressed both icons into the same clipped box at open.
                controls = controls.child(
                    div()
                        .w(px(widths.surface_reveal))
                        .h_full()
                        .flex_none()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(px(4.0))
                        .overflow_hidden()
                        // 8 + the trigger's own 8px pad = the pane's 16px
                        // text gutter. The 4px right padding is the stable
                        // gap before the fixed toggle.
                        .pl(px(8.0))
                        .pr(px(4.0))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .h_full()
                                .overflow_hidden()
                                .child(tabs),
                        )
                        .child(header_icon_button(
                            "expand-changes",
                            right_pane_expand_icon(self.right_pane_expanded),
                            &theme,
                            cx.listener(|this, _, _, cx| this.toggle_right_pane_expand(cx)),
                        )),
                );
            }
            // The explorer slot sits over the explorer column and carries the
            // two fixed right-edge anchors — the explorer toggle and,
            // outermost, the pane toggle — which stay mounted at one position
            // while the surface tabs reveal to their left. The explorer's own
            // search and visibility controls live in its secondary header.
            Some(
                controls
                    .child(
                        div()
                            .w(px(widths.files_controls))
                            .h_full()
                            .flex_none()
                            .flex()
                            .items_center()
                            .justify_end()
                            .gap(px(PANEL_TOGGLE_GAP))
                            // No hairline here: the explorer column below is
                            // padded down by the titlebar height and its left
                            // border already runs through this band, so a
                            // second one on the slot stacked on the same
                            // pixels and read lighter than the seam beneath
                            // it (user report).
                            .child(
                                header_icon_button(
                                    "toggle-files-panel",
                                    icons::FILE_TREE,
                                    &theme,
                                    cx.listener(|this, _, window, cx| {
                                        this.toggle_files_panel(window, cx)
                                    }),
                                )
                                .role(gpui::Role::Button)
                                .aria_label(if self.files_panel_open(cx) {
                                    "Hide files panel"
                                } else {
                                    "Show files panel"
                                })
                                .when(self.files_panel_open(cx), |button| {
                                    button.bg(crate::theme::wash(0.09))
                                }),
                            )
                            .child(header_icon_button(
                                "toggle-changes",
                                icons::SIDEBAR_MINIMALISTIC,
                                &theme,
                                cx.listener(|this, _, window, cx| {
                                    this.toggle_workspace_tool(
                                        workspace_panels::WorkspaceTool::Changes,
                                        window,
                                        cx,
                                    );
                                }),
                            )),
                    )
                    .into_any_element(),
            )
        };

        let actions = (!takeover && !on_canvas)
            .then(|| {
                self.render_project_actions_control(available_titlebar_width, viewport_height, cx)
            })
            .flatten();
        let inner = div()
            .size_full()
            .flex()
            .items_center()
            .pt(px(Theme::TITLEBAR_TOP_PAD))
            .gap(px(row_gap))
            .pl(px(row_left))
            .pr(px(right_pad))
            .when(!takeover, |el| {
                el.children(target.map(|target| {
                    div()
                        .min_w_0()
                        .truncate()
                        .text_size(crate::typography::ui_rems(12.0))
                        .text_color(theme.text_muted)
                        .child(target)
                }))
            })
            .child(div().flex_1())
            .children(actions)
            .children(trailing);

        // The unified window titlebar: full-width on the glass shell, ABOVE
        // the inset card. No bottom border — the card's own hairline is the
        // separation; the glass gutter shows between.
        let bar = div().h(px(Theme::TITLEBAR_HEIGHT)).flex_none().child(inner);
        self.titlebar_drag_region("chat-titlebar", bar, cx)
            .into_any_element()
    }
}

#[cfg(test)]
mod panel_titlebar_tests {
    use super::*;

    #[test]
    fn tabs_align_with_the_panel_for_each_caption_layout_and_files_width() {
        let viewport = 1400.0;
        for right_pad in [6.0, 40.0, 92.0, 114.0] {
            for files in [0.0, 10.0, 28.0, 100.0, 220.0, 286.0, 440.0] {
                let widths = panel_titlebar_widths(520.0, files, 1100.0, right_pad);
                let controls_left =
                    viewport - right_pad - widths.files_controls - widths.surface_reveal;
                assert_eq!(
                    controls_left,
                    viewport - files - 520.0,
                    "caption clearance {right_pad}, Files width {files}"
                );
                assert!(widths.files_controls >= PANEL_TOGGLE_SLOTS);
                if files >= right_pad + PANEL_TOGGLE_SLOTS {
                    assert_eq!(
                        viewport - right_pad - widths.files_controls,
                        viewport - files
                    );
                }
            }
        }
    }

    #[test]
    fn expanded_tabs_clear_the_left_controls_without_reserving_captions_twice() {
        for right_pad in [6.0, 92.0, 114.0] {
            let viewport = 1400.0;
            let files = 286.0;
            // With the sidebar open, the header starts exactly at its seam.
            // With it collapsed, leave room for the window/nav controls.
            for (sidebar, row_left) in [(256.0, 248.0), (0.0, 180.0)] {
                let widths = panel_titlebar_widths(
                    viewport - sidebar - files,
                    files,
                    viewport - row_left - right_pad - 8.0,
                    right_pad,
                );
                let controls_left =
                    viewport - right_pad - widths.files_controls - widths.surface_reveal;
                assert_eq!(controls_left, sidebar.max(row_left + 8.0));
            }
        }
    }

    #[test]
    fn narrow_panels_and_tight_headers_keep_nonnegative_reveal_widths() {
        // A narrow surface and Files share a 520px header.
        let widths = panel_titlebar_widths(234.0, 286.0, 600.0, 92.0);
        assert_eq!(
            1000.0 - 92.0 - widths.files_controls - widths.surface_reveal,
            480.0
        );
        for available in [-20.0, 0.0, 28.0, 56.0, 100.0] {
            let widths = panel_titlebar_widths(0.0, 0.0, available, 114.0);
            assert_eq!(widths.surface_reveal, 0.0);
            assert_eq!(widths.files_controls, PANEL_TOGGLE_SLOTS);
        }
    }
}

#[cfg(test)]
mod cycle_tests {
    use super::*;

    fn order(ids: &[&str]) -> Vec<String> {
        ids.iter().map(|id| id.to_string()).collect()
    }

    #[test]
    fn steps_forward_and_back_through_the_list() {
        let list = order(&["a", "b", "c"]);
        assert_eq!(cycle_target(&list, Some("a"), true).as_deref(), Some("b"));
        assert_eq!(cycle_target(&list, Some("b"), true).as_deref(), Some("c"));
        assert_eq!(cycle_target(&list, Some("c"), false).as_deref(), Some("b"));
        assert_eq!(cycle_target(&list, Some("b"), false).as_deref(), Some("a"));
    }

    #[test]
    fn wraps_at_both_ends() {
        let list = order(&["a", "b", "c"]);
        assert_eq!(cycle_target(&list, Some("c"), true).as_deref(), Some("a"));
        assert_eq!(cycle_target(&list, Some("a"), false).as_deref(), Some("c"));
    }

    #[test]
    fn a_single_session_cycles_to_itself() {
        // Not a no-op by accident: with one row both directions must resolve,
        // so the shortcut never looks broken by dead-ending on `None`.
        let list = order(&["only"]);
        assert_eq!(
            cycle_target(&list, Some("only"), true).as_deref(),
            Some("only")
        );
        assert_eq!(
            cycle_target(&list, Some("only"), false).as_deref(),
            Some("only")
        );
    }

    #[test]
    fn no_selection_enters_the_list_from_the_matching_end() {
        let list = order(&["a", "b", "c"]);
        assert_eq!(cycle_target(&list, None, true).as_deref(), Some("a"));
        assert_eq!(cycle_target(&list, None, false).as_deref(), Some("c"));
        assert_eq!(
            cycle_target(&list, Some("gone"), true).as_deref(),
            Some("a")
        );
        assert_eq!(
            cycle_target(&list, Some("gone"), false).as_deref(),
            Some("c")
        );
    }

    #[test]
    fn an_empty_list_has_nothing_to_select() {
        assert_eq!(cycle_target(&[], None, true), None);
        assert_eq!(cycle_target(&[], Some("a"), true), None);
    }

    // Cycling walks the rows the sidebar is drawing, not every chat: that
    // guarantee is structural now — `cycle_session` reads the same
    // `AppState::sidebar_chats` the sidebar and the jump shortcuts read, and
    // `jump_slots_count_the_rows_the_sidebar_draws` (state.rs) covers the
    // space-filter behaviour for all of them.
}
