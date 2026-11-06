//! Conversation identity belongs to the tab that owns it, including parked drafts.
use super::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::shell) enum TabAttention {
    Input,
    Error,
}

impl TabAttention {
    pub(in crate::shell) fn glyph(self) -> &'static str {
        match self {
            Self::Input => icons::INFO_CIRCLE,
            Self::Error => icons::DANGER_TRIANGLE,
        }
    }

    pub(in crate::shell) fn color(self, theme: &Theme) -> gpui::Hsla {
        match self {
            Self::Input => theme.warning,
            Self::Error => theme.danger,
        }
    }

    pub(in crate::shell) fn label(self) -> &'static str {
        match self {
            Self::Input => "Needs your input",
            Self::Error => "Needs attention — open for details",
        }
    }
}

#[derive(Clone)]
pub(super) struct TabContext {
    pub branch: Option<SharedString>,
    pub harness: Option<harness_proto::HarnessId>,
    pub model: Option<SharedString>,
    pub status: harness_proto::ChatIndicator,
    pub queued: bool,
    pub undelivered: bool,
    pub tooltip: SharedString,
}

impl TabContext {
    pub(super) fn attention(&self) -> Option<TabAttention> {
        // Completion, streaming and a queued send are not requests for action.
        // Reading a tab does not change either of these live conditions.
        if self.undelivered {
            Some(TabAttention::Error)
        } else if self.queued {
            None
        } else {
            match self.status {
                harness_proto::ChatIndicator::AwaitingInput => Some(TabAttention::Input),
                harness_proto::ChatIndicator::Errored => Some(TabAttention::Error),
                _ => None,
            }
        }
    }

    pub fn has_context(&self) -> bool {
        self.branch.is_some() || self.harness.is_some()
    }
}

fn agent_name(harness: harness_proto::HarnessId) -> &'static str {
    use harness_proto::HarnessId::*;
    match harness {
        ClaudeCode => "Claude Code",
        Codex => "Codex",
        Cursor => "Cursor",
        Devin => "Devin",
        Grok => "Grok",
        Hermes => "Hermes",
        Graff => "Codegraff",
        Pi => "Pi",
        Opencode => "opencode",
        Antigravity => "Antigravity",
        Exo => "Exo",
        Mock => "Mock",
    }
}

impl Shell {
    pub(in crate::shell) fn workspace_session_attention(
        &self,
        session: &str,
        cx: &App,
    ) -> Option<(u64, PanelTab, TabAttention)> {
        let layout = self.workspace_panels.layouts.get(session)?;
        for panel in &layout.panels {
            for tab in &panel.tabs {
                let (title, _) = self.panel_tab_label(tab, cx);
                if let Some(attention) = self
                    .panel_tab_context(tab, panel.id, &title, cx)
                    .and_then(|context| context.attention())
                {
                    return Some((panel.id, tab.clone(), attention));
                }
            }
        }
        None
    }

