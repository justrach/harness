//! Exercise the explorer and editors against an isolated real workspace/RPC.
//! Set HARNESS_FILES_CAPTURES to a directory to run on X11 and capture the fixture.
use super::workspace_panels::PanelTab;
use super::*;
use gpui::{AppContext, AsyncApp, WindowHandle};
use std::{path::Path, sync::Arc};

struct ClosedFixture;
impl Render for ClosedFixture {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full()
    }
}

async fn pause(cx: &mut AsyncApp) {
    cx.background_executor()
        .timer(Duration::from_millis(50))
        .await;
}

async fn wait_for(
    window: WindowHandle<Shell>,
    cx: &mut AsyncApp,
    label: &str,
    predicate: impl Fn(&Shell, &App) -> bool,
) {
    for _ in 0..200 {
        gpui::AnyWindowHandle::from(window)
            .update(cx, |_, window, cx| {
                window.refresh();
                let _ = window.draw(cx);
            })
            .unwrap();
        if window
            .update(cx, |shell, window, cx| {
                window.refresh();
                predicate(shell, cx)
            })
            .unwrap()
        {
            return;
        }
        pause(cx).await;
    }
    panic!("timed out waiting for {label}");
}

async fn frame(window: WindowHandle<Shell>, cx: &mut AsyncApp, output: Option<&Path>, name: &str) {
    for _ in 0..6 {
        pause(cx).await;
    }
    gpui::AnyWindowHandle::from(window)
        .update(cx, |_, window, cx| {
            window.refresh();
            let _ = window.draw(cx);
        })
        .unwrap();
    if let Some(output) = output {
        std::fs::create_dir_all(output).unwrap();
        let status = std::process::Command::new("import")
            .args(["-window", "Files panel fixture"])
            .arg(output.join(format!("{name}.png")))
            .status()
            .unwrap();
        assert!(status.success(), "fixture capture failed");
    }
}

fn explorer_visible(shell: &Shell, explorer: u64, cx: &App) -> bool {
    shell.panel_layout(cx).is_some_and(|layout| {
        layout.panels.iter().any(|panel| {
            layout.expanded.is_none_or(|id| id == panel.id)
                && panel.selected() == Some(&PanelTab::FileTree(explorer))
        })
    })
}

fn assert_panel_geometry(shell: &Shell, window: &Window, cx: &App) -> usize {
    let workspace = shell.workspace_layout_key(cx);
    let layout = shell.panel_layout(cx).unwrap();
    let measured = shell.workspace_panels.panel_bounds.borrow();
    let viewport = window.viewport_size();
    let mut visible: Vec<gpui::Bounds<Pixels>> = Vec::new();
    for panel in &layout.panels {
        if layout.expanded.is_some_and(|id| id != panel.id) {
            continue;
        }
        let bounds = *measured
            .get(&(workspace.clone(), panel.id))
            .expect("a visible workspace panel must have painted bounds");
        assert!(bounds.size.width > px(0.0) && bounds.size.height > px(0.0));
        assert!(bounds.left() >= px(0.0) && bounds.top() >= px(0.0));
        assert!(bounds.right() <= viewport.width + px(1.0));
        assert!(bounds.bottom() <= viewport.height + px(1.0));
        for other in &visible {
            assert!(
                bounds.right() <= other.left()
                    || other.right() <= bounds.left()
                    || bounds.bottom() <= other.top()
                    || other.bottom() <= bounds.top(),
                "visible workspace panels must not overlap"
            );
        }
        visible.push(bounds);
    }
    visible.len()
}

fn open_explorer_file(explorer: &Entity<FilesSurface>, path: &str, cx: &mut AsyncApp) {
    explorer.update(cx, |files, cx| {
        files.reveal_file_explicit(path.into(), cx);
        cx.emit(FilesEvent::OpenFile(path.into()));
    });
}

