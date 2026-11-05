impl Shell {
    pub(super) fn review_project_actions(
        &mut self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let snapshot: ProjectActionsSnapshot = serde_json::from_value(serde_json::json!({
            "spaceId": "launch", "actions": [
                {"id":"preview", "name":"Start preview", "command":"npm run dev", "icon":"play", "runOnWorktreeCreate":false},
                {"id":"check", "name":"Run checks", "command":"npm test", "icon":"play", "runOnWorktreeCreate":false}
            ], "importableActions":[], "projectFileIssue":null
        })).expect("synthetic action data");
        self.render_project_actions_menu(
            &ProjectActionsStatus::Ready(snapshot.clone()),
            &snapshot,
            window.viewport_size().height,
            cx,
        )
    }
}