    pub(super) fn panel_tab_context(
        &self,
        tab: &PanelTab,
        panel: u64,
        title: &SharedString,
        cx: &App,
    ) -> Option<TabContext> {
        let now = Utc::now();
        let state = self.state.read(cx);
        let (branch, harness, model, status, queued, undelivered) = match tab {
            PanelTab::Chat(id) => {
                let chat = state.chats.iter().find(|chat| &chat.id == id)?;
                let branch = crate::change_requests::conversation_branch(chat, &state.spaces)
                    .map(str::trim)
                    .filter(|branch| !branch.is_empty())
                    .map(SharedString::from);
                let config = chat.config.as_ref();
                (
                    branch,
                    config.map(|config| config.harness),
                    config.and_then(|config| config.model.clone()),
                    // A failure remains actionable after its messages have been
                    // read. The unread badge's display status intentionally does
                    // not have that lifetime, so use the live error explicitly.
                    if state.indicator_for(id, now) == harness_proto::view::Indicator::Errored {
                        harness_proto::ChatIndicator::Errored
                    } else {
                        state.display_status_for(chat, now)
                    },
                    state.send_queued(id, now),
                    state.send_undelivered(id, now),
                )
            }
            PanelTab::Draft(id) => {
                let active = state.selected_chat.is_none()
                    && self.panel_layout(cx).is_some_and(|layout| {
                        layout.focused == panel
                            && layout.panel(panel).and_then(|panel| panel.selected()) == Some(tab)
                    });
                let picks = self.composer.read(cx).pickers().read(cx);
                let draft = if active {
                    Some(picks.canvas_draft(cx))
                } else {
                    self.workspace_panels.drafts.get(id).cloned()
                };
                (
                    None,
                    draft.as_ref().and_then(|draft| draft.harness),
                    draft.as_ref().and_then(|draft| draft.model.clone()),
                    harness_proto::ChatIndicator::Idle,
                    false,
                    false,
                )
            }
            _ => return None,
        };
        let model = harness.zip(model).map(|(harness, id)| {
            self.composer
                .read(cx)
                .pickers()
                .read(cx)
                .model_label_for(harness, &id)
                .into()
        });
        let mut details = vec![title.to_string()];
        if let Some(branch) = &branch {
            details.push(format!("Branch: {branch}"));
        }
        if let Some(harness) = harness {
            details.push(format!("Agent: {}", agent_name(harness)));
        }
        if let Some(model) = &model {
            details.push(format!("Model: {model}"));
        }
        if undelivered {
            details.push("Message not delivered — open to retry".into());
        } else if queued {
            details.push("Message queued — waiting to send".into());
        } else if let Some(label) = match status {
            harness_proto::ChatIndicator::Working => Some("Working"),
            harness_proto::ChatIndicator::AwaitingInput => Some("Needs your input"),
            harness_proto::ChatIndicator::Errored => Some("Failed — open for details"),
            harness_proto::ChatIndicator::Completed => Some("New activity — open to read"),
            harness_proto::ChatIndicator::Idle => None,
        } {
            details.push(label.into());
        }
        Some(TabContext {
            branch,
            harness,
            model,
            status,
            queued,
            undelivered,
            tooltip: details.join("\n").into(),
        })
    }

    pub(super) fn render_panel_tab_labels(
        &self,
        key: &str,
        title: SharedString,
        context: Option<&TabContext>,
        progress: f32,
        active: bool,
        theme: &Theme,
        _cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(context) = context.filter(|context| context.has_context()) else {
            return div()
                .flex_1()
                .min_w_0()
                .truncate()
                .text_size(crate::typography::ui_rems(12.0))
                .line_height(px(14.0))
                .text_color(if active { theme.text } else { theme.text_muted })
                .child(title)
                .into_any_element();
        };
        let shift = 6.5 * (1.0 - progress);
        // One stable text column: only branch and agent/model reveal on hover.
        let mut metadata = div()
            .debug_selector({
                let key = key.to_string();
                move || format!("{key}-metadata")
            })
            .w_full()
            .min_w_0()
            .h(px(12.0))
            .relative()
            .top(px(shift))
            .opacity(progress)
            .flex()
            .items_center()
            .gap(px(6.0))
            .overflow_hidden()
            .text_size(crate::typography::ui_rems(10.0))
            .line_height(px(12.0))
            .text_color(theme.text_muted);
        if let Some(branch) = &context.branch {
            metadata = metadata.child(div().min_w_0().flex().items_center().child(
                sidebar_faded_label(format!("{key}-branch").into(), false, branch.clone()),
            ));
        }
        if let Some(harness) = context.harness {
            let (glyph, tint) = crate::pickers::harness_brand_icon(harness);
            metadata = metadata.child(
                div()
                    .min_w_0()
                    .flex()
                    .items_center()
                    .gap(px(3.0))
                    .child(
                        div()
                            .debug_selector({
                                let key = key.to_string();
                                move || format!("{key}-agent")
                            })
                            .flex_none()
                            .child(
                                icon(glyph)
                                    .size(px(12.0))
                                    .text_color(tint.unwrap_or(theme.text_muted)),
                            ),
                    )
                    .child(sidebar_faded_label(
                        format!("{key}-model").into(),
                        false,
                        context
                            .model
                            .clone()
                            .unwrap_or_else(|| agent_name(harness).into()),
                    )),
            );
        }
        div()
            .flex_1()
            .min_w_0()
            .h(px(27.0))
            .flex()
            .flex_col()
            .gap(px(1.0))
            .child(
                div()
                    .relative()
                    .top(px(shift))
                    .h(px(14.0))
                    .flex_none()
                    .text_size(crate::typography::ui_rems(12.0))
                    .line_height(px(14.0))
                    .text_color(if active { theme.text } else { theme.text_muted })
                    .when(
                        context.status == harness_proto::ChatIndicator::Completed,
                        |label| label.font_weight(gpui::FontWeight::MEDIUM),
                    )
                    .child(sidebar_faded_label(
                        format!("{key}-title").into(),
                        true,
                        title,
                    )),
            )
            .child(metadata)
            .into_any_element()
    }