#[test]
fn files_panel_workspace_navigation_and_external_updates() {
    let directory = tempfile::tempdir().unwrap();
    let project = directory.path().join("project");
    std::fs::create_dir_all(project.join("src/nested")).unwrap();
    std::fs::write(
        project.join("src/nested/main.rs"),
        "fn main() { println!(\"Hello\"); }\n",
    )
    .unwrap();
    std::fs::write(
        project.join("README.md"),
        "# Workspace\n\nAn independent file explorer.\n",
    )
    .unwrap();
    let runtime = tokio::runtime::Runtime::new().unwrap();
    for args in [
        vec!["init", "-b", "main"],
        vec!["add", "."],
        vec!["commit", "-m", "fixture"],
    ] {
        let result = std::process::Command::new("git")
            .args(args)
            .current_dir(&project)
            .env("GIT_AUTHOR_NAME", "Fixture")
            .env("GIT_AUTHOR_EMAIL", "fixture@example.test")
            .env("GIT_COMMITTER_NAME", "Fixture")
            .env("GIT_COMMITTER_EMAIL", "fixture@example.test")
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
    }
    std::fs::write(
        project.join("README.md"),
        "# Workspace\n\nChanged documentation.\n",
    )
    .unwrap();
    std::fs::write(project.join("src/new.rs"), "// new file\n").unwrap();
    let core = runtime
        .block_on(async {
            harness_engine::EngineCore::assemble(
                &directory.path().join("engine"),
                Arc::new(harness_engine::default_registry()),
                harness_proto::HarnessId::Mock,
                None,
            )
        })
        .unwrap();
    core.workspace
        .create_space(
            "project",
            &core.device_id,
            &project.to_string_lossy(),
            Some("Workspace".into()),
            false,
        )
        .unwrap();
    for id in ["first", "second"] {
        core.workspace
            .create_chat(
                id,
                Some("project"),
                None,
                None,
                Some(project.to_string_lossy().into_owned()),
            )
            .unwrap();
        core.workspace
            .rename_chat(id, &format!("Explore files · {id}"))
            .unwrap();
    }
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let _ipc = runtime
        .block_on(harness_engine::serve_ipc(port, core.rpc_service()))
        .unwrap();
    let output = std::env::var_os("HARNESS_FILES_CAPTURES").map(PathBuf::from);
    let application = if output.is_some() {
        gpui_platform::application()
    } else {
        gpui_platform::headless()
    };
    application
        .with_assets(crate::icons::Assets)
        .run(move |cx| {
            gpui_tokio::init(cx);
            gpui_base::init(cx);
            let data = directory.path().join("ui");
            let settings = UiSettings::default();
            settings::init(settings.clone(), &data, cx);
            let fonts = crate::typography::register_fonts(cx);
            crate::typography::init(
                settings.ui_font_family.clone(),
                settings.ui_font_size,
                settings.terminal_font_family.clone(),
                settings.terminal_font_size,
                settings.code_font_family.clone(),
                settings.code_font_size,
                fonts,
                cx,
            );
            crate::theme_library::init(data.clone(), cx);
            crate::appearance::init(
                crate::appearance::AppearanceMode::Dark,
                settings.theme_selection.clone(),
                settings.accent,
                settings.surface,
                cx,
            );
            crate::history::init(
                settings.git_history_columns,
                settings.git_history_column_widths,
                settings.git_history_column_order,
                settings.git_history_author_display,
                cx,
            );
            crate::composer::init(cx, settings.composer_send_behavior);
            crate::terminal::panel::init(cx);
            crate::app_menus::init(cx);
            let boot = EngineBootConfig {
                data_dir: data,
                ipc_port: port,
                edge_url: String::new(),
                edge_token: None,
                org_id: None,
                codegraff_client_id: None,
                default_harness: harness_proto::HarnessId::Mock,
            };
            let state = cx.new(|_| AppState::new());
            let window = cx
                .open_window(
                    gpui::WindowOptions {
                        window_bounds: Some(gpui::WindowBounds::Windowed(gpui::Bounds::new(
                            gpui::Point::default(),
                            gpui::size(px(1400.0), px(800.0)),
                        ))),
                        ..Default::default()
                    },
                    |window, cx| {
                        window.set_window_title("Files panel fixture");
                        cx.new(|cx| Shell::new(state.clone(), boot.clone(), cx))
                    },
                )
                .unwrap();
            AppState::bootstrap(state.clone(), boot, cx);
            cx.spawn(async move |cx| {
                // Keep the temporary store, workspace and daemon alive throughout the UI run.
                let _directory = directory;
                wait_for(window, cx, "engine and chats", |shell, cx| {
                    shell.state.read(cx).engine().is_some() && shell.state.read(cx).chats.len() == 2
                })
                .await;
                state.update(cx, |state, cx| state.select_chat(Some("first".into()), cx));
                wait_for(window, cx, "first session", |shell, _| {
                    shell.active_chat == "first"
                })
                .await;
                let (first_session, first_owner, explorer_id, first_explorer) = window
                    .update(cx, |shell, window, cx| {
                        shell.splash = SplashPhase::Gone;
                        shell.ensure_workspace_sessions(cx);
                        shell.open_workspace_files(window, cx);
                        let id = shell.workspace_panels.seq;
                        let (explorer, _, owner) = &shell.workspace_panels.explorers[&id];
                        (
                            shell.chat_tabs[shell.chat_tab].id.clone(),
                            owner.clone(),
                            id,
                            explorer.clone(),
                        )
                    })
                    .unwrap();
                let first_engine_owner =
                    first_explorer.read_with(cx, |files, _| files.session_owner().to_owned());
                assert_eq!(first_engine_owner, "first");
                let file_key = |path: &str| {
                    (
                        first_owner.clone(),
                        first_engine_owner.clone(),
                        path.to_owned(),
                    )
                };
                wait_for(
                    window,
                    cx,
                    "workspace explorer root listing",
                    |shell, cx| {
                        explorer_visible(shell, explorer_id, cx)
                            && first_explorer.read(cx).tree().node("src").is_some()
                    },
                )
                .await;
                frame(window, cx, output.as_deref(), "01-chat-files").await;
                window
                    .update(cx, |shell, window, cx| {
                        assert_eq!(assert_panel_geometry(shell, window, cx), 2);
                    })
                    .unwrap();
                wait_for(
                    window,
                    cx,
                    "Git decorations without a Diffs panel",
                    |_, cx| {
                        let files = first_explorer.read(cx);
                        let theme = Theme::of(cx);
                        files.test_git_color("README.md", false, cx) == Some(theme.warning)
                            && files.test_git_color("src/new.rs", false, cx) == Some(theme.success)
                            && files.test_git_color("src", true, cx) == Some(theme.success)
                            && files
                                .test_git_color("src/nested/main.rs", false, cx)
                                .is_none()
                    },
                )
                .await;
                window
                    .update(cx, |shell, _, cx| {
                        let other = cx.new(|cx| {
                            FilesSurface::new_explorer(
                                shell.state.clone(),
                                "second".into(),
                                false,
                                cx,
                            )
                        });
                        other.update(cx, |files, cx| files.ensure_git_status(cx));
                        assert_eq!(
                            first_explorer.read(cx).test_git_source(),
                            other.read(cx).test_git_source(),
                            "chats on the same checkout share one status source"
                        );
                    })
                    .unwrap();

                // Reveal/select the row, then use the workspace explorer's real
                // event subscription to choose the adjacent editor and its owner.
                open_explorer_file(&first_explorer, "src/nested/main.rs", cx);
                wait_for(window, cx, "nested file and selection", |shell, cx| {
                    first_explorer.read(cx).tree().selected() == Some("src/nested/main.rs")
                        && shell
                            .file_surface_keys
                            .get(&file_key("src/nested/main.rs"))
                            .is_some_and(|id| {
                                shell.file_surfaces[id]
                                    .read(cx)
                                    .test_document_text("src/nested/main.rs")
                                    .is_some_and(|text| text.contains("Hello"))
                            })
                })
                .await;
                let first_file = window
                    .update(cx, |shell, _, cx| {
                        let tree = first_explorer.read(cx).tree();
                        assert!(tree.is_expanded("src") && tree.is_expanded("src/nested"));
                        assert!(
                            shell.file_surfaces.values().all(|file| file
                                .read(cx)
                                .tree()
                                .visible_rows()
                                .is_empty()),
                            "editors must not load hidden trees"
                        );
                        shell.file_surface_keys[&file_key("src/nested/main.rs")]
                    })
                    .unwrap();
                frame(window, cx, output.as_deref(), "02-editor-files").await;
                open_explorer_file(&first_explorer, "README.md", cx);
                wait_for(window, cx, "second file tab", |shell, cx| {
                    shell
                        .file_surface_keys
                        .get(&file_key("README.md"))
                        .is_some_and(|id| {
                            *id != first_file
                                && shell.file_surfaces[id]
                                    .read(cx)
                                    .test_document_text("README.md")
                                    .is_some_and(|text| text.contains("Changed documentation"))
                        })
                })
                .await;
                frame(window, cx, output.as_deref(), "02b-two-file-tabs").await;
                window
                    .update(cx, |shell, window, cx| shell.toggle_files_panel(window, cx))
                    .unwrap();
                frame(
                    window,
                    cx,
                    output.as_deref(),
                    "02c-two-file-tabs-explorer-hidden",
                )
                .await;
                window
                    .update(cx, |shell, window, cx| {
                        assert!(!explorer_visible(shell, explorer_id, cx));
                        assert_eq!(assert_panel_geometry(shell, window, cx), 1);
                        assert!(
                            shell
                                .panel_layout(cx)
                                .unwrap()
                                .hidden_tools
                                .iter()
                                .any(|(_, _, _, tab)| *tab == PanelTab::FileTree(explorer_id))
                        );
                        assert_eq!(
                            shell.workspace_panels.explorers[&explorer_id].0, first_explorer,
                            "hiding an explorer retains its workspace-owned entity"
                        );
                        shell.toggle_files_panel(window, cx);
                        assert!(explorer_visible(shell, explorer_id, cx));
                    })
                    .unwrap();
                open_explorer_file(&first_explorer, "src/nested/main.rs", cx);
                frame(window, cx, None, "restored-files").await;
                window
                    .update(cx, |shell, _, cx| {
                        assert_eq!(
                            shell.file_surface_keys[&file_key("src/nested/main.rs")],
                            first_file
                        );
                        shell.toggle_chat_pane_zoom(cx);
                    })
                    .unwrap();
                frame(window, cx, output.as_deref(), "03-expanded-editor").await;
                window
                    .update(cx, |shell, window, cx| {
                        assert_eq!(assert_panel_geometry(shell, window, cx), 1);
                        assert!(!explorer_visible(shell, explorer_id, cx));
                        shell.toggle_chat_pane_zoom(cx);
                        window.resize(gpui::size(px(1000.0), px(720.0)));
                        window.bounds_changed(cx);
                    })
                    .unwrap();
                frame(window, cx, output.as_deref(), "04-narrow-files").await;
                window
                    .update(cx, |shell, window, cx| {
                        assert!(explorer_visible(shell, explorer_id, cx));
                        assert_eq!(assert_panel_geometry(shell, window, cx), 2);
                    })
                    .unwrap();
                // A browser surface coexists with the explorer and keeps its own tab.
                window
                    .update(cx, |shell, window, cx| {
                        shell.add_browser_surface(None, window, cx)
                    })
                    .unwrap();
                frame(window, cx, output.as_deref(), "05-browser-files").await;
                window
                    .update(cx, |shell, window, cx| {
                        assert!(explorer_visible(shell, explorer_id, cx));
                        assert_eq!(assert_panel_geometry(shell, window, cx), 2);
                        assert!(shell.panel_layout(cx).unwrap().panels.iter().any(|panel| {
                            panel.tabs.iter().any(|tab| {
                                matches!(
                                    tab,
                                    PanelTab::Surface {
                                        surface: RightSurface::Browser(_),
                                        ..
                                    }
                                )
                            })
                        }));
                    })
                    .unwrap();
                open_explorer_file(&first_explorer, "src/nested/main.rs", cx);
                frame(window, cx, None, "selected-editor").await;
                window
                    .update(cx, |shell, window, cx| shell.toggle_files_panel(window, cx))
                    .unwrap();
                std::fs::write(
                    project.join("src/nested/main.rs"),
                    "fn main() { println!(\"Updated\"); }\n",
                )
                .unwrap();
                wait_for(
                    window,
                    cx,
                    "document update with explorer hidden",
                    |shell, cx| {
                        !explorer_visible(shell, explorer_id, cx)
                            && shell.file_surfaces[&first_file]
                                .read(cx)
                                .test_document_text("src/nested/main.rs")
                                .is_some_and(|text| text.contains("Updated"))
                    },
                )
                .await;

                // Events queued in an inactive session must never open a tab in another.
                let before_inactive_event = window
                    .update(cx, |shell, _, cx| {
                        shell.create_workspace_session(cx);
                        shell.file_surface_keys.clone()
                    })
                    .unwrap();
                state.update(cx, |state, cx| state.select_chat(Some("second".into()), cx));
                wait_for(window, cx, "second session", |shell, _| {
                    shell.active_chat == "second"
                })
                .await;
                let second_owner = window
                    .update(cx, |shell, _, cx| shell.panel_key(cx))
                    .unwrap();
                assert_ne!(first_owner, second_owner);
                first_explorer.update(cx, |_, cx| {
                    cx.emit(FilesEvent::OpenFile("src/new.rs".into()))
                });
                frame(window, cx, None, "inactive-event").await;
                window
                    .update(cx, |shell, _, _| {
                        assert_eq!(shell.file_surface_keys, before_inactive_event);
                    })
                    .unwrap();
                window
                    .update(cx, |shell, _, cx| {
                        shell.activate_workspace_session(&first_session, cx)
                    })
                    .unwrap();
                wait_for(window, cx, "restored session", |shell, _| {
                    shell.active_chat == "first"
                })
                .await;
                window
                    .update(cx, |shell, window, cx| {
                        assert!(!explorer_visible(shell, explorer_id, cx));
                        shell.toggle_files_panel(window, cx);
                        assert!(explorer_visible(shell, explorer_id, cx));
                        assert_eq!(
                            shell.workspace_panels.explorers[&explorer_id].0,
                            first_explorer
                        );
                    })
                    .unwrap();
                std::fs::rename(
                    project.join("src/nested/main.rs"),
                    project.join("src/nested/renamed.rs"),
                )
                .unwrap();
                wait_for(window, cx, "renamed file and tab", |shell, cx| {
                    shell
                        .file_surface_keys
                        .get(&file_key("src/nested/renamed.rs"))
                        == Some(&first_file)
                        && !shell
                            .file_surface_keys
                            .contains_key(&file_key("src/nested/main.rs"))
                        && first_explorer
                            .read(cx)
                            .tree()
                            .node("src/nested/renamed.rs")
                            .is_some()
                        && shell.file_surfaces[&first_file]
                            .read(cx)
                            .test_document_text("src/nested/renamed.rs")
                            .is_some_and(|text| text.contains("Updated"))
                })
                .await;
                open_explorer_file(&first_explorer, "src/nested/renamed.rs", cx);
                wait_for(window, cx, "renamed file selection", |shell, cx| {
                    first_explorer.read(cx).tree().selected() == Some("src/nested/renamed.rs")
                        && shell
                            .file_surface_keys
                            .get(&file_key("src/nested/renamed.rs"))
                            == Some(&first_file)
                })
                .await;
                std::fs::remove_file(project.join("src/nested/renamed.rs")).unwrap();
                wait_for(window, cx, "deleted file", |shell, cx| {
                    first_explorer
                        .read(cx)
                        .tree()
                        .node("src/nested/renamed.rs")
                        .is_none()
                        && shell.file_surfaces[&first_file]
                            .read(cx)
                            .test_document_phase("src/nested/renamed.rs")
                            .as_deref()
                            == Some("DeletedOnDisk")
                })
                .await;
                core.workspace.set_chat_archived("first", true).unwrap();
                wait_for(window, cx, "archived session", |shell, cx| {
                    shell
                        .state
                        .read(cx)
                        .chats
                        .iter()
                        .any(|chat| chat.id == "first" && chat.archived)
                })
                .await;
                window
                    .update(cx, |shell, window, cx| {
                        assert!(explorer_visible(shell, explorer_id, cx));
                        assert_eq!(
                            shell.workspace_panels.explorers[&explorer_id].0,
                            first_explorer
                        );
                        shell.toggle_files_panel(window, cx);
                        assert!(!explorer_visible(shell, explorer_id, cx));
                        shell.toggle_files_panel(window, cx);
                        assert!(explorer_visible(shell, explorer_id, cx));
                    })
                    .unwrap();
                // An archived chat's explorer must survive subsequent state updates
                // and keep receiving filesystem changes after being reopened.
                state.update(cx, |_, cx| cx.notify());
                std::fs::write(project.join("archived.txt"), "still accessible\n").unwrap();
                wait_for(window, cx, "archived explorer update", |shell, cx| {
                    explorer_visible(shell, explorer_id, cx)
                        && first_explorer
                            .read(cx)
                            .tree()
                            .node("archived.txt")
                            .is_some()
                })
                .await;
                core.workspace.delete_chat("first").unwrap();
                wait_for(
                    window,
                    cx,
                    "deleted chat target invalidation",
                    |shell, cx| {
                        !shell
                            .state
                            .read(cx)
                            .chats
                            .iter()
                            .any(|chat| chat.id == "first")
                            && !first_explorer.read(cx).is_current_target(cx)
                    },
                )
                .await;
                let before_deleted_event = window
                    .update(cx, |shell, _, _| {
                        // The workspace retains the explorer after its backing
                        // chat disappears; its subscription must reject stale events.
                        assert_eq!(
                            shell.workspace_panels.explorers[&explorer_id].0,
                            first_explorer
                        );
                        shell.file_surface_keys.clone()
                    })
                    .unwrap();
                first_explorer.update(cx, |_, cx| {
                    cx.emit(FilesEvent::OpenFile("archived.txt".into()));
                });
                frame(window, cx, None, "deleted-event").await;
                window
                    .update(cx, |shell, _, _| {
                        assert_eq!(shell.file_surface_keys, before_deleted_event);
                    })
                    .unwrap();
                drop(first_explorer);
                drop(state);
                let handle = gpui::AnyWindowHandle::from(window);
                // Render an input-free frame before closing. X11's retained
                // IME handler otherwise outlives the app's leak detector.
                handle
                    .update(cx, |_, window, cx| {
                        window.replace_root(cx, |_, _| ClosedFixture);
                        window.blur();
                        window.refresh();
                        let _ = window.draw(cx);
                    })
                    .unwrap();
                pause(cx).await;
                handle
                    .update(cx, |_, window, _| window.remove_window())
                    .unwrap();
                pause(cx).await;
                cx.update(|cx| cx.quit());
            })
            .detach();
        });
}
