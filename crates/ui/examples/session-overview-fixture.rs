//! All sessions captures with synthetic projects, plans and an unanswered question.
//! cargo run -p harness-ui --example session-overview-fixture --features appshots-fixture -- OUT_DIR [--dark] [--question] [--reorder]
//! Add the project-palette-fixture feature and --project for the existing New project dialog.
//! --reorder exercises a real pointer drag and captures hover, active drag, and saved order.
use gpui::{AppContext, AsyncApp, Bounds, WindowBounds, WindowOptions, px, size};
use harness_ui::*;
use std::{path::Path, sync::Arc, time::Duration};

const PROJECTS: [(&str, &str, Option<&str>); 6] = [
    ("studio", "Studio", Some("studio-settings")),
    ("orbit", "Orbit", Some("orbit-export")),
    ("beacon", "Beacon", Some("beacon-search")),
    (
        "atlas",
        "Internationalization and accessibility",
        Some("atlas-review"),
    ),
    ("harbor", "Harbor", Some("harbor-preview")),
    ("new-project", "New project", None),
];

const CHATS: [(&str, &str, &str, &str); 6] = [
    (
        "studio-settings",
        "studio",
        "Refine account settings",
        "Checking focus order in the model picker.",
    ),
    (
        "studio-empty",
        "studio",
        "Polish empty states",
        "The empty-state copy is ready for a final review.",
    ),
    (
        "orbit-export",
        "orbit",
        "Fix CSV exports",
        "One choice before I can finish: how should dates be exported?",
    ),
    (
        "beacon-search",
        "beacon",
        "Add search shortcuts",
        "Ready to try. Shortcuts work on Mac and Windows.",
    ),
    (
        "atlas-review",
        "atlas",
        "Review translated settings, keyboard navigation, and screen-reader announcements",
        "The review notes are ready whenever you want to continue.",
    ),
    (
        "harbor-preview",
        "harbor",
        "Check the preview build",
        "Inspecting the build output before opening the preview.",
    ),
];

fn transcript(
    chat: &str,
    message: &str,
    now: chrono::DateTime<chrono::Utc>,
) -> Vec<harness_doc::SessionMessageEntry> {
    let steps: &[(&str, bool)] = match chat {
        "studio-settings" => &[
            ("Inspect the current flow", true),
            ("Update spacing and alignment", true),
            ("Verify keyboard navigation", false),
        ],
        "orbit-export" => &[
            ("Reproduce the export issue", true),
            ("Prepare the fix", true),
            ("Choose the date format", false),
        ],
        "beacon-search" => &[
            ("Wire up the shortcuts", true),
            ("Test focused input fields", true),
            ("Verify both platforms", true),
        ],
        _ => &[],
    };
    let mut parts = Vec::new();
    if !steps.is_empty() {
        parts.push(serde_json::json!({
            "id": "acp-plan", "kind": "tool", "resolved": true,
            "call": {"kind": "todo", "items": steps.iter().map(|(text, done)| {
                serde_json::json!({"text": text, "done": done})
            }).collect::<Vec<_>>()}
        }));
    }
    parts.push(serde_json::json!({"id": "status", "kind": "text", "text": message}));
    if chat == "orbit-export" {
        parts.push(serde_json::json!({
            "id": "export-question", "kind": "input", "requestId": "export-date-format",
            "resolved": false,
            "questions": [{
                "id": "date-format", "header": "Export date format",
                "question": "How should dates be formatted in CSV exports?",
                "options": [
                    "Keep the original formatting from the source file",
                    "ISO date only, using YYYY-MM-DD without a time component",
                    "ISO timestamp in UTC, including the full date and time",
                    "ISO timestamp with the original time-zone offset",
                    "Month / day / year for US spreadsheet imports",
                    "Day / month / year for day-first regional settings",
                    "Unix timestamp in seconds for downstream services",
                    "Unix timestamp in milliseconds for event pipelines",
                    "A written month name with a four-digit year and two-digit day",
                    "The locale selected for the destination workspace, even when source files use different conventions",
                    "Separate columns for the date, local time, and time-zone offset",
                    "Keep the original value and add a second column containing a normalized UTC timestamp for auditing"
                ],
                "multiSelect": false
            }]
        }));
    }
    serde_json::from_value(serde_json::json!([{
        "id": format!("{chat}-assistant"), "role": "assistant", "parts": parts,
        "createdAt": (now - chrono::Duration::minutes(2)).timestamp_millis(),
        "deviceId": "preview-device",
        "status": if ["studio-settings", "orbit-export", "harbor-preview"].contains(&chat) {
            "streaming"
        } else { "complete" }
    }]))
    .expect("valid synthetic transcript")
}

