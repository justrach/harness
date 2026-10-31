//! Named, scrollable harness tabs. Keep agent selection separate from model
//! search; existing chats stay on their original harness.
use super::*;

impl Pickers {
    pub(super) fn render_harness_tabs(
        &mut self,
        descriptors: &[HarnessDescriptor],
        effective: Option<HarnessId>,
        favorites_view: bool,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let mut tabs = div()
            .id("harness-tabs")
            .flex_none()
            .min_w_0()
            .w_full()
            .overflow_x_scroll()
            .track_scroll(&self.harness_scroll)
            .h(px(40.0))
            .px(px(popover::CARD_INSET))
            .border_b_1()
            .border_color(crate::theme::hairline(0.08))
            .flex()
            .flex_row()
            .items_center()
            .gap(px(2.0))
            .text_size(crate::typography::ui_rems(12.0))
            .text_color(theme.text);
        tabs = tabs.child(
            div()
                .id("model-tab-favorites")
                .relative()
                .flex_none()
                .px(px(8.0))
                .gap(px(5.0))
                .h(px(32.0))
                .rounded(px(popover::MENU_ITEM_RADIUS))
                .flex()
                .items_center()
                .justify_center()
                .cursor_pointer()
                .when(!favorites_view, |el| {
                    el.hover(|s| s.bg(crate::theme::ink(0.06)))
                })
                .on_click(cx.listener(|this, _, _, cx| {
                    this.setting_menu = None;
                    this.model_rail = ModelRail::Favorites;
                    // Anchor on the selected row when it's starred, else
                    // the top — never a stray second highlight.
                    this.active = this.selected_model_index(cx);
                    this.model_scroll_base().set_offset(gpui::Point::default());
                    this.model_scroll
                        .scroll_to_item(this.active, gpui::ScrollStrategy::Nearest);
                    cx.notify();
                }))
                .child(
                    crate::icons::icon(crate::icons::STAR_BOLD)
                        .size(px(15.0))
                        .text_color(if favorites_view {
                            theme.text
                        } else {
                            theme.text_muted
                        }),
                )
                .child("Starred")
                .when(favorites_view, |el| el.child(tab_indicator(theme.accent))),
        );
        for (ix, descriptor) in descriptors.iter().enumerate() {
            let harness = descriptor.id;
            let is_viewed = !favorites_view && effective == Some(harness);
            let (icon_path, tint) = harness_brand_icon(harness);
            tabs =
                tabs.child(
                    div()
                        .id(("harness-tab", ix))
                        .relative()
                        .flex_none()
                        .px(px(8.0))
                        .gap(px(5.0))
                        .h(px(32.0))
                        .rounded(px(popover::MENU_ITEM_RADIUS))
                        .flex()
                        .items_center()
                        .justify_center()
                        .cursor_pointer()
                        .when(!is_viewed, |el| el.hover(|s| s.bg(crate::theme::ink(0.06))))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.setting_menu = None;
                            this.model_rail = ModelRail::Harness;
                            this.pick_harness(harness, cx);
                            this.harness_scroll.scroll_to_item(ix + 1);
                            cx.notify();
                        }))
                        .child(crate::icons::icon(icon_path).size(px(16.0)).text_color(
                            tint.unwrap_or(if is_viewed {
                                theme.text
                            } else {
                                theme.text_muted
                            }),
                        ))
                        .child(SharedString::from(descriptor.name.clone()))
                        .when(is_viewed, |el| el.child(tab_indicator(theme.accent))),
                );
        }

        tabs.into_any_element()
    }

    pub(super) fn cycle_harness(&mut self, backwards: bool, cx: &mut Context<Self>) {
        let descriptors = self.rail_descriptors(cx);
        if self.harness_locked(cx) || descriptors.is_empty() {
            return;
        }
        let current = self.effective_harness(cx);
        #[cfg(feature = "model-picker-preview")]
        let current = if self.preview.enabled {
            self.preview_viewed(cx)
        } else {
            current
        };
        let index = descriptors.iter().position(|d| Some(d.id) == current);
        let next = match (index, backwards) {
            (Some(0), true) | (None, true) => descriptors.len() - 1,
            (Some(index), true) => index - 1,
            (Some(index), false) => (index + 1) % descriptors.len(),
            (None, false) => 0,
        };
        self.setting_menu = None;
        self.model_rail = ModelRail::Harness;
        self.pick_harness(descriptors[next].id, cx);
        self.harness_scroll.scroll_to_item(next + 1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn descriptor(id: HarnessId, name: &str) -> HarnessDescriptor {
        HarnessDescriptor {
            id,
            name: name.into(),
            installed: true,
            can_install: false,
            enabled: Some(true),
            reasoning_levels: Vec::new(),
            steering_mode: harness_proto::SteeringMode::StepBoundary,
            supports_steering: false,
        }
    }

    #[gpui::test]
    fn harness_tabs_cycle_only_runnable_agents_and_clear_foreign_model(
        cx: &mut gpui::TestAppContext,
    ) {
        cx.update(|cx| cx.set_global(Theme::dark()));
        let state = cx.new(|_| AppState::new());
        let pickers = cx.new(|cx| Pickers::new(state, cx));
        pickers.update(cx, |pickers, cx| {
            let mut disabled = descriptor(HarnessId::Cursor, "Cursor");
            disabled.enabled = Some(false);
            let mut missing = descriptor(HarnessId::ClaudeCode, "Claude Code");
            missing.installed = false;
            pickers.harnesses = Loadable::Ready(vec![
                descriptor(HarnessId::Graff, "graff"),
                disabled,
                missing,
                descriptor(HarnessId::Codex, "Codex"),
            ]);
            pickers.config.harness = Some(HarnessId::Graff);
            pickers.config.model = Some("anthropic/claude-sonnet-4-6".into());
            pickers.config.reasoning = Some(ReasoningLevel::High);
            pickers.model_rail = ModelRail::Favorites;
            pickers.cycle_harness(false, cx);
            assert_eq!(pickers.config.harness, Some(HarnessId::Codex));
            assert!(pickers.config.model.is_none());
            assert!(pickers.config.reasoning.is_none());
            assert_eq!(pickers.model_rail, ModelRail::Harness);
            pickers.cycle_harness(false, cx);
            assert_eq!(pickers.config.harness, Some(HarnessId::Graff));
            pickers.cycle_harness(true, cx);
            assert_eq!(pickers.config.harness, Some(HarnessId::Codex));
        });
    }

    #[gpui::test]
    fn harness_tabs_keep_existing_chats_locked_and_empty_catalogs_safe(
        cx: &mut gpui::TestAppContext,
    ) {
        cx.update(|cx| cx.set_global(Theme::dark()));
        let state = cx.new(|_| AppState::new());
        let pickers = cx.new(|cx| Pickers::new(state.clone(), cx));
        pickers.update(cx, |pickers, cx| {
            pickers.harnesses = Loadable::Ready(Vec::new());
            pickers.cycle_harness(false, cx);
            assert_eq!(pickers.config.harness, None);
            pickers.harnesses = Loadable::Ready(vec![
                descriptor(HarnessId::Graff, "graff"),
                descriptor(HarnessId::Codex, "Codex"),
            ]);
            pickers.config.harness = Some(HarnessId::Graff);
            pickers.config.model = Some("saved-model".into());
        });
        state.update(cx, |state, _| {
            state.selected_chat = Some("existing-chat".into())
        });
        pickers.update(cx, |pickers, cx| {
            pickers.cycle_harness(false, cx);
            pickers.cycle_harness(true, cx);
            assert_eq!(pickers.config.harness, Some(HarnessId::Graff));
            assert_eq!(pickers.config.model.as_deref(), Some("saved-model"));
        });
    }
}
