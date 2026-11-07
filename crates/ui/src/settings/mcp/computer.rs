//! Settings → MCP servers → Computer use: nanocua on the project's device, the
//! app graff's agents use to see and use this computer. It has a Stop button
//! that doesn't depend on finding nanocua's window. Buttons ending in an ellipsis
//! only ask: the answer is a click in nanocua's own window.

use gpui::{AnyElement, Context, SharedString, Task, div, prelude::*, px};

use harness_proto::{ComputerUseAction, ComputerUseStatus};
use harness_rpc::methods;

use crate::popover::Loadable;
use crate::settings::widgets;
use crate::theme::Theme;

use super::McpPage;

#[derive(Default)]
pub(super) struct ComputerSection {
    status: Loadable<ComputerUseStatus>,
    /// The action in flight. Stop is never held back by it.
    busy: Option<ComputerUseAction>,
    message: Option<SharedString>,
    load_task: Option<Task<()>>,
    action_tasks: Vec<Task<()>>,
}

/// Whether a press goes through while `busy` runs. A question can wait a minute,
/// and stopping must not wait with it.
fn may_run(busy: Option<ComputerUseAction>, action: ComputerUseAction) -> bool {
    busy.is_none() || action == ComputerUseAction::Stop
}

/// What the page says beside the buttons, in a line.
fn detail(status: &ComputerUseStatus) -> String {
    if !status.installed {
        return "nanocua isn't installed. It ships with graff's signed macOS releases.".into();
    }
    if !status.running {
        return "It starts when an agent first uses it.".into();
    }
    let grant = |on| if on { "allowed" } else { "not allowed" };
    format!(
        "{} agent{} connected · whole screen {} · Accessibility {} · Screen Recording {}",
        status.agents,
        if status.agents == 1 { "" } else { "s" },
        if status.whole_screen { "on" } else { "off" },
        grant(status.accessibility),
        grant(status.screen_recording),
    )
}

