impl Shell {
    pub(super) fn render_sidebar_view_menu_for_review(
        &mut self,
        case: &str,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        self.settings.sidebar_compact = case != "sidebar-show";
        if let Some(menu) = self.sidebar_view_menu.open_mut() {
            menu.submenu = match case {
                "sidebar-organize" => Some(0),
                "sidebar-sort" => Some(1),
                _ => None,
            };
            menu.active = menu.submenu;
            menu.submenu_active = None;
        }
        self.render_sidebar_view_menu(theme, cx)
    }
}
