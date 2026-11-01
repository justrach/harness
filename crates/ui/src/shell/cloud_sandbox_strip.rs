//! The "Cloud sandbox running" strip above the account menu.
//!
//! A Codegraff cloud sandbox started from Harness keeps running, billed per second, until it
//! is turned off. While one runs this strip stays in the sidebar footer with a live dot, what
//! it costs or why it will pause, and a one-click Turn off (a pause: memory and files are
//! kept). Clicking the label opens Settings → Accounts, where the sandboxes card lives. It
//! reads the list [`AppState`] keeps fresh, so it is hidden when signed out, when the feature
//! is off, and when nothing is running.
//!
//! With the sidebar collapsed the strip is out of sight, so a cloud button with a live dot
//! joins the titlebar's left cluster, the same size as its other buttons so it never covers
//! anything. Hover says what it costs; a click opens a small card with the details, Settings
//! and Turn off.

use super::*;
use crate::codegraff_sandboxes::{
    RunningSummary, TURN_OFF, TURN_OFF_HINT, compact_tooltip, running_summary,
};

impl Shell {
    pub(super) fn render_cloud_sandbox_strip(
        &mut self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let summary = running_summary(self.state.read(cx).cloud_sandboxes()?, chrono::Utc::now())?;
        let tone = if summary.warning {
            theme.warning
        } else {
            theme.accent
        };
        let label = div()
            .id("cloud-sandbox-strip-open")
            .debug_selector(|| "cloud-sandbox-strip-open".into())
            .flex_1()
            .min_w_0()
            .flex()
            .flex_col()
            .gap(px(1.0))
            .cursor_pointer()
            .tooltip(crate::settings::widgets::text_tooltip(compact_tooltip(
                &summary,
            )))
            .tooltip_show_delay(std::time::Duration::from_millis(350))
            .on_click(cx.listener(|this, _, _, cx| {
                this.open_settings(SettingsSection::Agents, cx);
            }))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(6.0))
                    .child(div().size(px(6.0)).flex_none().rounded_full().bg(tone))
                    .child(
                        div()
                            .min_w_0()
                            .truncate()
                            .font_weight(gpui::FontWeight::MEDIUM)
                            .text_color(theme.text)
                            .child(SharedString::from(summary.label.clone())),
                    ),
            )
            // One line at rest (the detail is in the tooltip); a problem gets its own line.
            .when(summary.warning, |el| {
                el.child(
                    div()
                        .pl(px(12.0))
                        .min_w_0()
                        .truncate()
                        .text_size(crate::typography::ui_rems(10.5))
                        .text_color(theme.warning)
                        .child(SharedString::from(summary.detail.clone())),
                )
            });
        let turn_off = (!summary.running_ids.is_empty()).then(|| {
            self.cloud_turn_off_button(
                "cloud-sandbox-turn-off",
                summary.running_ids.clone(),
                theme,
                cx,
            )
        });
        Some(
            div()
                .id("cloud-sandbox-strip")
                .debug_selector(|| "cloud-sandbox-strip".into())
                .mx(px(Theme::SPACE_SM))
                .mt(px(4.0))
                .px(px(Theme::SPACE_SM))
                .py(px(4.0))
                .rounded(px(Theme::CONTROL_RADIUS))
                .bg(if summary.warning {
                    theme.warning.opacity(0.12)
                } else {
                    theme.accent_wash
                })
                .border_1()
                .border_color(tone.opacity(0.3))
                .flex()
                .flex_row()
                .items_center()
                .gap(px(8.0))
                .text_size(crate::typography::ui_rems(11.0))
                .child(label)
                .children(turn_off)
                .into_any_element(),
        )
    }

    /// What the titlebar cloud button reports: a running sandbox while the sidebar (and so the
    /// strip) is collapsed out of sight.
    fn cloud_sandbox_button_summary(&self, cx: &App) -> Option<RunningSummary> {
        if !self.settings.sidebar_collapsed {
            return None;
        }
        running_summary(self.state.read(cx).cloud_sandboxes()?, chrono::Utc::now())
    }

    /// Width the titlebar's left cluster gains while the cloud button shows.
    pub(super) fn titlebar_cloud_slot(&self, cx: &App) -> f32 {
        if self.cloud_sandbox_button_summary(cx).is_some() {
            TITLEBAR_ACTION_SLOT_WIDTH
        } else {
            0.0
        }
    }

    /// The collapsed-sidebar stand-in for the strip: a cloud button in the titlebar's left
    /// cluster with a live dot. Hover says what it costs; a click opens a small card with the
    /// details, Settings and Turn off. `None` while the sidebar is open (the strip shows) or
    /// nothing runs.
    pub(super) fn render_cloud_sandbox_button(
        &mut self,
        theme: &Theme,
        control_gap: f32,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let Some(summary) = self.cloud_sandbox_button_summary(cx) else {
            // Gone (turned off, or the sidebar opened): don't reopen the card next time.
            self.cloud_sandbox_menu = popover::Popup::default();
            return None;
        };
        let tone = if summary.warning {
            theme.warning
        } else {
            theme.accent
        };
        let fade_key = "window-control-titlebar-cloud";
        let mut button = div()
            .id("cloud-sandbox-button")
            .debug_selector(|| "cloud-sandbox-button".into())
            .role(gpui::Role::Button)
            .aria_label(SharedString::from(compact_tooltip(&summary)))
            .relative()
            .size(px(24.0))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(6.0))
            .cursor_pointer()
            .bg(motion::hover_blend(
                fade_key,
                theme.glass_hover().opacity(0.0),
                theme.glass_hover(),
            ))
            .on_hover(motion::hover_listener(fade_key))
            // Over the titlebar drag strip: carve the button out of it (see
            // `window_control_button`).
            .occlude()
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, _, window, _| {
                    window.prevent_default();
                    this.cloud_sandbox_menu.note_trigger_press();
                }),
            )
            .on_click(cx.listener(|this, _, _, cx| {
                cx.stop_propagation();
                if this.cloud_sandbox_menu.take_press_was_open() {
                    this.close_cloud_sandbox_menu(cx);
                } else {
                    this.cloud_sandbox_menu.open(());
                    cx.notify();
                }
            }))
            .child(
                icon(icons::CLOUD)
                    .size(px(16.0))
                    .text_color(theme.text_muted),
            )
            .child(
                div()
                    .absolute()
                    .top(px(3.0))
                    .right(px(3.0))
                    .size(px(6.0))
                    .rounded_full()
                    .bg(tone),
            );
        if self.cloud_sandbox_menu.get().is_some() {
            let closing = self.cloud_sandbox_menu.closing_since();
            let card = self.cloud_sandbox_card(&summary, theme, cx);
            button = button.child(popover::anchored_menu_below_gap(
                "cloud-sandbox-menu",
                card,
                closing,
                8.0,
            ));
        } else {
            button = button
                .tooltip(crate::settings::widgets::text_tooltip(compact_tooltip(
                    &summary,
                )))
                .tooltip_show_delay(std::time::Duration::from_millis(350));
        }
        Some(
            div()
                .flex_none()
                .ml(px(control_gap))
                .child(button)
                .into_any_element(),
        )
    }

    /// The cloud button's card: what runs and what it costs, then Settings and Turn off.
    fn cloud_sandbox_card(
        &mut self,
        summary: &RunningSummary,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let ui = crate::typography::ui_rems;
        let tone = if summary.warning {
            theme.warning
        } else {
            theme.accent
        };
        let turn_off = (!summary.running_ids.is_empty()).then(|| {
            self.cloud_turn_off_button(
                "cloud-sandbox-menu-turn-off",
                summary.running_ids.clone(),
                theme,
                cx,
            )
        });
        popover::popover_card(theme)
            .id("cloud-sandbox-card")
            .debug_selector(|| "cloud-sandbox-card".into())
            .w(px(260.0))
            .flex()
            .flex_col()
            .gap(px(8.0))
            .on_mouse_down_out(cx.listener(|this, _, _, cx| this.close_cloud_sandbox_menu(cx)))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(6.0))
                    .child(div().size(px(6.0)).flex_none().rounded_full().bg(tone))
                    .child(
                        div()
                            .min_w_0()
                            .text_size(ui(12.5))
                            .font_weight(gpui::FontWeight::MEDIUM)
                            .child(SharedString::from(summary.label.clone())),
                    ),
            )
            .child(
                div()
                    .pl(px(12.0))
                    .text_size(ui(11.5))
                    .text_color(if summary.warning {
                        theme.warning
                    } else {
                        theme.text_muted
                    })
                    .child(SharedString::from(summary.detail.clone())),
            )
            .child(
                div()
                    .flex()
                    .flex_row()
                    .justify_end()
                    .items_center()
                    .gap(px(6.0))
                    .text_size(ui(11.0))
                    .child(
                        popover::btn_ghost(theme, "Settings", "cloud-sandbox-menu-settings-fade")
                            .id("cloud-sandbox-menu-settings")
                            .debug_selector(|| "cloud-sandbox-menu-settings".into())
                            .cursor_pointer()
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.close_cloud_sandbox_menu(cx);
                                this.open_settings(SettingsSection::Agents, cx);
                            })),
                    )
                    .children(turn_off),
            )
            .into_any_element()
    }

    fn close_cloud_sandbox_menu(&mut self, cx: &mut Context<Self>) {
        if self.cloud_sandbox_menu.begin_close() {
            popover::reap_popup(cx, |shell: &mut Self| &mut shell.cloud_sandbox_menu);
        }
        cx.notify();
    }

    /// "Turn off" (or "Turn off all"), busy while the pause is under way.
    fn cloud_turn_off_button(
        &self,
        id: &'static str,
        ids: Vec<String>,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> gpui::Stateful<gpui::Div> {
        let turning_off = self.cloud_turning_off;
        let text = match (turning_off, ids.len()) {
            (true, _) => TURN_OFF.1,
            (false, 1) => TURN_OFF.0,
            (false, _) => "Turn off all",
        };
        div()
            .id(id)
            .debug_selector(move || id.into())
            .flex_none()
            .px(px(8.0))
            .py(px(3.0))
            .rounded(px(Theme::CONTROL_RADIUS))
            .border_1()
            .border_color(theme.border)
            .bg(theme.surface_raised)
            .font_weight(gpui::FontWeight::MEDIUM)
            .text_color(theme.text)
            .tooltip(crate::settings::widgets::text_tooltip(TURN_OFF_HINT))
            .tooltip_show_delay(std::time::Duration::from_millis(350))
            .when(turning_off, |el| el.opacity(0.6))
            .when(!turning_off, |el| {
                el.cursor_pointer()
                    .hover(|s| s.bg(theme.surface_raised_hover))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        cx.stop_propagation();
                        this.turn_off_cloud_sandboxes(ids.clone(), cx);
                    }))
            })
            .child(SharedString::from(text))
    }

    /// Pause every running sandbox (memory and files are kept; billing stops), then re-read
    /// the list so the strip and the Settings card catch up at once.
    fn turn_off_cloud_sandboxes(&mut self, ids: Vec<String>, cx: &mut Context<Self>) {
        if self.cloud_turning_off {
            return;
        }
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        self.cloud_turning_off = true;
        cx.notify();
        self.cloud_turn_off_task = Some(cx.spawn(async move |this, cx| {
            let mut failure = None;
            for id in ids {
                let result = engine
                    .client()
                    .call(
                        methods::CODEGRAFF_SANDBOX_ACTION,
                        serde_json::json!({ "id": id, "action": "stop" }),
                    )
                    .await;
                if let Err(error) = result {
                    failure.get_or_insert(error.to_string());
                }
            }
            this.update(cx, |shell, cx| {
                shell.cloud_turning_off = false;
                if let Some(error) = failure {
                    shell.sidebar_notice =
                        Some(format!("Couldn't turn off the cloud sandbox: {error}").into());
                }
                shell
                    .state
                    .update(cx, |state, cx| state.refresh_cloud_sandboxes(cx));
                cx.notify();
            })
            .ok();
        }));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::codegraff_sandboxes::{CodegraffSandbox, CodegraffSandboxes};

    fn sandboxes(state: &str) -> Option<CodegraffSandboxes> {
        Some(CodegraffSandboxes {
            enabled: true,
            sandboxes: vec![CodegraffSandbox {
                id: "cnd_1".into(),
                provider: "fleet".into(),
                state: state.into(),
                harness: true,
                keep_running: Some(true),
                ..Default::default()
            }],
            ..Default::default()
        })
    }

    /// The sidebar is a cached view: repaint the whole window, as a real frame would.
    fn redraw(cx: &mut gpui::VisualTestContext) {
        cx.update(|window, cx| {
            window.refresh();
            window.draw(cx).clear();
        });
    }

    /// A Ready shell in a window, its sidebar open or collapsed.
    fn open_shell<'a>(
        cx: &'a mut gpui::TestAppContext,
        dir: &std::path::Path,
        collapsed: bool,
    ) -> (
        Entity<AppState>,
        Entity<Shell>,
        &'a mut gpui::VisualTestContext,
    ) {
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
            settings::init(settings::UiSettings::default(), dir, cx);
        });
        let state = cx.new(|_| AppState::new());
        let shell_state = state.clone();
        let data_dir = dir.to_path_buf();
        let (shell, cx) = cx.add_window_view(|_, cx| {
            let mut shell = Shell::new(
                shell_state,
                EngineBootConfig {
                    data_dir,
                    ipc_port: 0,
                    edge_url: "http://127.0.0.1:1".into(),
                    edge_token: None,
                    org_id: None,
                    codegraff_client_id: None,
                    default_harness: harness_proto::HarnessId::Mock,
                },
                cx,
            );
            shell.debug_gate = Some(GatePhase::Ready);
            shell.settings.sidebar_collapsed = collapsed;
            shell
        });
        (state, shell, cx)
    }

    #[gpui::test]
    fn the_strip_shows_while_a_sandbox_runs_and_opens_its_settings(cx: &mut gpui::TestAppContext) {
        let dir = tempfile::tempdir().unwrap();
        let (state, shell, cx) = open_shell(cx, dir.path(), false);
        redraw(cx);
        assert!(
            cx.debug_bounds("cloud-sandbox-strip").is_none(),
            "nothing known yet (signed out reads the same)"
        );

        state.update(cx, |state, cx| {
            state.apply_cloud_sandboxes(sandboxes("paused"), cx)
        });
        redraw(cx);
        assert!(
            cx.debug_bounds("cloud-sandbox-strip").is_none(),
            "a paused sandbox costs nothing, so no strip"
        );

        state.update(cx, |state, cx| {
            state.apply_cloud_sandboxes(sandboxes("running"), cx)
        });
        redraw(cx);
        assert!(cx.debug_bounds("cloud-sandbox-strip").is_some());
        assert!(cx.debug_bounds("cloud-sandbox-turn-off").is_some());
        assert!(
            cx.debug_bounds("cloud-sandbox-button").is_none(),
            "the open sidebar has the strip; no titlebar button"
        );

        shell.update(cx, |shell, cx| {
            shell.cloud_turning_off = true;
            cx.notify();
        });
        redraw(cx);
        assert!(
            cx.debug_bounds("cloud-sandbox-turn-off").is_some(),
            "the button stays put while it works"
        );
        shell.update(cx, |shell, _| shell.cloud_turning_off = false);

        let open = cx.debug_bounds("cloud-sandbox-strip-open").unwrap();
        cx.simulate_click(open.center(), Default::default());
        cx.run_until_parked();
        shell.read_with(cx, |shell, _| {
            assert_eq!(shell.route, Route::Settings(SettingsSection::Agents));
        });
        redraw(cx);
        assert!(
            cx.debug_bounds("cloud-sandbox-strip").is_some(),
            "the settings sidebar keeps it in view"
        );

        let mut off = sandboxes("running");
        off.as_mut().unwrap().enabled = false;
        state.update(cx, |state, cx| state.apply_cloud_sandboxes(off, cx));
        redraw(cx);
        assert!(
            cx.debug_bounds("cloud-sandbox-strip").is_none(),
            "hidden where the feature is off"
        );
    }

    #[gpui::test]
    fn a_collapsed_sidebar_keeps_a_titlebar_button_with_turn_off_one_click_away(
        cx: &mut gpui::TestAppContext,
    ) {
        let dir = tempfile::tempdir().unwrap();
        let (state, shell, cx) = open_shell(cx, dir.path(), true);
        state.update(cx, |state, cx| {
            state.apply_cloud_sandboxes(sandboxes("paused"), cx)
        });
        redraw(cx);
        assert!(
            cx.debug_bounds("cloud-sandbox-button").is_none(),
            "nothing runs"
        );
        assert_eq!(
            shell.read_with(cx, |shell, cx| shell.titlebar_cloud_slot(cx)),
            0.0
        );

        state.update(cx, |state, cx| {
            state.apply_cloud_sandboxes(sandboxes("running"), cx)
        });
        redraw(cx);
        let button = cx
            .debug_bounds("cloud-sandbox-button")
            .expect("a running sandbox stays in view with the sidebar collapsed");
        let toggle = cx.debug_bounds("toggle-sidebar").unwrap();
        assert_eq!(button.size, toggle.size, "a titlebar button like the rest");
        assert_eq!(
            button.origin.y, toggle.origin.y,
            "in the titlebar row, not under it"
        );
        assert_eq!(
            shell.read_with(cx, |shell, cx| shell.titlebar_cloud_slot(cx)),
            TITLEBAR_ACTION_SLOT_WIDTH,
            "the tab strip makes room for it"
        );
        assert!(
            cx.debug_bounds("cloud-sandbox-card").is_none(),
            "closed at rest"
        );

        cx.simulate_click(button.center(), Default::default());
        cx.run_until_parked();
        redraw(cx);
        let card = cx
            .debug_bounds("cloud-sandbox-card")
            .expect("a click opens the card");
        assert!(card.origin.y >= button.origin.y + button.size.height);
        assert!(cx.debug_bounds("cloud-sandbox-menu-turn-off").is_some());

        let settings = cx.debug_bounds("cloud-sandbox-menu-settings").unwrap();
        cx.simulate_click(settings.center(), Default::default());
        cx.run_until_parked();
        shell.read_with(cx, |shell, _| {
            assert_eq!(shell.route, Route::Settings(SettingsSection::Agents));
            assert!(!shell.cloud_sandbox_menu.is_open());
        });
        redraw(cx);
        assert!(
            cx.debug_bounds("cloud-sandbox-button").is_some(),
            "still there in Settings"
        );

        shell.update(cx, |shell, cx| {
            shell.settings.sidebar_collapsed = false;
            cx.notify();
        });
        redraw(cx);
        assert!(
            cx.debug_bounds("cloud-sandbox-button").is_none(),
            "an open sidebar shows the strip instead"
        );
        assert!(cx.debug_bounds("cloud-sandbox-strip").is_some());
    }
}
