impl HarnessesPage {
    pub(crate) fn review_menu(&mut self, case: &str, cx: &mut Context<Self>) -> AnyElement {
        if case.starts_with("keep-awake-") {
            if !self.keep_awake_fixture {
                self.keep_awake_task = None;
                self.keep_awake_fixture = true;
                self.keep_awake_saving = false;
                self.keep_awake = Loadable::Ready(KeepAwake {
                    enabled: case == "keep-awake-on",
                    supported: case != "keep-awake-unsupported",
                });
            }
            let theme = Theme::of(cx).clone();
            return div()
                .w_full()
                .max_w(px(768.0))
                .px(px(24.0))
                .child(
                    div()
                        .flex()
                        .justify_between()
                        .items_center()
                        .child(widgets::page_header(&theme, "Agents", None))
                        .child(
                            div()
                                .flex()
                                .gap(px(6.0))
                                .items_center()
                                .text_size(crate::typography::ui_rems(12.0))
                                .text_color(theme.text_muted)
                                .child(crate::icons::icon(crate::icons::MONITOR).size(px(16.0)))
                                .child(if case == "keep-awake-remote" {
                                    "Studio computer"
                                } else if case == "keep-awake-unsupported" {
                                    "Linux computer"
                                } else {
                                    "This Mac"
                                }),
                        ),
                )
                .children(self.render_keep_awake(&theme, cx))
                .child(
                    widgets::section_card(&theme).child(
                        widgets::card_row(&theme, true)
                            .child(widgets::row_title(&theme, "Claude Agent"))
                            .child(widgets::badge(&theme, "Available")),
                    ),
                )
                .into_any_element();
        }
        if case.starts_with("titles-") {
            self.title_menu = Some(case == "titles-model");
            self.title_settings = Loadable::Ready(TitleSettings {
                harness: Some(HarnessId::Codex),
                model: None,
            });
            self.title_models = Loadable::Ready(vec![harness_proto::Model {
                id: "review-model".into(),
                label: "Review model".into(),
                description: None,
                reasoning_levels: vec![],
                options: vec![],
                maker: None,
                billing: None,
                context: None,
            }]);
            self.harnesses = Loadable::Ready(vec![harness_engine::registry::HarnessDescriptor {
                id: HarnessId::Codex,
                name: "Codex".into(),
                installed: true,
                can_install: false,
                enabled: Some(true),
                reasoning_levels: vec![],
                steering_mode: harness_proto::SteeringMode::StepBoundary,
                supports_steering: false,
            }]);
            return self.render_titles(&Theme::of(cx).clone(), cx);
        }
        self.device_menu_open = true;
        self.render_device_switcher(&Theme::of(cx).clone(), cx)
    }
}