async fn settle(cx: &mut AsyncApp) {
    cx.background_executor()
        .timer(Duration::from_millis(500))
        .await;
}

fn capture(
    handle: gpui::AnyWindowHandle,
    cx: &mut AsyncApp,
    output: &Path,
    name: &str,
) -> anyhow::Result<()> {
    handle.update(cx, |_, window, cx| -> anyhow::Result<()> {
        window.draw(cx).clear();
        window
            .render_to_image()?
            .save(output.join(format!("{name}.png")))?;
        Ok(())
    })?
}

fn pointer_move(
    handle: gpui::AnyWindowHandle,
    cx: &mut AsyncApp,
    position: gpui::Point<gpui::Pixels>,
    pressed: bool,
) -> anyhow::Result<()> {
    handle.update(cx, |_, window, cx| {
        window.dispatch_event(
            gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                position,
                pressed_button: pressed.then_some(gpui::MouseButton::Left),
                modifiers: Default::default(),
            }),
            cx,
        );
    })
}

async fn verify_reorder(
    window: gpui::WindowHandle<shell::Shell>,
    cx: &mut AsyncApp,
    output: &Path,
    appearance: &str,
) -> anyhow::Result<()> {
    window.update(cx, |_, window, _| {
        window.resize(size(px(1440.), px(1000.)));
    })?;
    settle(cx).await;
    let before: Vec<Option<String>> = PROJECTS
        .iter()
        .map(|(id, _, _)| Some((*id).into()))
        .collect();
    anyhow::ensure!(
        window.update(cx, |shell, _, cx| shell.fixture_overview_project_order(cx))? == before,
        "unexpected initial overview order"
    );

    // Hovering the sheet body must leave every grip hidden. Only the
    // separate project heading above a sheet reveals its grip.
    let handle: gpui::AnyWindowHandle = window.into();
    pointer_move(handle, cx, gpui::point(px(466.), px(200.)), false)?;
    settle(cx).await;
    capture(handle, cx, output, &format!("overview-body-hover-{appearance}-1440"))?;
    let start = gpui::point(px(43.), px(71.));
    pointer_move(handle, cx, start, false)?;
    // Let the grip's reveal finish while staying below the tooltip delay.
    cx.background_executor()
        .timer(Duration::from_millis(220))
        .await;
    capture(handle, cx, output, &format!("overview-hover-{appearance}-1440"))?;

    // These coordinates belong to this synthetic 1440px fixture: x32 card
    // gutter, heading y60..82, and a 22px grip to the left of "Studio".
    // GPUI debug-selector bounds are internal, so use the deterministic
    // layout and fail if the real drag does not activate.
    handle.update(cx, |_, window, cx| {
        window.dispatch_event(
            gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                position: start,
                button: gpui::MouseButton::Left,
                click_count: 1,
                ..Default::default()
            }),
            cx,
        );
    })?;
    let destination = gpui::point(px(1180.), px(300.));
    for position in [
        gpui::point(px(56.), px(71.)),
        gpui::point(px(260.), px(155.)),
        gpui::point(px(700.), px(210.)),
        gpui::point(px(1100.), px(250.)),
        destination,
    ] {
        pointer_move(handle, cx, position, true)?;
        cx.background_executor()
            .timer(Duration::from_millis(80))
            .await;
        anyhow::ensure!(
            cx.update(|cx| cx.has_active_drag()),
            "project grip did not start or retain a real GPUI drag"
        );
    }
    capture(handle, cx, output, &format!("overview-drag-{appearance}-1440"))?;
    handle.update(cx, |_, window, cx| {
        window.dispatch_event(
            gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                position: destination,
                button: gpui::MouseButton::Left,
                click_count: 1,
                ..Default::default()
            }),
            cx,
        );
    })?;
    settle(cx).await;
    anyhow::ensure!(
        !cx.update(|cx| cx.has_active_drag()),
        "project drag remained active after the drop"
    );
    let mut expected = before;
    let studio = expected.remove(0);
    expected.insert(2, studio);
    anyhow::ensure!(
        window.update(cx, |shell, _, cx| shell.fixture_overview_project_order(cx))? == expected,
        "dropping Studio on Beacon did not produce Orbit, Beacon, Studio"
    );

    // Reopening exercises saved layout restoration, not just the live order.
    window.update(cx, |shell, window, cx| {
        shell.fixture_session_overview(false, window, cx);
        shell.fixture_session_overview(true, window, cx);
    })?;
    settle(cx).await;
    anyhow::ensure!(
        window.update(cx, |shell, _, cx| shell.fixture_overview_project_order(cx))? == expected,
        "project order did not survive closing and reopening the overview"
    );
    pointer_move(handle, cx, gpui::point(px(1420.), px(70.)), false)?;
    settle(cx).await;
    capture(handle, cx, output, &format!("overview-reordered-{appearance}-1440"))?;

    // In two columns the last row sits below the fold. Holding a drag near
    // the viewport edge must reveal it, even without further mouse movement.
    window.update(cx, |_, window, _| {
        window.resize(size(px(760.), px(1000.)));
    })?;
    settle(cx).await;
    let height = window.update(cx, |_, window, _| f32::from(window.viewport_size().height))?;
    let start = gpui::point(px(43.), px(71.));
    pointer_move(handle, cx, start, false)?;
    cx.background_executor()
        .timer(Duration::from_millis(220))
        .await;
    handle.update(cx, |_, window, cx| {
        window.dispatch_event(
            gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                position: start,
                button: gpui::MouseButton::Left,
                click_count: 1,
                ..Default::default()
            }),
            cx,
        );
    })?;
    for position in [
        gpui::point(px(56.), px(71.)),
        gpui::point(px(650.), px(300.)),
        gpui::point(px(650.), px(height - 10.)),
    ] {
        pointer_move(handle, cx, position, true)?;
        cx.background_executor()
            .timer(Duration::from_millis(80))
            .await;
        anyhow::ensure!(
            cx.update(|cx| cx.has_active_drag()),
            "narrow project drag did not start or remain active"
        );
    }
    cx.background_executor()
        .timer(Duration::from_millis(1200))
        .await;
    anyhow::ensure!(
        cx.update(|cx| cx.has_active_drag()),
        "edge scrolling unexpectedly ended the project drag"
    );
    // After scrolling, this point is inside New project's final-row sheet.
    // At the initial scroll offset it hits an earlier row, including when
    // the requested 1000px height is not clamped by the physical display.
    let destination = gpui::point(px(650.), px(height - 240.));
    pointer_move(handle, cx, destination, true)?;
    settle(cx).await;
    capture(handle, cx, output, &format!("overview-scroll-drag-{appearance}-760"))?;
    handle.update(cx, |_, window, cx| {
        window.dispatch_event(
            gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                position: destination,
                button: gpui::MouseButton::Left,
                click_count: 1,
                ..Default::default()
            }),
            cx,
        );
    })?;
    settle(cx).await;
    anyhow::ensure!(
        !cx.update(|cx| cx.has_active_drag()),
        "narrow project drag remained active after the drop"
    );
    let orbit = expected.remove(0);
    expected.push(orbit);
    anyhow::ensure!(
        window.update(cx, |shell, _, cx| shell.fixture_overview_project_order(cx))? == expected,
        "edge drag failed to reach the last row and move Orbit to the end"
    );
    pointer_move(handle, cx, gpui::point(px(740.), px(70.)), false)?;
    settle(cx).await;
    capture(handle, cx, output, &format!("overview-reordered-{appearance}-760"))?;
    Ok(())
}

