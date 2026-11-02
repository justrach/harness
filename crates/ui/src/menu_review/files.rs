impl FilesSurface {
    pub(crate) fn review_menu(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let theme = crate::theme::Theme::of(cx).clone();
        if !self.editor_context_menu.is_open() {
            let editor = editor::new_file_editor(
                "A sample document.",
                "notes.txt",
                false,
                &theme,
                window,
                cx,
            );
            self.open_editor_context_menu(
                editor,
                editor::EditorMenuAvailability {
                    cut: true,
                    copy: true,
                    paste: false,
                },
                gpui::point(px(64.0), px(110.0)),
                cx,
            );
        }
        self.render_editor_context_menu(&theme, cx)
            .expect("open editor menu")
    }
}
