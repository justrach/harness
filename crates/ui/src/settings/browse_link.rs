//! Settings › Accounts › browse: connect Harness to the user's browse so
//! agents browse with their sign-ins (engine `browse_link`, browse's
//! Connected apps). Pairing shows six digits that browse also shows; the user
//! confirms there and picks what Harness may do.

use std::time::Duration;

use gpui::{
    AnyElement, App, Context, Entity, FontWeight, IntoElement, ParentElement, Render, SharedString,
    Styled, Task, Window, div, prelude::*, px,
};
use harness_rpc::methods;

use crate::settings::widgets;
use crate::state::AppState;
use crate::theme::Theme;

const POLL_EVERY: Duration = Duration::from_millis(1000);

#[derive(Debug, Clone, Default, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct BrowseLinkStatus {
    pub browse_running: bool,
    pub paired: bool,
    pub scopes: Vec<String>,
    pub pairing_code: Option<String>,
    pub key_mismatch: bool,
    pub error: Option<String>,
}

/// What each browse scope lets agents do, in the words the card uses.
pub fn scope_label(scope: &str) -> &str {
    match scope {
        "read" => "Search and read",
        "act-own-pages" => "Act in its own pages",
        "act-user-tabs" => "Use your tabs",
        "run-js" => "Run scripts",
        other => other,
    }
}

/// "123456" → "123 456".
pub fn spaced_code(code: &str) -> String {
    if code.len() == 6 {
        format!("{} {}", &code[..3], &code[3..])
    } else {
        code.to_owned()
    }
}

pub struct BrowseLinkCard {
    state: Entity<AppState>,
    status: Option<BrowseLinkStatus>,
    busy: bool,
    error: Option<SharedString>,
    task: Option<Task<()>>,
}

impl BrowseLinkCard {
    pub fn new(state: Entity<AppState>, cx: &mut Context<Self>) -> Self {
        let mut card = Self {
            state,
            status: None,
            busy: false,
            error: None,
            task: None,
        };
        card.refresh(cx);
        card
    }

    fn call(
        &self,
        cx: &App,
        method: &'static str,
    ) -> Option<Task<Result<serde_json::Value, String>>> {
        let engine = self.state.read(cx).engine().cloned()?;
        Some(cx.background_spawn(async move {
            engine
                .client()
                .call(method, serde_json::json!({}))
                .await
                .map_err(|e| e.to_string())
        }))
    }

    /// Re-read the status; keep polling while a pairing code is up.
    fn refresh(&mut self, cx: &mut Context<Self>) {
        let Some(call) = self.call(cx, methods::BROWSE_LINK_STATUS) else {
            return;
        };
        self.task = Some(cx.spawn(async move |this, cx| {
            let mut call = call;
            loop {
                let status = call
                    .await
                    .ok()
                    .and_then(|value| serde_json::from_value::<BrowseLinkStatus>(value).ok());
                let pairing = status.as_ref().is_some_and(|s| s.pairing_code.is_some());
                let Ok(next) = this.update(cx, |card, cx| {
                    if card.status != status {
                        card.status = status;
                        cx.notify();
                    }
                    card.call(cx, methods::BROWSE_LINK_STATUS)
                }) else {
                    return;
                };
                let Some(next) = next.filter(|_| pairing) else {
                    return;
                };
                cx.background_executor().timer(POLL_EVERY).await;
                call = next;
            }
        }));
    }

    fn connect(&mut self, cx: &mut Context<Self>) {
        let Some(call) = self.call(cx, methods::BROWSE_LINK_PAIR) else {
            return;
        };
        self.busy = true;
        self.error = None;
        cx.notify();
        self.task = Some(cx.spawn(async move |this, cx| {
            let result = call.await;
            this.update(cx, |card, cx| {
                card.busy = false;
                if let Err(error) = result {
                    card.error = Some(error.into());
                }
                card.refresh(cx);
            })
            .ok();
        }));
    }

    fn disconnect(&mut self, cx: &mut Context<Self>) {
        let Some(call) = self.call(cx, methods::BROWSE_LINK_DISCONNECT) else {
            return;
        };
        self.error = None;
        self.task = Some(cx.spawn(async move |this, cx| {
            let _ = call.await;
            this.update(cx, |card, cx| card.refresh(cx)).ok();
        }));
    }