fn main() -> anyhow::Result<()> {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let output = std::path::PathBuf::from(arguments.first().expect("output directory"));
    let dark = arguments.iter().any(|argument| argument == "--dark");
    let question = arguments.iter().any(|argument| argument == "--question");
    let project = arguments.iter().any(|argument| argument == "--project");
    let reorder = arguments.iter().any(|argument| argument == "--reorder");
    #[cfg(not(feature = "project-palette-fixture"))]
    if project {
        anyhow::bail!("--project requires the project-palette-fixture feature");
    }
    std::fs::create_dir_all(&output)?;
    tracing_subscriber::fmt().with_env_filter("warn").init();
    let runtime = tokio::runtime::Runtime::new()?;
    let _runtime = runtime.enter();
    let temporary = tempfile::tempdir()?;
    let data = temporary.path().to_path_buf();
    let failure = Arc::new(std::sync::Mutex::new(None));
    let result = failure.clone();

    gpui_platform::application().with_assets(icons::Assets).run(move |cx| {
        gpui_tokio::init(cx);
        gpui_base::init(cx);
        let mut settings = settings::UiSettings::default();
        settings.project_tabs_version = 1;
        settings.chat_tabs = PROJECTS.iter().map(|(id, _, chat)| settings::SavedChatTab {
            project: Some((*id).into()), selected: chat.map(str::to_owned), layout: None,
        }).collect();
        settings.chat_tab = 0;
        settings.last_space_id = Some("studio".into());
        settings.space_filter = Some("studio".into());
        settings.surface = harness_theme::SurfacePreference::Opaque;
        settings::init(settings.clone(), data.clone(), cx);
        let fonts = typography::register_fonts(cx);
        typography::init(
            settings.ui_font_family.clone(), settings.ui_font_size,
            settings.terminal_font_family.clone(), settings.terminal_font_size,
            settings.code_font_family.clone(), settings.code_font_size, fonts, cx,
        );
        theme_library::init(data.clone(), cx);
        appearance::init(
            if dark { appearance::AppearanceMode::Dark } else { appearance::AppearanceMode::Light },
            settings.theme_selection, settings.accent, settings.surface, cx,
        );
        history::init(Default::default(), Default::default(), Default::default(), Default::default(), cx);
        composer::init(cx, settings.composer_send_behavior);
        terminal::panel::init(cx);
        app_menus::init(cx);

        let now = chrono::Utc::now();
        let state = cx.new(|_| {
            let mut state = state::AppState::new();
            state.connection = harness_proto::view::ConnectionStatus::Ready;
            state.workspace_scope = Some(harness_proto::WorkspaceScope::Local);
            state.local_device_id = Some("preview-device".into());
            state.selected_space = Some("studio".into());
            state.auto_selected = true;
            state.chats_synced = true;
            state.spaces_synced = true;
            state.devices = serde_json::from_value(serde_json::json!([{
                "id": "preview-device", "name": "Preview device", "platform": "macos", "lastSeenAt": now
            }])).expect("valid synthetic device");
            state.spaces = PROJECTS.iter().map(|(id, name, _)| {
                serde_json::from_value(serde_json::json!({
                    "id": id, "name": name, "deviceId": "preview-device",
                    "path": format!("/fixtures/{id}"), "createdAt": now - chrono::Duration::days(1)
                })).expect("valid synthetic project")
            }).collect();
            state.chats = CHATS.iter().enumerate().map(|(index, (id, project, title, preview))| {
                serde_json::from_value(serde_json::json!({
                    "id": id, "spaceId": project, "deviceId": "preview-device", "title": title,
                    "archived": false, "createdAt": now - chrono::Duration::hours(index as i64 + 1),
                    "lastMessagePreview": preview, "lastMessageAt": now - chrono::Duration::minutes(2),
                    "lastPromptAt": now - chrono::Duration::minutes(10), "lastSeenAt": now,
                    "config": {"harness": "graff", "model": null, "reasoning": null, "sandbox": "workspace-write"}
                })).expect("valid synthetic chat")
            }).collect();
            state.sessions = [
                ("studio-settings", harness_proto::SessionStatus::Working),
                ("orbit-export", harness_proto::SessionStatus::AwaitingInput),
                ("harbor-preview", harness_proto::SessionStatus::Working),
            ].into_iter().map(|(id, status)| harness_proto::Session {
                chat_id: id.into(), device_id: "preview-device".into(), status,
                started_at: Some(now - chrono::Duration::minutes(5)), updated_at: now,
                last_completed_turn: None,
            }).collect();
            state
        });
        // Warm the same per-chat transcript cache populated during normal navigation.
        state.update(cx, |state, cx| {
            for (id, _, _, preview) in CHATS {
                state.select_chat(Some(id.into()), cx);
                state.apply_transcript(transcript(id, preview, now));
            }
            // An explicit selection at shell creation suppresses saved-project
            // restoration. Park every transcript and let the real boot path
            // restore all six saved tabs, including idle and empty projects.
            state.select_chat(None, cx);
            for chat in &mut state.chats {
                if chat.id == "beacon-search" {
                    chat.last_seen_at = None;
                }
            }
        });

        let boot = EngineBootConfig {
            data_dir: data, ipc_port: 0, edge_url: String::new(), edge_token: None,
            org_id: None, codegraff_client_id: None, default_harness: HarnessId::Graff,
        };
        let window = cx.open_window(WindowOptions {
            window_background: theme::Theme::of(cx).window_background_appearance(),
            window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                gpui::point(px(20.), px(40.)), size(px(1440.), px(1000.)),
            ))),
            titlebar: Some(gpui::TitlebarOptions {
                title: None, appears_transparent: true,
                traffic_light_position: Some(gpui::point(px(14.), px(14.))),
            }),
            app_owns_titlebar_drag: true,
            ..Default::default()
        }, |_, cx| cx.new(|cx| shell::Shell::new(state.clone(), boot, cx))).unwrap();
        state.update(cx, |_, cx| cx.notify());
        cx.spawn(async move |cx| {
            let run: anyhow::Result<()> = async {
                settle(cx).await;
                window.update(cx, |shell, window, cx| shell.fixture_session_overview(true, window, cx))?;
                settle(cx).await;
                let appearance = if dark { "dark" } else { "light" };
                capture(window.into(), cx, &output, &format!("overview-{appearance}-1440"))?;
                window.update(cx, |_, window, _| window.resize(size(px(760.), px(1000.))))?;
                settle(cx).await;
                capture(window.into(), cx, &output, &format!("overview-{appearance}-760"))?;
                if reorder {
                    verify_reorder(window, cx, &output, appearance).await?;
                }
                if question {
                    for (width, height) in [(1440., 1000.), (760., 1000.), (520., 720.)] {
                        window.update(cx, |shell, window, cx| {
                            window.resize(size(px(width), px(height)));
                            shell.fixture_overview_answer("orbit-export", window, cx);
                        })?;
                        settle(cx).await;
                        capture(window.into(), cx, &output, &format!("overview-question-{appearance}-{width:.0}"))?;
                        window.update(cx, |shell, _, cx| {
                            shell.fixture_appshots_composer().update(cx, |composer, cx| {
                                composer.fixture_set_draft(
                                    "Keep the original format and add a second column with the UTC date, so we can compare both values.", cx,
                                );
                            });
                        })?;
                        settle(cx).await;
                        capture(window.into(), cx, &output, &format!("overview-reply-{appearance}-{width:.0}"))?;
                        window.update(cx, |shell, window, cx| {
                            shell.fixture_appshots_composer().update(cx, |composer, cx| {
                                composer.fixture_set_draft("", cx);
                            });
                            shell.fixture_session_overview(false, window, cx);
                            shell.fixture_session_overview(true, window, cx);
                        })?;
                        settle(cx).await;
                    }
                }
                #[cfg(feature = "project-palette-fixture")]
                if project {
                    for width in [1440., 760.] {
                        window.update(cx, |shell, window, cx| {
                            window.resize(size(px(width), px(1000.)));
                            shell.fixture_open_project_setup(cx);
                        })?;
                        settle(cx).await;
                        capture(window.into(), cx, &output, &format!("overview-project-{appearance}-{width:.0}"))?;
                        let handle: gpui::AnyWindowHandle = window.into();
                        handle.update(cx, |_, window, cx| -> anyhow::Result<()> {
                            window.dispatch_event(gpui::PlatformInput::KeyDown(gpui::KeyDownEvent {
                                keystroke: gpui::Keystroke::parse("escape")?,
                                is_held: false,
                                prefer_character_input: false,
                            }), cx);
                            Ok(())
                        })??;
                        settle(cx).await;
                    }
                }
                Ok(())
            }.await;
            if let Err(error) = run { *result.lock().unwrap() = Some(format!("{error:#}")); }
            let _ = window.update(cx, |_, window, _| window.remove_window());
            cx.update(|cx| cx.quit());
        }).detach();
    });
    if let Some(error) = failure.lock().unwrap().take() {
        anyhow::bail!(error);
    }
    Ok(())
}
