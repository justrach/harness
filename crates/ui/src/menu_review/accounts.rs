impl AccountsPage {
    pub(crate) fn review_menu(&mut self, cx: &mut Context<Self>) -> AnyElement {
        self.device_menu.open(());
        self.render_device_switcher(&Theme::of(cx).clone(), cx)
    }
}