    fn body(&self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let status = self.status.clone().unwrap_or_default();
        let note = |text: String| {
            div()
                .text_size(crate::typography::ui_rems(12.0))
                .line_height(px(18.0))
                .text_color(theme.text_muted)
                .child(SharedString::from(text))
        };
        let action = |id: &'static str, label: &'static str| {
            widgets::ghost_action(theme)
                .id(id)
                .hover(|s| widgets::ghost_hover(theme, s))
                .child(label)
        };
        let mut column = div()
            .px(px(20.0))
            .py(px(14.0))
            .flex()
            .flex_col()
            .gap(px(10.0));
        if let Some(code) = &status.pairing_code {
            column = column
                .child(
                    div()
                        .text_size(crate::typography::ui_rems(26.0))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(theme.text)
                        .child(SharedString::from(spaced_code(code))),
                )
                .child(note(
                    "Check that browse shows the same code, then allow Harness there and choose what it may do."
                        .into(),
                ))
                .child(action("browse-link-cancel", "Cancel").on_click(
                    cx.listener(|card, _, _, cx| card.disconnect(cx)),
                ));
        } else if status.paired {
            let badges = status.scopes.iter().fold(
                div()
                    .flex()
                    .flex_row()
                    .flex_wrap()
                    .gap(px(6.0))
                    .child(widgets::badge_active(theme, "Connected")),
                |row, scope| row.child(widgets::badge(theme, scope_label(scope).to_owned())),
            );
            column = column
                .child(badges)
                .child(note(if status.key_mismatch {
                    "A different browse is running than the one Harness connected to. Disconnect and connect again."
                        .into()
                } else if status.browse_running {
                    "New agent runs get browse's tools, with your sign-ins. Each run has its own pages, closed when it ends."
                        .into()
                } else {
                    "browse isn't running with Connected apps on, so agents use Harness's own browser for now."
                        .into()
                }))
                .child(note("Change what Harness may do, or revoke it, in browse › Settings › Agent › Connected apps.".into()))
                .child(action("browse-link-disconnect", "Disconnect").on_click(
                    cx.listener(|card, _, _, cx| card.disconnect(cx)),
                ));
        } else if status.browse_running {
            column = column
                .child(note(
                    "Let agents use browse, with your sign-ins. You'll confirm a code in browse and choose what Harness may do."
                        .into(),
                ))
                .child(
                    action("browse-link-connect", if self.busy { "Connecting…" } else { "Connect" })
                        .on_click(cx.listener(|card, _, _, cx| {
                            if !card.busy {
                                card.connect(cx);
                            }
                        })),
                );
        } else {
            column = column
                .child(note(
                    "Open browse and turn on Settings › Agent › Connected apps to let agents use it with your sign-ins."
                        .into(),
                ))
                .child(action("browse-link-recheck", "Check again").on_click(
                    cx.listener(|card, _, _, cx| card.refresh(cx)),
                ));
        }
        let error = self
            .error
            .clone()
            .or_else(|| status.error.clone().map(SharedString::from));
        column
            .when_some(error, |el, error| {
                el.child(widgets::error_strip(theme, error))
            })
            .into_any_element()
    }
}

impl Render for BrowseLinkCard {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let header = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(px(8.0))
            .child(
                div()
                    .size(px(24.0))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(
                        crate::icons::icon(crate::icons::GLOBE)
                            .size(px(16.0))
                            .text_color(theme.text_muted),
                    ),
            )
            .child(
                div()
                    .text_size(crate::typography::ui_rems(14.0))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(theme.text)
                    .child("browse"),
            );
        div().mt(px(24.0)).flex().flex_col().child(header).child(
            widgets::section_card(&theme)
                .mt(px(8.0))
                .child(self.body(&theme, cx)),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_and_scopes_read_well() {
        assert_eq!(spaced_code("012345"), "012 345");
        assert_eq!(spaced_code("12"), "12");
        assert_eq!(scope_label("act-user-tabs"), "Use your tabs");
        assert_eq!(scope_label("future-scope"), "future-scope");
        let status: BrowseLinkStatus = serde_json::from_value(serde_json::json!({
            "browseRunning": true, "paired": true, "scopes": ["read"], "pairingCode": null,
            "keyMismatch": false, "error": null,
        }))
        .unwrap();
        assert!(status.paired && status.browse_running);
    }
}
