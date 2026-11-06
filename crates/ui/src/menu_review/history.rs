impl GitHistory {
    pub(crate) fn review_menu(&mut self, case: &str, cx: &mut Context<Self>) -> AnyElement {
        let theme = Theme::of(cx).clone();
        if case == "history-author" {
            self.render_author_menu(&theme, cx)
        } else {
            self.render_column_menu(&theme, cx)
        }
    }
}
