//! Rebind surface events to the Shell and native window that now owns them.
use super::*;

impl Shell {
    pub(crate) fn subscribe_window_browser(
        &mut self,
        id: u64,
        owner: String,
        browser: &Entity<crate::browser::BrowserSurface>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Subscription {
        cx.subscribe_in(&browser, window, move |this, _, event, window, cx| {
            match event {
                crate::browser::BrowserEvent::Changed => cx.notify(),
                crate::browser::BrowserEvent::NewTab(url) => {
                    // A background page cannot open a tab in the wrong session.
                    if matches!(this.route, Route::Chat) && this.visible_workspace_browsers(cx).contains(&id)
                        && (owner.starts_with("workspace:") || owner.starts_with("space-canvas:") || this.chat_navigation_is_live(&owner, cx)) {
                        this.workspace_panels.resource_owner = Some(owner.clone());
                        this.add_browser_surface(url.clone(), window, cx);
                        this.workspace_panels.resource_owner = None;
                    }
                }
                crate::browser::BrowserEvent::OpenSource(path) => {
                    if matches!(this.route, Route::Chat) && this.visible_workspace_browsers(cx).contains(&id)
                        && (owner.starts_with("workspace:") || owner.starts_with("space-canvas:") || this.chat_navigation_is_live(&owner, cx)) {
                        this.workspace_panels.resource_owner = Some(owner.clone());
                        this.open_workspace_file_link(path, window, cx);
                        this.workspace_panels.resource_owner = None;
                    }
                }
                crate::browser::BrowserEvent::Close => {
                    this.close_right_surface(RightSurface::Browser(id), window, cx)
                }
            }
        })
    }

    pub(crate) fn subscribe_window_file(
        &mut self,
        id: u64,
        event_panel_key: String,
        file: &Entity<FilesSurface>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Subscription {
        cx.subscribe_in(
            &file,
            window,
            move |this: &mut Self, source, event, window, cx| {
                if matches!(
                    event,
                    FilesEvent::OpenFile(_)
                        | FilesEvent::OpenFileAtAnchor { .. }
                        | FilesEvent::RevealFile(_)
                ) && !this.accepts_file_navigation(&event_panel_key, &source, cx)
                {
                    return;
                }
                match event {
                    FilesEvent::OpenFile(path) | FilesEvent::OpenFileAtAnchor { path, .. } => {
                        let previous_owner = this
                            .workspace_panels
                            .resource_owner
                            .replace(event_panel_key.clone());
                        let engine_owner = source.read(cx).session_owner().to_owned();
                        let previous_engine = this
                            .workspace_panels
                            .resource_engine_owner
                            .replace(engine_owner);
                        if let FilesEvent::OpenFileAtAnchor { anchor, .. } = event {
                            this.add_file_surface_at_anchor(
                                path.clone(),
                                anchor.clone(),
                                window,
                                cx,
                            );
                        } else {
                            this.add_file_surface(path.clone(), window, cx);
                        }
                        this.workspace_panels.resource_owner = previous_owner;
                        this.workspace_panels.resource_engine_owner = previous_engine;
                    }
                    FilesEvent::RevealFile(path) => {
                        let previous_owner = this
                            .workspace_panels
                            .resource_owner
                            .replace(event_panel_key.clone());
                        let engine_owner = source.read(cx).session_owner().to_owned();
                        let previous_engine = this
                            .workspace_panels
                            .resource_engine_owner
                            .replace(engine_owner);
                        this.add_files_surface(window, cx);
                        if let Some(files) = this.files.get(&this.panel_key(cx)).cloned() {
                            files.update(cx, |files, cx| {
                                files.reveal_file_explicit(path.clone(), cx)
                            });
                        }
                        this.workspace_panels.resource_owner = previous_owner;
                        this.workspace_panels.resource_engine_owner = previous_engine;
                    }
                    FilesEvent::OpenWebLink(activation) => {
                        if let crate::markdown::render::LinkOutcome::External(url) =
                            this.activate_session_link(activation, window, cx)
                        {
                            cx.open_url(&url);
                        }
                    }
                    FilesEvent::TitleChanged => cx.notify(),
                    FilesEvent::FileRenamed { old_path, new_path } => {
                        this.rename_file_surface(id, &event_panel_key, old_path, new_path, cx)
                    }
                    FilesEvent::WordWrapChanged(word_wrap) => {
                        this.set_files_word_wrap(*word_wrap, window, cx)
                    }
                    FilesEvent::AddProject => this.open_files_project(&source, cx),
                    FilesEvent::ShowAllFilesChanged(show_all_files) => {
                        this.set_files_show_all(*show_all_files, cx)
                    }
                    FilesEvent::CloseReady => {
                        this.on_file_close_ready(RightSurface::File(id), &event_panel_key, cx)
                    }
                    FilesEvent::CloseCancelled => {
                        this.cancel_file_close(RightSurface::File(id), cx)
                    }
                }
            },
        )
    }
}
