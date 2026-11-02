use super::*;
use harness_proto::{
    WorkspaceDirectoryPage, WorkspaceEntry, WorkspaceEntryKind, WorkspaceFileSearchMatch,
};

impl FilesSurface {
    pub(crate) fn fixture_explorer(&mut self, phase: &str, cx: &mut Context<Self>) {
        // Only seed the fixture's private temporary project. Its real watcher
        // can then reconcile without erasing the demonstration rows.
        if let Some(project) = self.state.read(cx).space_row("launch") {
            let root = std::path::Path::new(&project.path);
            if root.starts_with(std::env::temp_dir()) {
                for folder in ["src/components", "docs", "assets"] {
                    std::fs::create_dir_all(root.join(folder)).unwrap();
                }
                for file in [
                    "src/components/file_browser.rs",
                    "src/components/project_picker.rs",
                    "src/main.rs",
                    "src/theme.rs",
                    "src/workspace.rs",
                    "Cargo.toml",
                    "package.json",
                    "release-notes.md",
                ] {
                    let _ = std::fs::OpenOptions::new()
                        .write(true)
                        .create_new(true)
                        .open(root.join(file));
                }
            }
        }
        self.state.update(cx, |state, _| {
            for project in &mut state.spaces {
                project.path = format!("/fixtures/{}", project.id);
            }
        });
        self.loads.clear();
        self.watch_task = None;
        self.error = None;
        self.started = true;
        self.choosing_project = phase == "empty";
        self.chat_id = if phase == "empty" {
            "space-canvas:"
        } else {
            "space-canvas:launch"
        }
        .into();
        self.request_context = FilesRequestContext::for_chat(self.state.read(cx), &self.chat_id);
        self.clear_search(cx);
        self.tree.reset();
        let generation = self.tree.generation();
        for (directory, names) in [
            (
                "",
                vec![
                    ("src", true),
                    ("docs", true),
                    ("assets", true),
                    ("Cargo.toml", false),
                    ("README.md", false),
                    ("package.json", false),
                    ("release-notes.md", false),
                ],
            ),
            (
                "src",
                vec![
                    ("components", true),
                    ("main.rs", false),
                    ("theme.rs", false),
                    ("workspace.rs", false),
                ],
            ),
            (
                "src/components",
                vec![("file_browser.rs", false), ("project_picker.rs", false)],
            ),
        ] {
            self.tree.apply_page(
                WorkspaceDirectoryPage {
                    directory: directory.into(),
                    entries: names
                        .into_iter()
                        .map(|(name, dir)| WorkspaceEntry {
                            path: if directory.is_empty() {
                                name.into()
                            } else {
                                format!("{directory}/{name}")
                            },
                            name: name.into(),
                            kind: if dir {
                                WorkspaceEntryKind::Directory
                            } else {
                                WorkspaceEntryKind::File
                            },
                            size: None,
                            modified_at: None,
                            ignored: false,
                            read_only: false,
                        })
                        .collect(),
                    next_cursor: None,
                    truncated: false,
                },
                generation,
            );
            if !directory.is_empty() {
                self.tree.expand(directory);
            }
        }
        self.tree.select("src/components/file_browser.rs");
        self.sync_tree_list();
        if phase == "search" {
            self.search
                .update(cx, |input, cx| input.set_text("file", cx));
            self.search_state.task = None;
            self.search_state.query = "file".into();
            self.search_state.loading = false;
            self.search_state.error = None;
            self.search_state.results = vec![WorkspaceFileSearchMatch {
                path: "src/components/file_browser.rs".into(),
                name: "file_browser.rs".into(),
                kind: WorkspaceEntryKind::File,
                score: 100,
            }];
            self.fixture_search_results();
        }
        cx.notify();
    }
}