    pub(super) fn render_panel_tab_status(
        &self,
        key: &str,
        context: &TabContext,
        progress: f32,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        use harness_proto::ChatIndicator;
        let queued = context.queued && !context.undelivered;
        let failed = context.undelivered || (!queued && context.status == ChatIndicator::Errored);
        let working = context.status == ChatIndicator::Working && !queued && !context.undelivered;
        let unseen = context.status == ChatIndicator::Completed && !queued && !context.undelivered;
        let label = if context.undelivered {
            "Message not delivered — open to retry"
        } else if queued {
            "Message queued — waiting to send"
        } else if failed {
            "Failed — open for details"
        } else if working {
            "Working"
        } else if unseen {
            "New activity — open to read"
        } else if context.status == ChatIndicator::AwaitingInput {
            "Needs your input"
        } else {
            "Idle"
        };
        div()
            .id(SharedString::from(format!("{key}-status")))
            .debug_selector({
                let key = key.to_string();
                move || format!("{key}-status")
            })
            .size(px(14.0))
            .flex_none()
            .opacity(progress)
            .when(progress == 0.0, |slot| slot.invisible())
            .flex()
            .items_center()
            .justify_center()
            .aria_label(label)
            .tooltip(move |_, cx| cx.new(|_| SurfaceTabTooltip { text: label.into() }).into())
            .when(working, |slot| {
                slot.child(loaders::mini_glyph_spinner(
                    format!("{key}-working"),
                    2.0,
                    theme.glyph,
                    cx.entity_id(),
                    cx,
                ))
            })
            .when(unseen, |slot| {
                slot.child(div().size(px(6.0)).rounded_full().bg(theme.accent))
            })
            .when(!working && !unseen && queued, |slot| {
                slot.child(
                    icon(if failed {
                        icons::DANGER_TRIANGLE
                    } else if queued {
                        icons::CLOCK_CIRCLE
                    } else {
                        icons::CHAT_ROUND_LINE
                    })
                    .size(px(12.0))
                    .text_color(if failed {
                        theme.danger
                    } else {
                        theme.warning
                    }),
                )
            })
            .into_any_element()
    }
}

#[cfg(test)]
mod attention_tests {
    use super::*;

    fn context(status: harness_proto::ChatIndicator) -> TabContext {
        TabContext {
            branch: None,
            harness: None,
            model: None,
            status,
            queued: false,
            undelivered: false,
            tooltip: "Test".into(),
        }
    }

    #[test]
    fn tab_attention_requires_an_unresolved_request_or_failure() {
        use harness_proto::ChatIndicator::*;
        for status in [Idle, Working, Completed] {
            assert_eq!(context(status).attention(), None);
        }
        assert_eq!(
            context(AwaitingInput).attention(),
            Some(TabAttention::Input)
        );
        assert_eq!(context(Errored).attention(), Some(TabAttention::Error));
        let mut row = context(Errored);
        row.queued = true;
        assert_eq!(row.attention(), None);
        row.undelivered = true;
        assert_eq!(row.attention(), Some(TabAttention::Error));
        row.undelivered = false;
        row.queued = false;
        row.status = Idle;
        assert_eq!(row.attention(), None);
    }
}