impl McpPage {
    pub(super) fn load_computer(&mut self, cx: &mut Context<Self>) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        let params = self.request(cx, serde_json::json!({}));
        self.computer.load_task = Some(cx.spawn(async move |this, cx| {
            let result = engine
                .client()
                .call(methods::GET_COMPUTER_USE, params)
                .await;
            this.update(cx, |page, cx| {
                page.computer.status = match result.map(serde_json::from_value) {
                    Ok(Ok(status)) => Loadable::Ready(status),
                    Ok(Err(err)) => Loadable::Error(format!("Unexpected reply: {err}")),
                    Err(err) => Loadable::Error(err.to_string()),
                };
                cx.notify();
            })
            .ok();
        }));
    }

    fn act_computer(&mut self, action: ComputerUseAction, cx: &mut Context<Self>) {
        if !may_run(self.computer.busy, action) {
            return;
        }
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        // Stop goes through beside a waiting question, and leaves it waiting.
        if action != ComputerUseAction::Stop {
            self.computer.busy = Some(action);
            self.computer.message = action.asks().then(|| {
                SharedString::from("Answer in nanocua's window. The question lasts a minute.")
            });
        }
        let params = self.request(cx, serde_json::json!({ "action": action }));
        let task = cx.spawn(async move |this, cx| {
            let result = engine
                .client()
                .call(methods::COMPUTER_USE_ACTION, params)
                .await;
            this.update(cx, |page, cx| {
                if page.computer.busy == Some(action) {
                    page.computer.busy = None;
                }
                match result.map(serde_json::from_value::<ComputerUseStatus>) {
                    Ok(Ok(status)) => {
                        match status.outcome_text() {
                            Some(text) => page.computer.message = Some(text.into()),
                            None if page.computer.busy.is_none() => page.computer.message = None,
                            None => {}
                        }
                        page.computer.status = Loadable::Ready(status);
                    }
                    Ok(Err(err)) => {
                        page.computer.message = Some(format!("Unexpected reply: {err}").into());
                    }
                    Err(err) => page.computer.message = Some(err.to_string().into()),
                }
                cx.notify();
            })
            .ok();
        });
        if self.computer.action_tasks.len() > 32 && self.computer.busy.is_none() {
            self.computer.action_tasks.clear();
        }
        self.computer.action_tasks.push(task);
        cx.notify();
    }

    /// Nothing on a device without computer use, or before the first answer.
    pub(super) fn render_computer(
        &self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let status = match &self.computer.status {
            Loadable::Ready(status) if status.supported => status,
            _ => return None,
        };
        let dot = if !status.running {
            theme.text_muted.opacity(0.4)
        } else if status.stopped {
            theme.danger
        } else if status.input {
            theme.warning
        } else {
            theme.success
        };
        let buttons: Vec<AnyElement> = status
            .controls()
            .into_iter()
            .enumerate()
            .map(|(ix, (label, action))| {
                let hover_theme = theme.clone();
                let stop = action == ComputerUseAction::Stop;
                widgets::ghost_action(theme)
                    .id(("computer-action", ix))
                    .debug_selector(move || format!("computer-{}", action.ctl_args().join("-")))
                    .flex_none()
                    .border_1()
                    .border_color(if stop { theme.danger } else { theme.border })
                    .when(stop, |el| el.text_color(theme.danger))
                    .when(!may_run(self.computer.busy, action), |el| el.opacity(0.5))
                    .hover(move |s| widgets::ghost_hover(&hover_theme, s))
                    .on_click(cx.listener(move |this, _, _, cx| this.act_computer(action, cx)))
                    .child(SharedString::from(label))
                    .into_any_element()
            })
            .collect();
        let refresh_theme = theme.clone();
        Some(
            widgets::section_card(theme)
                .debug_selector(|| "computer-section".into())
                .mt(px(16.0))
                .child(
                    widgets::card_row(theme, true)
                        .child(widgets::row_tile(theme, crate::icons::REMOTE_SERVER))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .flex()
                                .flex_col()
                                .gap(px(4.0))
                                .child(widgets::row_title(theme, "Computer use"))
                                .child(
                                    div()
                                        .text_size(crate::typography::ui_rems(12.0))
                                        .text_color(theme.text_muted)
                                        .child(SharedString::from(detail(status))),
                                ),
                        )
                        .child(
                            div()
                                .flex_none()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap(px(6.0))
                                .text_size(crate::typography::ui_rems(12.0))
                                .text_color(theme.text_muted)
                                .child(div().size(px(7.0)).rounded_full().bg(dot))
                                .child(SharedString::from(status.summary())),
                        )
                        .child(
                            widgets::ghost_action(theme)
                                .id("computer-refresh")
                                .flex_none()
                                .hover(move |s| widgets::ghost_hover(&refresh_theme, s))
                                .on_click(cx.listener(|this, _, _, cx| this.load_computer(cx)))
                                .child(SharedString::from("Refresh")),
                        ),
                )
                .when(!buttons.is_empty(), |el| {
                    el.child(
                        div()
                            .px(px(20.0))
                            .pb(px(14.0))
                            .flex()
                            .flex_row()
                            .flex_wrap()
                            .gap(px(8.0))
                            .children(buttons),
                    )
                })
                .when_some(self.computer.message.clone(), |el, message| {
                    el.child(
                        div()
                            .debug_selector(|| "computer-message".into())
                            .px(px(20.0))
                            .pb(px(14.0))
                            .text_size(crate::typography::ui_rems(12.0))
                            .text_color(theme.text_muted)
                            .child(message),
                    )
                })
                .into_any_element(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn redraw(cx: &mut gpui::VisualTestContext) {
        cx.update(|window, cx| {
            window.refresh();
            window.draw(cx).clear();
        });
    }

    fn show(
        page: &gpui::Entity<McpPage>,
        cx: &mut gpui::VisualTestContext,
        status: ComputerUseStatus,
    ) {
        page.update(cx, |page, cx| {
            page.computer.status = Loadable::Ready(status);
            cx.notify();
        });
        redraw(cx);
    }

    fn click(cx: &mut gpui::VisualTestContext, selector: &'static str) {
        let bounds = cx.debug_bounds(selector).expect(selector);
        cx.simulate_click(bounds.center(), gpui::Modifiers::none());
        cx.run_until_parked();
    }

    /// The computer-use requests sent so far, leaving the page's other ones.
    fn sent(requests: &mut tokio::sync::mpsc::Receiver<String>) -> Vec<serde_json::Value> {
        let mut out = Vec::new();
        while let Ok(line) = requests.try_recv() {
            let request: serde_json::Value = serde_json::from_str(&line).unwrap();
            if request["method"] == methods::COMPUTER_USE_ACTION {
                out.push(request);
            }
        }
        out
    }

    #[gpui::test]
    fn the_section_follows_the_status_and_its_buttons_reach_the_engine(
        cx: &mut gpui::TestAppContext,
    ) {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let _guard = runtime.enter();
        let (out, mut requests) = tokio::sync::mpsc::channel::<String>(16);
        let (replies, inbound) = tokio::sync::mpsc::channel::<String>(16);
        let engine =
            crate::state::EngineHandle::from_test_client(harness_rpc::RpcClient::new(out, inbound));
        cx.update(|cx| {
            gpui_base::init(cx);
            cx.set_global(Theme::default());
        });
        let state = cx.new(|_| {
            let mut state = crate::state::AppState::new();
            state.set_test_engine(engine);
            state
        });
        let (page, cx) = cx.add_window_view(|_, cx| McpPage::new(state, cx));
        cx.run_until_parked();
        redraw(cx);
        assert!(
            cx.debug_bounds("computer-section").is_none(),
            "no reply yet"
        );

        show(&page, cx, ComputerUseStatus::default());
        assert!(
            cx.debug_bounds("computer-section").is_none(),
            "no computer use here"
        );

        show(
            &page,
            cx,
            ComputerUseStatus {
                supported: true,
                ..Default::default()
            },
        );
        assert!(
            cx.debug_bounds("computer-section").is_some(),
            "says it's missing"
        );
        assert!(
            cx.debug_bounds("computer-open").is_none(),
            "nothing to press"
        );

        show(
            &page,
            cx,
            ComputerUseStatus {
                supported: true,
                installed: true,
                running: true,
                ..Default::default()
            },
        );
        assert!(cx.debug_bounds("computer-stop").is_some());
        assert!(cx.debug_bounds("computer-allow-resume").is_none());
        assert!(cx.debug_bounds("computer-grant-screen").is_some());

        // A question: the engine is asked, and the page says where to answer.
        sent(&mut requests);
        click(cx, "computer-allow-input");
        let asked = sent(&mut requests);
        assert_eq!(asked.len(), 1);
        assert_eq!(asked[0]["params"]["action"], "allow_input");
        redraw(cx);
        assert!(cx.debug_bounds("computer-message").is_some());

        // Nothing else starts while it waits, except Stop.
        click(cx, "computer-allow-whole_screen");
        assert!(sent(&mut requests).is_empty());
        click(cx, "computer-stop");
        let stop = sent(&mut requests);
        assert_eq!(stop.len(), 1);
        assert_eq!(stop[0]["params"]["action"], "stop");

        // Stop's answer shows, and the question is still waiting.
        let answer = |id: &serde_json::Value, ok: serde_json::Value| {
            runtime.block_on(async {
                let line = serde_json::json!({"id": id, "ok": ok}).to_string();
                replies.send(line).await.unwrap();
                while replies.capacity() < replies.max_capacity() {
                    tokio::task::yield_now().await;
                }
            });
        };
        answer(
            &stop[0]["id"],
            serde_json::json!({"installed": true, "running": true, "stopped": true,
                "pending": "input", "supported": true}),
        );
        cx.run_until_parked();
        redraw(cx);
        assert!(cx.debug_bounds("computer-allow-resume").is_some());
        assert!(cx.debug_bounds("computer-message").is_some());
        page.update(cx, |page, _| {
            assert_eq!(page.computer.busy, Some(ComputerUseAction::AllowInput));
        });

        // The question's answer ends the wait and says how it went.
        answer(
            &asked[0]["id"],
            serde_json::json!({"installed": true, "running": true, "stopped": true,
                "outcome": "denied", "supported": true}),
        );
        cx.run_until_parked();
        page.update(cx, |page, _| {
            assert_eq!(page.computer.busy, None);
            assert_eq!(
                page.computer
                    .message
                    .as_ref()
                    .map(|m| m.to_string())
                    .as_deref(),
                Some("Denied in nanocua's window.")
            );
        });
    }

    #[test]
    fn a_waiting_question_never_holds_up_stop() {
        use ComputerUseAction as A;
        assert!(may_run(None, A::AllowInput));
        assert!(may_run(Some(A::AllowInput), A::Stop));
        assert!(!may_run(Some(A::AllowInput), A::AllowWholeScreen));
        assert!(!may_run(Some(A::AllowInput), A::TurnOffInput));
    }

    #[test]
    fn the_line_says_what_is_missing() {
        let mut status = ComputerUseStatus::default();
        assert!(detail(&status).contains("isn't installed"));
        status.installed = true;
        assert!(detail(&status).contains("starts when an agent"));
        status.running = true;
        status.agents = 1;
        status.accessibility = true;
        let line = detail(&status);
        assert!(line.starts_with("1 agent connected"));
        assert!(line.contains("Accessibility allowed"));
        assert!(line.contains("Screen Recording not allowed"));
    }
}
