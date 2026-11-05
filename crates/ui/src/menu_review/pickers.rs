impl Pickers {
    pub(crate) fn review_menu(&mut self, case: &str, cx: &mut Context<Self>) -> AnyElement {
        let kind = match case {
            "device" => PickerKind::Device,
            "project" => PickerKind::Space,
            "branch" => PickerKind::Branch,
            "checkout" => PickerKind::Checkout,
            _ => PickerKind::HarnessModel,
        };
        if self.open.get() != Some(&kind) {
            self.open.open(kind);
        }
        self.active = 0;
        self.refs = Loadable::Ready(
            ["main", "release", "feature/navigation"]
                .into_iter()
                .enumerate()
                .map(|(i, name)| RepoRef {
                    name: name.into(),
                    current: i == 0,
                    worktree_path: None,
                })
                .collect(),
        );
        if kind == PickerKind::HarnessModel {
            self.config.harness = Some(HarnessId::Graff);
            self.config.model = Some("review-model".into());
            self.config.reasoning = Some(ReasoningLevel::High);
            self.harnesses = Loadable::Ready(vec![HarnessDescriptor {
                id: HarnessId::Graff,
                name: "graff".into(),
                installed: true,
                can_install: false,
                enabled: Some(true),
                reasoning_levels: vec![],
                steering_mode: harness_proto::SteeringMode::StepBoundary,
                supports_steering: false,
            }]);
            self.models.insert(
                HarnessId::Graff,
                Loadable::Ready(vec![Model {
                    id: "review-model".into(),
                    label: "Review model".into(),
                    description: Some("Synthetic model for menu review".into()),
                    reasoning_levels: vec![
                        ReasoningLevel::Low,
                        ReasoningLevel::Medium,
                        ReasoningLevel::High,
                    ],
                    options: vec![harness_proto::ModelOption {
                        id: "contextWindow".into(),
                        label: "Context window".into(),
                        choices: ["200k", "1m"]
                            .into_iter()
                            .map(|v| harness_proto::ModelOptionChoice {
                                id: v.into(),
                                label: v.into(),
                            })
                            .collect(),
                        default_choice: "200k".into(),
                    }],
                    maker: None,
                    billing: None,
                    context: None,
                }]),
            );
            self.open_model_height = model_menu_height(2);
            let setting = if case == "model-reasoning" {
                Some(ModelSetting::Reasoning)
            } else if case == "model-context" {
                self.setting_groups(cx).get(1).map(|g| g.id.clone())
            } else {
                None
            };
            if self.setting_menu != setting {
                self.setting_menu = None;
                if let Some(id) = setting {
                    self.open_setting(id, cx);
                }
            }
        }
        let content = match kind {
            PickerKind::Device => self.render_device_popover(cx),
            PickerKind::Space => self.render_space_popover(cx),
            PickerKind::Branch => self.render_branch_popover(cx),
            PickerKind::Checkout => self.render_checkout_popover(cx),
            PickerKind::HarnessModel => self.render_harness_model_popover(cx),
        };
        if kind == PickerKind::HarnessModel {
            self.popover_frame_flush(304.0, content, cx)
        } else {
            self.popover_frame(280.0, content, cx)
        }
    }
}
