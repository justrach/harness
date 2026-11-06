impl Changes {
    pub(crate) fn review_menu(
        &mut self,
        case: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme = Theme::of(cx).clone();
        if case == "diff-scope" {
            self.render_scope_menu(&theme, cx)
        } else {
            self.branches = vec!["main".into(), "release".into(), "feature/navigation".into()];
            self.base_ref = Some("main".into());
            if !self.ref_menu.is_open() {
                self.open_ref_menu(window, cx);
            }
            self.render_ref_menu(&theme, cx)
        }
    }
}
