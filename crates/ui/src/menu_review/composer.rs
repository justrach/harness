impl Composer {
    pub(crate) fn review_menu(&mut self, case: &str, cx: &mut Context<Self>) -> gpui::AnyElement {
        let theme = Theme::of(cx).clone();
        if case == "slash" {
            self.slash.token = slash_token("/", 1);
            self.slash.loading = false;
            let commands = with_workspace_commands(Vec::new(), true);
            self.slash.filtered = (0..commands.len()).collect();
            self.slash.active = Some(0);
            self.slash_cache
                .insert(self.slash.context.clone(), commands);
            self.render_slash_popup(&theme, cx).expect("slash token")
        } else {
            self.mention.token = mention_token("@src", 4);
            self.mention.loading = false;
            self.mention.results = ["src/app.rs", "src/components/menu.rs", "src/theme.rs"]
                .into_iter()
                .map(|path| {
                    serde_json::from_value(serde_json::json!({"path":path,"isDir":false}))
                        .expect("synthetic mention")
                })
                .collect();
            self.mention.active = Some(0);
            self.render_file_mention_popup(&theme, cx)
                .expect("mention token")
        }
    }
}
