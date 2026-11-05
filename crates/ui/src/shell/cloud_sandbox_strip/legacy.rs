//! The "Cloud sandbox running" strip above the account menu.
//!
//! A Codegraff cloud sandbox started from Harness keeps running, billed per second, until it
//! is turned off. While one runs this strip stays in the sidebar footer with a live dot, what
//! it costs or why it will pause, and a one-click Turn off (a pause: memory and files are
//! kept). Clicking the label opens Settings → Accounts, where the sandboxes card lives. It
//! reads the list [`AppState`] keeps fresh, so it is hidden when signed out, when the feature
//! is off, and when nothing is running.
//!
//! With the sidebar collapsed the strip is out of sight, so a compact chip takes its place
//! under the sidebar toggle: the live dot and a cloud (hover says what it costs, click opens
//! the Settings card) beside the same one-click Turn off.

use super::*;
use crate::codegraff_sandboxes::{TURN_OFF, TURN_OFF_HINT, compact_tooltip, running_summary};

impl Shell {
    pub(in crate::shell) fn render_cloud_sandbox_strip(
        &mut self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let summary = running_summary(self.state.read(cx).cloud_sandboxes()?, chrono::Utc::now())?;
        let turning_off = self.cloud_turning_off;
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
                            .child(SharedString::from(summary.label)),
                    ),
            )
            .child(
                div()
                    .pl(px(12.0))
                    .min_w_0()
                    .truncate()
                    .text_size(crate::typography::ui_rems(10.5))
                    .text_color(if summary.warning {
                        theme.warning
                    } else {
                        theme.text_muted
                    })
                    .child(SharedString::from(summary.detail)),
            );
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
                .py(px(6.0))
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

    /// The collapsed-sidebar stand-in for the strip: a small floating chip under the sidebar
    /// toggle. `None` while the sidebar is open (the strip shows) or nothing runs.
    pub(in crate::shell) fn render_cloud_sandbox_chip(
        &mut self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if !self.settings.sidebar_collapsed {
            return None;
        }
        let summary = running_summary(self.state.read(cx).cloud_sandboxes()?, chrono::Utc::now())?;
        let tone = if summary.warning {
            theme.warning
        } else {
            theme.accent
        };
        let tooltip = compact_tooltip(&summary);
        let open = div()
            .id("cloud-sandbox-chip-open")
            .debug_selector(|| "cloud-sandbox-chip-open".into())
            .flex()
            .flex_row()
            .items_center()
            .gap(px(5.0))
            .px(px(7.0))
            .py(px(4.0))
            .rounded(px(Theme::CONTROL_RADIUS))
            .cursor_pointer()
            .hover(|s| s.bg(theme.ink(0.06)))
            .tooltip(crate::settings::widgets::text_tooltip(tooltip))
            .tooltip_show_delay(std::time::Duration::from_millis(350))
            .on_click(cx.listener(|this, _, _, cx| {
                this.open_settings(SettingsSection::Agents, cx);
            }))
            .child(div().size(px(6.0)).flex_none().rounded_full().bg(tone))
            .child(
                icon(icons::CLOUD)
                    .size(px(13.0))
                    .flex_none()
                    .text_color(theme.text_muted),
            );
        let turn_off = (!summary.running_ids.is_empty()).then(|| {
            self.cloud_turn_off_button(
                "cloud-sandbox-chip-turn-off",
                summary.running_ids.clone(),
                theme,
                cx,
            )
        });
        Some(
            div()
                .id("cloud-sandbox-chip")
                .debug_selector(|| "cloud-sandbox-chip".into())
                .occlude()
                .absolute()
                .left(px(Theme::SPACE_MD))
                .top(px(Theme::TITLEBAR_HEIGHT + 4.0))
                .p(px(3.0))
                .flex()
                .flex_row()
                .items_center()
                .gap(px(4.0))
                .rounded(px(Theme::CONTROL_RADIUS + 3.0))
                .border_1()
                .border_color(tone.opacity(0.35))
                .bg(crate::popover::surface_bg(theme))
                .when(!theme.is_frost(), |el| el.shadow_md())
                .text_size(crate::typography::ui_rems(11.0))
                .child(open)
                .children(turn_off)
                .into_any_element(),
        )
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
            cx.debug_bounds("cloud-sandbox-chip").is_none(),
            "the open sidebar has the strip; no chip"
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
    fn a_collapsed_sidebar_keeps_a_chip_with_turn_off_in_view(cx: &mut gpui::TestAppContext) {
        let dir = tempfile::tempdir().unwrap();
        let (state, shell, cx) = open_shell(cx, dir.path(), true);
        state.update(cx, |state, cx| {
            state.apply_cloud_sandboxes(sandboxes("paused"), cx)
        });
        redraw(cx);
        assert!(
            cx.debug_bounds("cloud-sandbox-chip").is_none(),
            "nothing runs"
        );

        state.update(cx, |state, cx| {
            state.apply_cloud_sandboxes(sandboxes("running"), cx)
        });
        redraw(cx);
        let chip = cx
            .debug_bounds("cloud-sandbox-chip")
            .expect("a running sandbox stays in view with the sidebar collapsed");
        assert!(f32::from(chip.size.width) > 0.0 && f32::from(chip.size.height) > 0.0);
        assert!(
            cx.debug_bounds("cloud-sandbox-chip-turn-off").is_some(),
            "Turn off is one click away"
        );

        let open = cx.debug_bounds("cloud-sandbox-chip-open").unwrap();
        cx.simulate_click(open.center(), Default::default());
        cx.run_until_parked();
        shell.read_with(cx, |shell, _| {
            assert_eq!(shell.route, Route::Settings(SettingsSection::Agents));
        });
        redraw(cx);
        assert!(
            cx.debug_bounds("cloud-sandbox-chip").is_some(),
            "still there in Settings"
        );

        shell.update(cx, |shell, cx| {
            shell.settings.sidebar_collapsed = false;
            cx.notify();
        });
        redraw(cx);
        assert!(
            cx.debug_bounds("cloud-sandbox-chip").is_none(),
            "an open sidebar shows the strip instead"
        );
    }
}
