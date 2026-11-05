impl AppearancePage {
    pub(crate) fn review_menu(&mut self, case: &str, cx: &mut Context<Self>) -> AnyElement {
        let theme = Theme::of(cx).clone();
        if case.starts_with("theme-") {
            let tone = if case == "theme-light" {
                Appearance::Light
            } else {
                Appearance::Dark
            };
            self.theme_menu_mut(tone).open(());
            let selection = crate::settings::current(cx).theme_selection.clone();
            return self.render_theme_selector(tone, &selection, &theme, cx);
        }
        let kind = if case.starts_with("terminal") {
            FontKind::Terminal
        } else if case.starts_with("code-") {
            FontKind::Code
        } else {
            FontKind::Ui
        };
        if case.ends_with("size") {
            self.size_menu_mut(kind).open(());
            self.render_size_picker(kind, &theme, theme.font_sans.clone(), cx)
        } else {
            self.font_menu_mut(kind).open(());
            self.render_font_picker(
                kind,
                &theme,
                &crate::typography::availability(cx),
                theme.font_sans.clone(),
                cx,
            )
        }
    }
}
