impl Shell {
    pub(crate) fn review_menu(
        &mut self,
        case: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme = Theme::of(cx).clone();
        let at = gpui::point(px(64.0), px(110.0));
        match case {
            "account" => {
                self.user_menu.open(());
                self.render_user_menu("Sample account".into(), "Local only".into(), &theme, cx)
            }
            "chat" | "chat-copy" => {
                self.chat_menu.open(ChatMenuState {
                    chat_id: "launch-0".into(),
                    position: at,
                    page: if case == "chat" {
                        ChatMenuPage::Root
                    } else {
                        ChatMenuPage::Copy
                    },
                });
                div()
                    .children(self.render_overlays(window.viewport_size(), window, cx))
                    .into_any_element()
            }
            "project-context" => {
                self.space_menu.open(("launch".into(), at));
                div()
                    .children(self.render_space_overlays(window.viewport_size(), window, cx))
                    .into_any_element()
            }
            "section-context" => div()
                .child("Unavailable: historical sidebar groups are excluded from this integration preview.")
                .into_any_element(),
            "project-filter" => {
                if !self.spaces_menu.is_open() {
                    self.open_spaces_menu(window, cx);
                }
                self.render_spaces_menu(&theme, cx)
            }
            "sidebar" | "sidebar-organize" | "sidebar-sort" | "sidebar-show" => {
                if !self.sidebar_view_menu.is_open() {
                    self.fixture_sidebar_submenu(Some(0), window, cx);
                }
                self.render_sidebar_view_menu_for_review(case, &theme, cx)
            }
            "project-actions" => self.review_project_actions(window, cx),
            "add-panel" => {
                if self.subagent_tabs.is_empty() {
                    self.active_chat = "launch-0".into();
                    self.add_subagent_surface(
                        "launch-0".into(),
                        "review-agent".into(),
                        "Review".into(),
                        false,
                        self.transcript.clone(),
                        cx,
                    );
                }
                self.right_plus.open(());
                self.render_right_tab_strip(cx)
            }
            _ => unreachable!("unknown shell menu: {case}"),
        }
    }
}
