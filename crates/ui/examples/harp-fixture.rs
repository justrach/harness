//! Synthetic screenshots of the production shell; no agent runs are dispatched.
//! cargo run -p harness-ui --example harp-fixture --features appshots-fixture -- /tmp/harp-review
//! Append --warm to capture only the refined Warm Harp direction.
//! Append --sidebar to capture sidebar collapse and reopen at both window sizes.
//! Append --archived --warm to review the bottom archive shelf and overflowing lists.
//! Append --panel-axes --warm to verify top/bottom drops and stacked seam stability.
//! Append --panel-composer --warm to capture new conversations in stacked panels.
//! Append --session-hierarchy --warm to review session navigation and tab metadata.
//! Append --codex-import --warm to review synthetic Codex import dialog states.
//! HARNESS_FIXTURE_THEME can select another installed variant for Codex import review.
//! Append --connected-tabs --warm to capture attached tab contours and focus.
//! Append --tab-icons --warm to capture horizontal tab types and browser favicons.
//! Append --terminal --warm with a synthetic SHELL to capture a canvas terminal and repeated closes.
//! Append --session-hierarchy --warm to capture workspace controls.
//! Append --sidebar-hover-motion --warm for compact hover transition samples.
//! Append --panel-edge-drag --warm to capture tab-to-panel edge drops.
//! Set HARNESS_FIXTURE_TONE=light or dark to isolate appearance captures.
//! HARNESS_FIXTURE_CAPTURE can name a native capture helper receiving pid and output path.
//! Append --panel-stability --warm to verify seam drops and overlaid header controls.
//! Append --sidebar-matrix --warm to capture every display combination at three sidebar widths.
//! Append --shared-header --warm for native single-panel/shared-row verification.
//! Append --tab-insertion --warm for stacked-panel tab insertion feedback.
//! Append --chat-history --warm for history entry points and close/reopen recovery.
//! HARNESS_HISTORY_ACTIONS_ONLY=1 limits history review to background row/dialog actions.
//! Append --cloud-hover-review for real hover/retention/dismissal and targeted Settings checks.
//! Append --cloud-interactive for a persistent synthetic cloud preview with no UI engine handle.
//! Append --device-panel-review for multiple-computer, collapsed-anchor and panel-device checks.
//! Append --device-panel-interactive for a persistent three-computer test window.
//! Append --turn-changes-review for review/comment screenshots and draft-close checks.
//! Append --turn-changes-interactive for a persistent synthetic review with no UI engine handle.
#[path = "harp-fixture/device_panels.rs"]
mod device_panels;
#[path = "harp-fixture/chat_history.rs"]
mod chat_history;
#[path = "harp-fixture/shared_header.rs"]
mod shared_header;
#[path = "harp-fixture/tab_insertion.rs"]
mod tab_insertion;
use gpui::{AppContext, AsyncApp, Bounds, WindowBounds, WindowOptions, point, px, size};
use harness_ui::*;
use std::{path::Path, path::PathBuf, sync::Arc, time::Duration};

const SELECTED_CHAT: &str = "launch-0";
const PROJECTS: [(&str, &str, [&str; 3]); 3] = [
    (
        "launch",
        "Launch",
        [
            "Refine the launch page",
            "Compare pricing plans",
            "Polish the signup flow",
        ],
    ),
    (
        "mobile",
        "Mobile app",
        [
            "Simplify onboarding",
            "Review offline states",
            "Improve navigation",
        ],
    ),
    (
        "backend",
        "Backend",
        [
            "Add request caching",
            "Review API responses",
            "Update service docs",
        ],
    ),
];

#[derive(Clone, Copy)]
struct Candidate {
    key: &'static str,
    palette: &'static str,
    framed: bool,
    width: f32,
    show_branch: bool,
    font_size: f32,
}

const CANDIDATES: [Candidate; 5] = [
    Candidate {
        key: "a",
        palette: "harp",
        framed: true,
        width: 272.,
        show_branch: false,
        font_size: 16.,
    },
    Candidate {
        key: "b",
        palette: "warm-harp",
        framed: true,
        width: 272.,
        show_branch: false,
        font_size: 16.,
    },
    Candidate {
        key: "c",
        palette: "harp",
        framed: false,
        width: 272.,
        show_branch: false,
        font_size: 16.,
    },
    Candidate {
        key: "d",
        palette: "harp",
        framed: true,
        width: 240.,
        show_branch: false,
        font_size: 15.,
    },
    Candidate {
        key: "e",
        palette: "harp",
        framed: true,
        width: 320.,
        show_branch: true,
        font_size: 18.,
    },
];

/// Preview-only composition: no extra theme families or design preferences are saved.
fn candidate_surface(candidate: Candidate, cx: &mut gpui::App) {
    let current = theme::Theme::of(cx).clone();
    theme::Theme::reinstall_selection(
        current.appearance,
        current.variant_id.as_ref(),
        current.accent_selection,
        current.surface_preference,
        cx,
    );
    if candidate.palette == "warm-harp" {
        cx.refresh_windows();
        return;
    }
    let theme = cx.global_mut::<theme::Theme>();
    theme.family_id = if candidate.framed {
        "harp"
    } else {
        "fixture-flat"
    }
    .into();
    cx.refresh_windows();
}

fn workspace_fixture_theme(cx: &mut gpui::App) {
    let Ok(variant) = std::env::var("HARNESS_FIXTURE_THEME") else {
        return;
    };
    let current = theme::Theme::of(cx).clone();
    theme::Theme::reinstall_selection(
        current.appearance,
        &variant,
        current.accent_selection,
        current.surface_preference,
        cx,
    );
}

async fn pause(cx: &mut AsyncApp, ms: u64) {
    cx.background_executor()
        .timer(Duration::from_millis(ms))
        .await;
}

fn capture(
    window: gpui::AnyWindowHandle,
    cx: &mut AsyncApp,
    output: &Path,
    name: &str,
) -> anyhow::Result<()> {
    let path = output.join(format!("{name}.png"));
    window.update(cx, |_, window, cx| -> anyhow::Result<()> {
        window.draw(cx).clear();
        window.render_to_image()?.save(&path)?;
        Ok(())
    })??;
    if let Some(helper) = std::env::var_os("HARNESS_FIXTURE_CAPTURE") {
        let status = std::process::Command::new(helper)
            .arg(std::process::id().to_string())
            .arg(&path)
            .status()?;
        anyhow::ensure!(status.success(), "native capture helper failed");
    }
    Ok(())
}

fn port() -> anyhow::Result<u16> {
    Ok(std::net::TcpListener::bind("127.0.0.1:0")?
        .local_addr()?
        .port())
}

fn cloud_pointer_move(
    window: gpui::WindowHandle<shell::Shell>,
    position: gpui::Point<gpui::Pixels>,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let native: gpui::AnyWindowHandle = window.into();
    native.update(cx, |_, window, cx| {
        window.dispatch_event(
            gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                position,
                pressed_button: None,
                modifiers: Default::default(),
            }),
            cx,
        );
    })?;
    Ok(())
}

fn cloud_pointer_click(
    window: gpui::WindowHandle<shell::Shell>,
    position: gpui::Point<gpui::Pixels>,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let native: gpui::AnyWindowHandle = window.into();
    native.update(cx, |_, window, cx| {
        window.dispatch_event(
            gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                position,
                button: gpui::MouseButton::Left,
                click_count: 1,
                ..Default::default()
            }),
            cx,
        );
        window.dispatch_event(
            gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                position,
                button: gpui::MouseButton::Left,
                click_count: 1,
                ..Default::default()
            }),
            cx,
        );
    })?;
    Ok(())
}

async fn review_cloud_hover(
    window: gpui::WindowHandle<shell::Shell>,
    cx: &mut AsyncApp,
    output: &Path,
    tone: &str,
) -> anyhow::Result<()> {
    for (width, height) in [(1440., 900.), (980., 700.)] {
        window.update(cx, |shell, window, cx| {
            window.resize(size(px(width), px(height)));
            // The shared cloud base expects two existing workspace panels.
            // Rebuild its synthetic session here, also returning from Settings
            // before the next window-size pass.
            shell.fixture_session_hierarchy(0, window, cx);
            shell.fixture_cloud_refinement("card", window, cx);
        })?;
        cloud_pointer_move(window, point(px(width - 20.), px(height / 2.)), cx)?;
        pause(cx, 450).await;
        capture(window.into(), cx, output, &format!("cloud-card-{tone}-{width}"))?;
        let card = window.update(cx, |shell, window, cx| {
            shell.fixture_cloud_card_center(window, cx)
        })?;
        cloud_pointer_move(window, card, cx)?;
        pause(cx, 500).await;
        anyhow::ensure!(
            window.update(cx, |shell, _, _| shell.fixture_cloud_detail_is_open())?,
            "hover must reveal the cloud popover"
        );
        capture(window.into(), cx, output, &format!("cloud-hover-{tone}-{width}"))?;
        let detail = window.update(cx, |shell, window, cx| {
            shell.fixture_cloud_detail_center(window, cx)
        })?;
        cloud_pointer_move(window, detail, cx)?;
        pause(cx, 600).await;
        anyhow::ensure!(
            window.update(cx, |shell, _, _| shell.fixture_cloud_detail_is_open())?,
            "moving from the card into its popover must keep it open"
        );
        capture(window.into(), cx, output, &format!("cloud-hover-retained-{tone}-{width}"))?;
        cloud_pointer_move(window, point(px(width - 20.), px(height / 2.)), cx)?;
        pause(cx, 600).await;
        anyhow::ensure!(
            !window.update(cx, |shell, _, _| shell.fixture_cloud_detail_is_open())?,
            "leaving both card and popover must dismiss the hover preview"
        );
        cloud_pointer_move(window, card, cx)?;
        pause(cx, 500).await;
        cloud_pointer_click(window, card, cx)?;
        pause(cx, 600).await;
        anyhow::ensure!(
            window.update(cx, |shell, _, cx| shell.fixture_cloud_settings_selected(cx))?
                .as_deref()
                == Some("fixture-studio"),
            "clicking the cloud card must open Settings for that exact computer"
        );
        anyhow::ensure!(
            !window.update(cx, |shell, _, _| shell.fixture_cloud_detail_is_open())?,
            "navigating to Settings must close the cloud hover preview"
        );
        capture(window.into(), cx, output, &format!("cloud-settings-{tone}-{width}"))?;
    }
    Ok(())
}

fn transcript(device: &str) -> anyhow::Result<harness_doc::TranscriptFrame> {
    Ok(harness_doc::TranscriptFrame::Reset {
        reset: serde_json::from_value(serde_json::json!([
            {
                "id": "design-request",
                "role": "user",
                "parts": [{"id": "text", "kind": "text", "text": "Give the launch page a calmer layout. Keep the content easy to scan and make the next step clear."}],
                "createdAt": 1792620000000_i64,
                "deviceId": device
            },
            {
                "id": "design-response",
                "role": "assistant",
                "parts": [{"id": "text", "kind": "text", "text": "### A calmer launch page\n\nThe layout now gives the message more room and keeps the main action close to the introduction.\n\n- **Clear hierarchy:** one heading, a short introduction, and a focused action.\n- **Quieter surfaces:** soft neutrals with a little contrast around the controls.\n- **Consistent spacing:** related content stays together at every window size.\n\n```css\n.launch-page {\n  max-width: 72rem;\n  padding: 2rem;\n}\n```\n\nThe page is ready for a visual review."}],
                "createdAt": 1792620001000_i64,
                "deviceId": device,
                "status": "complete"
            }
        ]))?,
    })
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter("warn").init();
    let output = PathBuf::from(
        std::env::args()
            .nth(1)
            .ok_or_else(|| anyhow::anyhow!("usage: harp-fixture <output-directory>"))?,
    );
    std::fs::create_dir_all(&output)?;
    let device_panel_interactive = std::env::args().any(|arg| arg == "--device-panel-interactive");
    let device_panel_review = std::env::args().any(|arg| arg == "--device-panel-review");
    let device_panel_preview = device_panel_interactive || device_panel_review;
    let cloud_interactive = device_panel_interactive || std::env::args().any(|arg| arg == "--cloud-interactive");
    let cloud_hover_review = std::env::args().any(|arg| arg == "--cloud-hover-review");
    let cloud_preview = cloud_interactive || cloud_hover_review || device_panel_preview;
    anyhow::ensure!(!cloud_preview || cfg!(target_os = "macos"), "cloud preview is Mac only");
    let turn_changes_interactive = std::env::args().any(|arg| arg == "--turn-changes-interactive");
    let warm_only =
        cloud_preview || turn_changes_interactive || std::env::args().any(|arg| arg == "--warm");
    let nested_review = std::env::args().any(|arg| arg == "--nested");
    let hover_review = std::env::args().any(|arg| arg == "--hover");
    let tabs_review = std::env::args().any(|arg| arg == "--tabs");
    let sidebar_review = std::env::args().any(|arg| arg == "--sidebar");
    let panel_placement = std::env::args().any(|arg| arg == "--panel-placement");
    let panel_controls = std::env::args().any(|arg| arg == "--panel-controls");
    let tab_density = std::env::args().any(|arg| arg == "--tab-density");
    let panel_edge_drag = std::env::args().any(|arg| arg == "--panel-edge-drag");
    let panel_axes = std::env::args().any(|arg| arg == "--panel-axes");
    let panel_composer = std::env::args().any(|arg| arg == "--panel-composer");
    let files_review = std::env::args().any(|arg| arg == "--files-review");
    let resume_import = std::env::args().any(|arg| matches!(arg.as_str(), "--resume-import" | "--codex-import"));
    let turn_changes_review =
        turn_changes_interactive || std::env::args().any(|arg| arg == "--turn-changes-review");
    let reconciliation_design = std::env::args().any(|arg| arg == "--reconciliation-design");
    let follow_up_refinements = std::env::args().any(|arg| arg == "--follow-up-refinements");
    let session_emoji = std::env::args().any(|arg| arg == "--session-emoji");
    let session_hierarchy =
        cloud_preview || turn_changes_review || reconciliation_design || follow_up_refinements || session_emoji || std::env::args().any(|arg| arg == "--session-hierarchy");
    let shared_header = std::env::args().any(|arg| arg == "--shared-header");
    let tab_insertion = std::env::args().any(|arg| arg == "--tab-insertion");
    let chat_history = std::env::args().any(|arg| arg == "--chat-history");
    let history_actions_only = chat_history && chat_history::actions_only();
    if std::env::args().any(|arg| {
        matches!(
            arg.as_str(),
            "--project-sections" | "--sidebar-create" | "--sections"
        )
    }) {
        anyhow::bail!(
            "This integration preview excludes historical sidebar-group scenarios. Use --session-hierarchy or --chat-history."
        );
    }
    let codex_import = false;
    let connected_tabs = std::env::args().any(|arg| arg == "--connected-tabs");
    let tab_icons = std::env::args().any(|arg| arg == "--tab-icons");
    let panel_stability = std::env::args().any(|arg| arg == "--panel-stability");
    let terminal_review = std::env::args().any(|arg| arg == "--terminal");
    let panel_review = terminal_review
        || panel_axes
        || tab_icons
        || connected_tabs
        || session_hierarchy
        || files_review
        || resume_import
        || shared_header
        || tab_insertion
        || chat_history
        || codex_import
        || panel_composer
        || panel_stability
        || panel_placement
        || tab_density
        || panel_edge_drag
        || panel_controls
        || std::env::args().any(|arg| arg == "--panels");
    let sidebar_matrix = std::env::args().any(|arg| arg == "--sidebar-matrix");
    let project_sections = false;
    let sidebar_create = false;
    let sidebar_hover_motion = std::env::args().any(|arg| arg == "--sidebar-hover-motion");
    let sections_review = sidebar_create || project_sections;
    let simple_sidebar = sections_review
        || sidebar_matrix
        || sidebar_hover_motion
        || std::env::args().any(|arg| arg == "--simple-sidebar");
    let archived_review = std::env::args().any(|arg| arg == "--archived");
    let temp = tempfile::tempdir()?;
    let runtime = tokio::runtime::Runtime::new()?;
    let core = runtime.block_on(async {
        harness_engine::EngineCore::assemble(
            &temp.path().join("engine"),
            Arc::new(harness_engine::default_registry()),
            harness_proto::HarnessId::Graff,
            None,
        )
    })?;
    let config: harness_proto::ChatConfig = serde_json::from_value(serde_json::json!({
        "harness": "graff", "model": "gpt-6-sol", "reasoning": "high",
        "modelOptions": {}, "sandbox": "workspace-write"
    }))?;
    for (project, label, titles) in PROJECTS {
        // These paths are invented display data, not a user's checkout.
        let path = if panel_review {
            let root = temp.path().join(project);
            std::fs::create_dir_all(root.join("src"))?;
            std::fs::write(
                root.join("README.md"),
                "# Launch\n\nA synthetic project for panel layout review.\n",
            )?;
            std::fs::write(root.join("src/app.ts"), "export const title = 'Launch';\n")?;
            std::fs::write(root.join("src/styles.css"), "body { margin: 0; }\n")?;
            root.to_string_lossy().into_owned()
        } else {
            format!("/projects/{project}")
        };
        core.workspace
            .create_space(project, &core.device_id, &path, Some(label.into()), false)?;
        for (index, title) in titles.into_iter().enumerate() {
            let id = format!("{project}-{index}");
            let mut chat_config = config.clone();
            if simple_sidebar {
                let (agent, model) = match index {
                    1 => (harness_proto::HarnessId::Codex, "gpt-5.4"),
                    2 => (harness_proto::HarnessId::ClaudeCode, "claude-sonnet-4-6"),
                    _ => (harness_proto::HarnessId::Graff, "gpt-6-sol"),
                };
                chat_config.harness = agent;
                chat_config.model = Some(model.into());
            }
            core.workspace.create_chat(
                &id,
                Some(if simple_sidebar && !project_sections {
                    "launch"
                } else {
                    project
                }),
                Some(&core.device_id),
                Some(chat_config),
                Some(path.clone()),
            )?;
            core.workspace.rename_chat(&id, title)?;
            if tabs_review || panel_review || project_sections {
                // Seed the engine docs, not only the currently selected view,
                // so peer panes and tab switches keep their sample messages.
                let (prompt, reply) = match id.as_str() {
                    "launch-0" => (
                        "Refine the launch page spacing without losing any of the product details.",
                        "### Launch page refinements\n\nI adjusted the spacing between the headline, introduction, and signup form. All pricing and feature details remain visible.\n\n- Keep the main heading on two lines.\n- Align the signup form with the content column.\n- Use the lighter surface for the selected option.\n\nThe layout is ready to review in both appearances.",
                    ),
                    "launch-1" => (
                        "Compare the pricing plans and call out what we need to decide.",
                        "### Pricing comparison\n\nThe Starter plan covers individual work. Team adds shared projects and centralized billing.\n\n**Decision needed:** should shared projects be included in the trial?\n\nOnce that is decided, I can update the plan descriptions and comparison table.",
                    ),
                    "mobile-0" => (
                        "Simplify the onboarding flow while keeping every required step.",
                        "### Onboarding flow\n\nThe revised sequence keeps account setup, project selection, and permissions. Related fields now sit together, with a clear next action on each screen.",
                    ),
                    _ => (
                        "Review the current implementation and summarize the next change.",
                        "### Review notes\n\nThe current behavior is preserved. I am checking the empty state, loading feedback, and keyboard navigation before preparing the next change.",
                    ),
                };
                runtime.block_on(async {
                    let handle = core.doc_host.open_local(&id)?;
                    for (index, (role, text)) in [("user", prompt), ("assistant", reply)]
                        .into_iter()
                        .enumerate()
                    {
                        let entry: harness_doc::SessionMessageEntry =
                            serde_json::from_value(serde_json::json!({
                                "id": format!("sample-{id}-{index}"), "role": role,
                                "parts": [{"id":"text", "kind":"text", "text":text}],
                                "createdAt": 1792620000000_i64 + index as i64,
                                "deviceId": core.device_id, "status":"complete"
                            }))?;
                        handle.doc().push_message(&entry)?;
                    }
                    anyhow::Ok(())
                })?;
            }
        }
    }
    if chat_history {
        core.workspace.set_chat_archived("mobile-0", true)?;
    }

    let sidebar_preferences = core.workspace.sidebar_preferences_snapshot();
    let ipc_port = port()?;
    let _ipc = runtime.block_on(harness_engine::serve_ipc(ipc_port, core.rpc_service()))?;
    let data = temp.path().join("ui");
    std::fs::create_dir(&data)?;
    if simple_sidebar {
        let mut defaults = settings::composer::ComposerDefaults::default();
        defaults.remember_labels(
            [
                ("gpt-6-sol", "GPT-6-Sol"),
                ("gpt-5.4", "GPT-5.4"),
                ("claude-sonnet-4-6", "Claude Sonnet 4.6"),
            ]
            .into_iter(),
        );
        defaults.save(&data)?;
    }
    let boot = EngineBootConfig {
        data_dir: data.clone(),
        ipc_port,
        edge_url: String::new(),
        edge_token: None,
        org_id: None,
        codegraff_client_id: None,
        default_harness: harness_proto::HarnessId::Graff,
    };
    let engine = runtime.block_on(state::EngineHandle::bootstrap(boot.clone()))?;
    let mut chats = core.workspace.read_chats()?;
    let spaces = core.workspace.read_spaces()?;
    let device = core.device_id.clone();
    let now = chrono::Utc::now();
    let mut sessions = Vec::new();
    for (project_index, (project, _, titles)) in PROJECTS.into_iter().enumerate() {
        for index in 0..titles.len() {
            let id = format!("{project}-{index}");
            let chat = chats
                .iter_mut()
                .find(|chat| chat.id == id)
                .expect("seeded chat");
            let minutes = (project_index * 12 + index * 4 + 1) as i64;
            let timestamp = now - chrono::Duration::minutes(minutes);
            chat.created_at = timestamp;
            chat.last_prompt_at = Some(timestamp);
            chat.last_message_at = Some(timestamp);
            chat.last_seen_at = (index != 2
                && !(simple_sidebar && project_index == 2 && index == 1))
                .then_some(now);
            chat.branch = Some(format!(
                "feature/{}",
                titles[index].to_lowercase().replace(' ', "-")
            ));
            if simple_sidebar {
                chat.source_context = Some(serde_json::from_value(serde_json::json!({
                    "checkoutId": "fixture-checkout", "repoRoot": "/fixtures/project",
                    "cwd": chat.cwd.as_deref().unwrap_or("/fixtures/project"),
                    "branch": if sidebar_matrix {
                        format!("feature/{}-with-a-long-branch-name", titles[index].to_lowercase().replace(' ', "-"))
                    } else {
                        chat.branch.clone().unwrap()
                    },
                    "observedAt": now,
                }))?);
            }
            if index == 1 {
                sessions.push(harness_proto::Session {
                    last_completed_peer_only: false,
                    chat_id: id,
                    device_id: device.clone(),
                    status: if simple_sidebar && project_index == 2 {
                        harness_proto::SessionStatus::Errored
                    } else if project_index == 1 {
                        harness_proto::SessionStatus::Working
                    } else {
                        harness_proto::SessionStatus::AwaitingInput
                    },
                    started_at: Some(timestamp),
                    updated_at: now,
                    last_completed_turn: None,
                });
            }
        }
    }
    let failure = Arc::new(std::sync::Mutex::new(None));
    let result = failure.clone();
    gpui_platform::application()
        .with_assets(icons::Assets)
        .run(move |cx| {
            gpui_tokio::init(cx);
            gpui_base::init(cx);
            let mut settings = settings::UiSettings::default();
            settings.sidebar_organization = settings::SidebarOrganization::ByProject;
            settings.sidebar_width = 272.;
            settings.sidebar_show_branch = false;
            settings.sidebar_show_project_label = false;

            settings.ui_font_family = typography::UiFontFamily::System;
            settings::init(settings.clone(), data.clone(), cx);
            let fonts = typography::register_fonts(cx);
            typography::init(
                settings.ui_font_family.clone(),
                settings.ui_font_size,
                settings.terminal_font_family.clone(),
                settings.terminal_font_size,
                settings.code_font_family.clone(),
                settings.code_font_size,
                fonts,
                cx,
            );
            theme_library::init(data.clone(), cx);
            appearance::init(
                appearance::AppearanceMode::Light,
                settings.theme_selection,
                settings.accent,
                settings.surface,
                cx,
            );
            history::init(
                settings.git_history_columns,
                settings.git_history_column_widths,
                settings.git_history_column_order,
                settings.git_history_author_display,
                cx,
            );
            composer::init(cx, settings.composer_send_behavior);
            terminal::panel::init(cx);
            app_menus::init(cx);
            let state = cx.new(|_| {
                let mut state = state::AppState::new();
                if simple_sidebar {
                    state.data_dir = Some(data.clone());
                }
                // Interactive previews never receive a UI engine handle:
                // the composer cannot issue model requests, and Settings cannot
                // issue cloud requests. Changes are seeded only in memory.
                if !cloud_preview && !turn_changes_interactive {
                    state.fixture_attachment_engine(engine);
                }
                state.connection = harness_proto::view::ConnectionStatus::Ready;
                state.workspace_scope = Some(if sections_review {
                    harness_proto::WorkspaceScope::Local
                } else {
                    harness_proto::WorkspaceScope::Development
                });
                state.local_device_id = Some(device.clone());
                state.devices = vec![harness_proto::Device {
                    id: device.clone(),
                    name: "This device".into(),
                    platform: std::env::consts::OS.into(),
                    last_seen_at: None,
                    created_at: None,
                    version: None,
                    cursor_sdk_version: None,
                    capabilities: Vec::new(),
                }];
                state.spaces = spaces;
                state.chats = chats;
                state.sessions = sessions;
                state.sidebar_preferences = sidebar_preferences;
                if simple_sidebar && !project_sections {
                    let queued = state.chats.iter_mut().find(|chat| chat.id == "backend-0").unwrap();
                    queued.device_id = "fixture-remote".into();
                    state.connectivity.state = harness_proto::ConnectivityState::Offline;
                    state.begin_pending_send("backend-0", "fixture-send", chrono::Utc::now());
                }
                state.selected_chat = Some(SELECTED_CHAT.into());
                state.selected_space = Some("launch".into());
                state.auto_selected = true;
                state.chats_synced = true;
                state.spaces_synced = true;
                state
            });
            cx.spawn(async move |cx| {
                let mut active_window: Option<gpui::AnyWindowHandle> = None;
                let run: anyhow::Result<()> = async {
                    for candidate in CANDIDATES
                        .into_iter()
                        .filter(|candidate| !warm_only || candidate.key == "b")
                    {
                        for (tone, appearance, mode) in [
                            (
                                "light",
                                theme::Appearance::Light,
                                appearance::AppearanceMode::Light,
                            ),
                            (
                                "dark",
                                theme::Appearance::Dark,
                                appearance::AppearanceMode::Dark,
                            ),
                        ]
                        .into_iter()
                        .filter(|(tone, _, _)| {
                            std::env::var("HARNESS_FIXTURE_TONE")
                                .map_or(!(cloud_interactive || turn_changes_interactive) || *tone == "light", |requested| requested == *tone)
                        }) {
                            let font_size = typography::UiFontSize::ALL
                                .into_iter()
                                .find(|size| size.pixels() == candidate.font_size)
                                .expect("candidate uses a supported UI size");
                            let window = cx.update(|cx| {
                                settings::update(settings::SavePolicy::Immediate, cx, |settings| {
                                    settings.sidebar_width = candidate.width;
                                    settings.sidebar_show_branch = simple_sidebar || candidate.show_branch;
                                    if simple_sidebar {
                                        settings.reset_sidebar_display();
                                    }
                                    settings.sidebar_show_project_label = false;
                                    settings.sidebar_collapsed = false;
                                    settings.sidebar_organization =
                                        settings::SidebarOrganization::ByProject;
                                    settings.ui_font_family = typography::UiFontFamily::System;
                                    settings.ui_font_size = font_size;
                                    if tabs_review || panel_review {
                                        settings.last_chat_id = Some(SELECTED_CHAT.into());
                                        settings.chat_tabs.clear();
                                        settings.chat_tab = 0;
                                        settings.chat_layout = None;
                                        settings.space_filter = None;
                                    }
                                });
                                if tabs_review || panel_review {
                                    state.update(cx, |state, cx| {
                                        state.select_chat(Some(SELECTED_CHAT.into()), cx)
                                    });
                                }
                                appearance::set_theme(
                                    appearance,
                                    format!("{}-{tone}", candidate.palette),
                                    cx,
                                );
                                appearance::set_mode(mode, cx);
                                workspace_fixture_theme(cx);
                                appearance::set_surface(
                                    if candidate.framed {
                                        harness_theme::SurfacePreference::Frosted
                                    } else {
                                        harness_theme::SurfacePreference::Opaque
                                    },
                                    cx,
                                );
                                cx.open_window(
                                    WindowOptions {
                                        focus: !history_actions_only && !resume_import && !files_review && !reconciliation_design && !follow_up_refinements && !turn_changes_review && !cloud_hover_review && !device_panel_review,
                                        window_background: theme::Theme::of(cx)
                                            .window_background_appearance(),
                                        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                                            point(px(20.), px(40.)),
                                            size(px(1200.), px(760.)),
                                        ))),
                                        titlebar: Some(gpui::TitlebarOptions {
                                            title: Some(if turn_changes_interactive { "Harness — Changes preview (synthetic)" } else if device_panel_preview { "Harness — Devices preview (synthetic)" } else if cloud_preview { "Harness — Cloud preview (synthetic)" } else { "Harness — synthetic design review" }.into()),
                                            appears_transparent: true,
                                            traffic_light_position: Some(point(px(14.), px(14.))),
                                        }),
                                        app_owns_titlebar_drag: true,
                                        ..Default::default()
                                    },
                                    |_, cx| {
                                        cx.new(|cx| {
                                            shell::Shell::new(state.clone(), boot.clone(), cx)
                                        })
                                    },
                                )
                            })?;
                            active_window = Some(window.into());
                            window.update(cx, |_, window, cx| {
                                typography::set_font_size(font_size, window, cx);
                                window.set_rem_size(px(font_size.pixels()));
                                candidate_surface(candidate, cx);

                                if !history_actions_only && !files_review && !reconciliation_design && !follow_up_refinements && !turn_changes_review && !cloud_hover_review && !device_panel_review { cx.activate(true); }
                            })?;
                            pause(cx, 500).await;
                            let frame = transcript(&device)?;
                            state.update(cx, |state, cx| {
                                state.receive_transcript_frame(frame, cx)?;
                                state.context_usage = Some(harness_proto::ContextUsage {
                                    tokens: Some(12_000),
                                    window: Some(200_000),
                                    savings: None,
                                });
                                cx.notify();
                                anyhow::Ok(())
                            })?;
                            window.update(cx, |shell, _, cx| {
                                shell.fixture_onboarding_starter("tour", cx);
                                candidate_surface(candidate, cx);

                                shell.fixture_appshots_transcript_start(cx);
                            })?;
                            pause(cx, 700).await;
                            if cloud_preview {
                                state.update(cx, |state, _| {
                                    assert!(state.engine().is_none(), "synthetic cloud UI must have no engine handle");
                                });
                                if device_panel_preview {
                                    if device_panel_interactive {
                                        device_panels::interactive(window, state.clone(), cx, &output, tone).await?;
                                        active_window = None;
                                        return Ok(());
                                    }
                                    device_panels::review(window, &device, cx, &output, tone).await?;
                                    window.update(cx, |_, window, _| window.remove_window())?;
                                    active_window = None;
                                    continue;
                                }
                                if cloud_interactive {
                                    window.update(cx, |shell, window, cx| {
                                        window.resize(size(px(1200.), px(800.)));
                                        shell.fixture_session_hierarchy(0, window, cx);
                                        shell.fixture_cloud_refinement("card", window, cx);
                                        window.activate_window();
                                        cx.activate(true);
                                    })?;
                                    pause(cx, 500).await;
                                    capture(window.into(), cx, &output, &format!("cloud-interactive-{tone}"))?;
                                    // Hold until the user closes this temporary native window;
                                    // unlike a timed capture, it remains available for testing.
                                    let mut heartbeat_tick = 0_u32;
                                    loop {
                                        pause(cx, 250).await;
                                        if window.update(cx, |_, _, _| ()).is_err() {
                                            active_window = None;
                                            break;
                                        }
                                        heartbeat_tick += 1;
                                        if heartbeat_tick % 20 == 0 {
                                            state.update(cx, |state, _| {
                                                let running = state.cloud_sandboxes().is_some_and(|list| {
                                                    list.sandboxes.iter().any(|sandbox| {
                                                        sandbox.id == "fixture-studio"
                                                            && sandbox.state == "running"
                                                    })
                                                });
                                                if let Some(device) = state.devices.iter_mut().find(|device| device.id == "cloud-fixture-studio") {
                                                    device.last_seen_at = running.then(chrono::Utc::now);
                                                }
                                            });
                                        }
                                    }
                                    return Ok(());
                                }
                                review_cloud_hover(window, cx, &output, tone).await?;
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }
                            if terminal_review {
                                window.update(cx, |shell, window, cx| {
                                    window.activate_window();
                                    shell.fixture_chat_tab(None, window, cx);
                                })?;
                                window.update(cx, |_, window, cx| {
                                    window.dispatch_action(
                                        Box::new(terminal::panel::ToggleTerminal),
                                        cx,
                                    );
                                })?;
                                for (width, height) in [(1200., 760.), (980., 700.)] {
                                    window.update(cx, |_, window, _| {
                                        window.resize(size(px(width), px(height)));
                                    })?;
                                    pause(cx, 1000).await;
                                    capture(
                                        window.into(),
                                        cx,
                                        &output,
                                        &format!("terminal-{tone}-{width}"),
                                    )?;
                                }
                                for _ in 0..8 {
                                    cx.update(|cx| cx.dispatch_action(&app_menus::CloseTab));
                                    pause(cx, 80).await;
                                }
                                for (width, height) in [(1200., 760.), (980., 700.)] {
                                    window.update(cx, |_, window, _| {
                                        window.resize(size(px(width), px(height)));
                                    })?;
                                    pause(cx, 200).await;
                                    capture(
                                        window.into(),
                                        cx,
                                        &output,
                                        &format!("terminal-{tone}-{width}-closed"),
                                    )?;
                                }
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }
                            if archived_review {
                                for (width, height) in [(1200., 760.), (980., 700.)] {
                                    window.update(cx, |_, window, _| {
                                        window.resize(size(px(width), px(height)))
                                    })?;
                                    for (name, active, archived, open) in [
                                        ("collapsed", 1, 2, false),
                                        ("expanded", 1, 2, true),
                                        ("empty", 0, 2, false),
                                        ("active-overflow", 35, 2, false),
                                        ("archive-overflow", 1, 40, true),
                                    ] {
                                        window.update(cx, |shell, _, cx| {
                                            shell.fixture_archived_sidebar(
                                                active, archived, open, cx,
                                            );
                                        })?;
                                        pause(cx, 350).await;
                                        capture(
                                            window.into(),
                                            cx,
                                            &output,
                                            &format!("archived-{tone}-{width}-{name}"),
                                        )?;
                                        if name.ends_with("overflow") {
                                            window.update(cx, |shell, _, cx| {
                                                shell.fixture_sidebar_scroll_bottom(cx)
                                            })?;
                                            pause(cx, 150).await;
                                            capture(
                                                window.into(),
                                                cx,
                                                &output,
                                                &format!("archived-{tone}-{width}-{name}-bottom"),
                                            )?;
                                        }
                                    }
                                }
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }
                            if chat_history {
                                window.update(cx, |_, window, cx| {
                                    workspace_fixture_theme(cx);
                                    window.set_background_appearance(theme::Theme::of(cx).window_background_appearance());
                                })?;
                                chat_history::exercise(window, tone, &output, cx).await?;
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }
                            if tab_insertion {
                                window.update(cx, |_, window, cx| {
                                    workspace_fixture_theme(cx);
                                    window.set_background_appearance(theme::Theme::of(cx).window_background_appearance());
                                })?;
                                tab_insertion::exercise(window, tone, &output, cx).await?;
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }
                            if shared_header {
                                window.update(cx, |_, window, cx| {
                                    workspace_fixture_theme(cx);
                                    window.set_background_appearance(theme::Theme::of(cx).window_background_appearance());
                                })?;
                                shared_header::exercise(window, tone, &output, cx).await?;
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }

                            if files_review {
                                for (width, height) in [(1200., 760.), (700., 700.)] {
                                    window.update(cx, |_, window, _| window.resize(size(px(width), px(height))))?;
                                    for phase in ["empty", "tree", "search"] {
                                        window.update(cx, |shell, window, cx| shell.fixture_files_review(phase, window, cx))?;
                                        pause(cx, 500).await;
                                        capture(window.into(), cx, &output, &format!("files-{phase}-{tone}-{width}"))?;
                                    }
                                }
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }

                            if resume_import {
                                window.update(cx, |shell, window, cx| shell.fixture_session_hierarchy(0, window, cx))?;
                                for (width, height) in [(1200., 760.), (980., 700.)] {
                                    window.update(cx, |_, window, _| window.resize(size(px(width), px(height))))?;
                                    for (name, query) in [("resume", ""), ("resume-empty", "no matching conversation")] {
                                        window.update(cx, |shell, window, cx| shell.fixture_resume_conversation(query, window, cx))?;
                                        pause(cx, 500).await;
                                        capture(window.into(), cx, &output, &format!("{name}-{tone}-{width}"))?;
                                    }
                                    for phase in ["blank", "entry", "preview", "missing"] {
                                        window.update(cx, |shell, window, cx| shell.fixture_codex_import(phase, window, cx))?;
                                        pause(cx, 500).await;
                                        capture(window.into(), cx, &output, &format!("codex-import-{phase}-{tone}-{width}"))?;
                                    }
                                }
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }

                            if session_hierarchy {
                                window.update(cx, |shell, window, cx| {
                                    shell.fixture_session_hierarchy(0, window, cx);
                                })?;
                                if turn_changes_review {
                                    for (width, height) in [(1440., 900.), (980., 700.)] {
                                        window.update(cx, |_, window, _| window.resize(size(px(width), px(height))))?;
                                        for (phase, name) in [(0,"review-chat"), (1,"review-tab"), (4,"review-comment-draft"), (6,"review-comment-done-guard"), (7,"review-comment-close-guard"), (5,"review-comment-staged"), (2,"review-discard"), (3,"review-done")] {
                                            window.update(cx, |shell, window, cx| shell.fixture_turn_changes_review(phase, window, cx))?;
                                            pause(cx, 600).await;
                                            capture(window.into(), cx, &output, &format!("{name}-{tone}-{width}"))?;
                                            if phase == 2 {
                                                let native: gpui::AnyWindowHandle = window.into();
                                                native.update(cx, |_, window, cx| {
                                                    window.draw(cx).clear();
                                                    let position = window.debug_bounds("discard-working-tree-cancel")
                                                        .expect("discard confirmation has a visible Cancel button").center();
                                                    window.dispatch_event(gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                                                        position, button: gpui::MouseButton::Left, click_count: 1, ..Default::default()
                                                    }), cx);
                                                    window.dispatch_event(gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                                                        position, button: gpui::MouseButton::Left, click_count: 1, ..Default::default()
                                                    }), cx);
                                                })?;
                                                pause(cx, 150).await;
                                                window.update(cx, |shell, window, cx| shell.fixture_turn_changes_review(8, window, cx))?;
                                            }
                                            if turn_changes_interactive && phase == 1 {
                                                state.update(cx, |state, _| assert!(state.engine().is_none(), "interactive Changes preview must have no engine handle"));
                                                window.update(cx, |_, window, cx| {
                                                    window.activate_window();
                                                    cx.activate(true);
                                                })?;
                                                // Keep this isolated, synthetic view open for
                                                // local comment editing until the user closes it.
                                                loop {
                                                    pause(cx, 250).await;
                                                    if window.update(cx, |_, _, _| ()).is_err() {
                                                        active_window = None;
                                                        return Ok(());
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    window.update(cx, |_, window, _| window.remove_window())?;
                                    active_window = None;
                                    continue;
                                }
                                if follow_up_refinements {
                                    for (width, height) in [(1440., 900.), (980., 700.)] {
                                        window.update(cx, |_, window, _| window.resize(size(px(width), px(height))))?;
                                        for variant in ["attention-waiting", "attention-error", "attention-overflow", "newtab"] {
                                            window.update(cx, |shell, window, cx| shell.fixture_attention_import(variant, window, cx))?;
                                            pause(cx, 600).await;
                                            capture(window.into(), cx, &output, &format!("{variant}-{tone}-{width}"))?;
                                            if variant == "attention-overflow" {
                                                { let native: gpui::AnyWindowHandle = window.into(); native.update(cx, |_, window, cx| {
                                                    let position = window.debug_bounds("panel-attention-0").expect("offscreen attention control visible").center();
                                                    window.dispatch_event(gpui::PlatformInput::MouseDown(gpui::MouseDownEvent { position, button: gpui::MouseButton::Left, click_count: 1, ..Default::default() }), cx);
                                                    window.dispatch_event(gpui::PlatformInput::MouseUp(gpui::MouseUpEvent { position, button: gpui::MouseButton::Left, click_count: 1, ..Default::default() }), cx);
                                                })?; }
                                                pause(cx, 200).await;
                                                anyhow::ensure!(window.update(cx, |shell, _, cx| shell.fixture_attention_selected(cx))?, "attention control must open the affected chat");
                                            }
                                        }
                                        for variant in ["card", "detail", "stopped", "temporary", "loading", "error", "unavailable", "sidebar-closed"] {
                                            if variant == "detail" {
                                                let position = window.update(cx, |shell, window, cx| shell.fixture_cloud_card_center(window, cx))?;
                                                cloud_pointer_move(window, position, cx)?;
                                                pause(cx, 500).await;
                                            }
                                            window.update(cx, |shell, window, cx| shell.fixture_cloud_refinement(variant, window, cx))?;
                                            pause(cx, 600).await;
                                            capture(window.into(), cx, &output, &format!("cloud-{variant}-{tone}-{width}"))?;
                                            if variant == "detail" {
                                                { let native: gpui::AnyWindowHandle = window.into(); native.update(cx, |_, window, cx| window.dispatch_keystroke(gpui::Keystroke::parse("escape").unwrap(), cx))?; }
                                                pause(cx, 100).await;
                                                anyhow::ensure!(!window.update(cx, |shell, _, _| shell.fixture_cloud_detail_is_open())?, "Escape must close cloud details");
                                            }
                                            if variant == "sidebar-closed" {
                                                let position = window.update(cx, |shell, window, cx| shell.fixture_cloud_card_center(window, cx))?;
                                                cloud_pointer_move(window, position, cx)?;
                                                pause(cx, 500).await;
                                                anyhow::ensure!(window.update(cx, |shell, _, _| shell.fixture_cloud_detail_is_open())?, "hovering the closed-sidebar chip must open cloud details");
                                                capture(window.into(), cx, &output, &format!("cloud-sidebar-closed-detail-{tone}-{width}"))?;
                                            }
                                        }
                                    }
                                    window.update(cx, |_, window, _| window.remove_window())?;
                                    active_window = None;
                                    continue;
                                }
                                if reconciliation_design {
                                    for (width, height) in [(1440., 900.), (980., 700.)] {
                                        window.update(cx, |_, window, _| window.resize(size(px(width), px(height))))?;
                                        for variant in ["attention-a", "attention-b", "attention-c", "focus-minimal", "focus-top", "focus-full", "focus-loud", "cloud-a", "cloud-b", "cloud-c", "cloud-states", "newtab-links", "newtab-tiles"] {
                                            if std::env::var_os("HARNESS_DESIGN_ATTENTION_ONLY").is_some() && !variant.starts_with("attention-") { continue; }
                                            window.update(cx, |shell, window, cx| shell.fixture_reconciliation_design(variant, window, cx))?;
                                            pause(cx, 350).await;
                                            window.update(cx, |_, _, cx| cx.refresh_windows())?;
                                            pause(cx, 100).await;
                                            capture(window.into(), cx, &output, &format!("{variant}-{tone}-{width}"))?;
                                        }
                                    }
                                    window.update(cx, |_, window, _| window.remove_window())?;
                                    active_window = None;
                                    continue;
                                }
                                if session_emoji {
                                    for (phase, name) in [(0, "picker"), (1, "search"), (2, "sidebar"), (3, "switcher"), (4, "icons"), (5, "section-boundary"), (6, "category"), (7, "mid-scroll"), (8, "list-end")] {
                                        if phase == 5 {
                                            // Let the reopened list measure its rows before scrolling.
                                            window.update(cx, |shell, window, cx| shell.fixture_session_emoji(0, window, cx))?;
                                            pause(cx, 450).await;
                                        }
                                        window.update(cx, |shell, window, cx| shell.fixture_session_emoji(phase, window, cx))?;
                                        pause(cx, 450).await;
                                        capture(window.into(), cx, &output, &format!("session-emoji-{tone}-{name}"))?;
                                    }
                                    window.update(cx, |_, window, _| window.remove_window())?;
                                    active_window = None;
                                    continue;
                                }
                                for (width, height) in [(1200., 760.), (980., 700.)] {
                                    window.update(cx, |shell, window, cx| {
                                        window.resize(size(px(width), px(height)));
                                        shell.fixture_session_hierarchy(4, window, cx);
                                        shell.fixture_session_hierarchy_hover(false, window, cx);
                                    })?;
                                    pause(cx, 500).await;
                                    capture(window.into(), cx, &output, &format!("session-hierarchy-{tone}-{width}-compact"))?;
                                    window.update(cx, |shell, window, cx| shell.fixture_session_hierarchy_hover(true, window, cx))?;
                                    pause(cx, 260).await;
                                    capture(window.into(), cx, &output, &format!("session-hierarchy-{tone}-{width}-hover"))?;
                                    window.update(cx, |shell, window, cx| {
                                        shell.fixture_session_hierarchy_hover(false, window, cx);
                                        shell.fixture_session_hierarchy(1, window, cx);
                                    })?;
                                    pause(cx, 260).await;
                                    capture(window.into(), cx, &output, &format!("session-hierarchy-{tone}-{width}-details"))?;
                                    for (phase, name) in [(2, "new-tab"), (6, "collapsed")] {
                                        window.update(cx, |shell, window, cx| shell.fixture_session_hierarchy(phase, window, cx))?;
                                        pause(cx, 450).await;
                                        capture(window.into(), cx, &output, &format!("session-hierarchy-{tone}-{width}-{name}"))?;
                                    }
                                    for (phase, name) in [
                                        (3, "inactive-composer"),
                                        (7, "session-hover"),
                                        (8, "session-menu"),
                                        (9, "session-icons"),
                                        (10, "session-switcher"),
                                    ] {
                                        window.update(cx, |shell, window, cx| {
                                            shell.fixture_session_hierarchy(4, window, cx);
                                            shell.fixture_session_hierarchy(phase, window, cx);
                                        })?;
                                        pause(cx, 450).await;
                                        capture(window.into(), cx, &output, &format!("session-hierarchy-{tone}-{width}-{name}"))?;
                                    }
                                }
                                if std::env::var_os("HARNESS_FIXTURE_HOLD").is_some() {
                                    window.update(cx, |shell, window, cx| {
                                        shell.fixture_session_hierarchy(4, window, cx);
                                        shell.fixture_session_hierarchy(1, window, cx);
                                    })?;
                                    pause(cx, 90_000).await;
                                }
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }
                            if connected_tabs {
                                let native: gpui::AnyWindowHandle = window.into();
                                for (width, height) in [(1200., 760.), (980., 700.)] {
                                    window.update(cx, |shell, window, cx| {
                                        window.resize(size(px(width), px(height)));
                                        shell.fixture_panel_layout(50, window, cx);
                                    })?;
                                    for (phase, name) in [(50, "first"), (51, "middle"), (52, "last"), (54, "focus"), (53, "columns")] {
                                        window.update(cx, |shell, window, cx| {
                                            shell.fixture_panel_layout(phase, window, cx);
                                        })?;
                                        pause(cx, 450).await;
                                        capture(window.into(), cx, &output, &format!("connected-tabs-{tone}-{width}-{name}"))?;
                                    }
                                    window.update(cx, |shell, window, cx| {
                                        shell.fixture_panel_layout(50, window, cx);
                                    })?;
                                    native.update(cx, |_, window, cx| {
                                        window.dispatch_event(gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                                            position: point(px(520.), px(21.)),
                                            pressed_button: None,
                                            modifiers: Default::default(),
                                        }), cx);
                                    })?;
                                    pause(cx, 220).await;
                                    capture(window.into(), cx, &output, &format!("connected-tabs-{tone}-{width}-hover"))?;
                                }
                                if std::env::var_os("HARNESS_FIXTURE_HOLD").is_some() {
                                    window.update(cx, |shell, window, cx| {
                                        shell.fixture_panel_layout(50, window, cx);
                                    })?;
                                    pause(cx, 45_000).await;
                                }
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }
                            if tab_icons {
                                window.update(cx, |shell, window, cx| {
                                    shell.fixture_panel_layout(49, window, cx);
                                })?;
                                for (width, height) in [(1200., 760.), (980., 700.)] {
                                    window.update(cx, |_, window, _| {
                                        window.resize(size(px(width), px(height)));
                                    })?;
                                    pause(cx, 650).await;
                                    capture(
                                        window.into(),
                                        cx,
                                        &output,
                                        &format!("tab-icons-{tone}-{width}"),
                                    )?;
                                }
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }
                            if panel_composer {
                                for (width, height) in [(1200., 760.), (980., 700.)] {
                                    for (phase, name) in
                                        [
                                            (45, "bottom"),
                                            (48, "bottom-started"),
                                            (46, "top"),
                                            (47, "expanded"),
                                        ]
                                    {
                                        window.update(cx, |shell, window, cx| {
                                            window.resize(size(px(width), px(height)));
                                            shell.fixture_panel_layout(phase, window, cx);
                                        })?;
                                        pause(cx, 650).await;
                                        capture(
                                            window.into(),
                                            cx,
                                            &output,
                                            &format!("panel-composer-{tone}-{width}-{name}"),
                                        )?;
                                    }
                                }
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }
                            if panel_axes {
                                let native: gpui::AnyWindowHandle = window.into();
                                for (width, height) in [(1200., 760.), (980., 700.), (1600., 1200.)]
                                {
                                    window.update(cx, |_, window, _| {
                                        window.resize(size(px(width), px(height)));
                                        window.activate_window();
                                    })?;
                                    pause(cx, 250).await;
                                    let (actual_height, expected_rows) = window.update(cx, |shell, window, cx| {
                                        (f32::from(window.viewport_size().height), shell.fixture_panel_limit_state(cx).0)
                                    })?;
                                    eprintln!("panel capacity: requested {height}, actual {actual_height}, limit {expected_rows}");
                                    for edge in ["top", "bottom"] {
                                        window.update(cx, |shell, window, cx| {
                                            window.resize(size(px(width), px(height)));
                                            shell.fixture_panel_layout(
                                                if expected_rows == 3 { 40 } else { 12 },
                                                window,
                                                cx,
                                            );
                                            window.activate_window();
                                        })?;
                                        pause(cx, 250).await;
                                        let before = window.update(cx, |shell, _, cx| {
                                            shell.fixture_panel_axis_state(cx)
                                        })?;
                                        let source =
                                            before.1.iter().find(|(id, _)| *id == 0).unwrap().1;
                                        let start = source.origin + point(px(80.), px(20.));
                                        let target = point(
                                            source.center().x,
                                            if edge == "top" {
                                                source.top() + px(42.)
                                            } else {
                                                source.bottom() - px(5.)
                                            },
                                        );
                                        capture(
                                            native,
                                            cx,
                                            &output,
                                            &format!("axes-{tone}-{width}-{edge}-before"),
                                        )?;
                                        native.update(cx, |_, window, cx| {
                                            window.dispatch_event(
                                                gpui::PlatformInput::MouseDown(
                                                    gpui::MouseDownEvent {
                                                        position: start,
                                                        button: gpui::MouseButton::Left,
                                                        click_count: 1,
                                                        ..Default::default()
                                                    },
                                                ),
                                                cx,
                                            );
                                            window.dispatch_event(
                                                gpui::PlatformInput::MouseMove(
                                                    gpui::MouseMoveEvent {
                                                        position: start + point(px(12.), px(4.)),
                                                        pressed_button: Some(
                                                            gpui::MouseButton::Left,
                                                        ),
                                                        modifiers: Default::default(),
                                                    },
                                                ),
                                                cx,
                                            );
                                        })?;
                                        pause(cx, 80).await;
                                        native.update(cx, |_, window, cx| {
                                            window.dispatch_event(
                                                gpui::PlatformInput::MouseMove(
                                                    gpui::MouseMoveEvent {
                                                        position: target,
                                                        pressed_button: Some(
                                                            gpui::MouseButton::Left,
                                                        ),
                                                        modifiers: Default::default(),
                                                    },
                                                ),
                                                cx,
                                            );
                                        })?;
                                        pause(cx, 300).await;
                                        let preview = window.update(cx, |shell, _, cx| {
                                            shell.fixture_panel_axis_state(cx)
                                        })?;
                                        capture(
                                            native,
                                            cx,
                                            &output,
                                            &format!("axes-{tone}-{width}-{edge}-preview"),
                                        )?;
                                        assert_eq!(
                                            preview.2,
                                            Some((0, edge)),
                                            "preview state: {preview:?}"
                                        );
                                        assert!(
                                            !preview.0,
                                            "preview must not mutate the stored axis"
                                        );
                                        native.update(cx, |_, window, cx| {
                                            window.dispatch_event(
                                                gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                                                    position: target,
                                                    button: gpui::MouseButton::Left,
                                                    click_count: 1,
                                                    ..Default::default()
                                                }),
                                                cx,
                                            );
                                        })?;
                                        pause(cx, 300).await;
                                        let committed = window.update(cx, |shell, _, cx| {
                                            shell.fixture_panel_axis_state(cx)
                                        })?;
                                        assert!(committed.0);
                                        assert_eq!(committed.1.len(), expected_rows);
                                        let mut rows = window.update(cx, |shell, _, cx| {
                                            shell.fixture_panel_visible_bounds(cx)
                                        })?;
                                        rows.sort_by(|a, b| a.top().partial_cmp(&b.top()).unwrap());
                                        for pair in rows.windows(2) {
                                            assert!(
                                                (f32::from(pair[1].top() - pair[0].bottom()) - 36.)
                                                    .abs()
                                                    < 1.
                                            );
                                            assert_eq!(pair[0].size.width, pair[1].size.width);
                                        }
                                        capture(
                                            native,
                                            cx,
                                            &output,
                                            &format!("axes-{tone}-{width}-{edge}-dropped"),
                                        )?;
                                    }
                                    window.update(cx, |shell, window, cx| {
                                        shell.fixture_panel_layout(41, window, cx);
                                        window.activate_window();
                                    })?;
                                    pause(cx, 250).await;
                                    let state = window.update(cx, |shell, _, cx| {
                                        shell.fixture_panel_axis_state(cx)
                                    })?;
                                    let upper = state.1.iter().find(|(id, _)| *id == 0).unwrap().1;
                                    let lower = state.1.iter().find(|(id, _)| *id == 1).unwrap().1;
                                    let start = upper.origin + point(px(80.), px(20.));
                                    let seam = point(
                                        upper.center().x,
                                        (upper.bottom() + lower.top()) / 2.,
                                    );
                                    native.update(cx, |_, window, cx| {
                                        window.dispatch_event(
                                            gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                                                position: start,
                                                button: gpui::MouseButton::Left,
                                                click_count: 1,
                                                ..Default::default()
                                            }),
                                            cx,
                                        );
                                        window.dispatch_event(
                                            gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                                                position: start + point(px(12.), px(4.)),
                                                pressed_button: Some(gpui::MouseButton::Left),
                                                modifiers: Default::default(),
                                            }),
                                            cx,
                                        );
                                    })?;
                                    pause(cx, 80).await;
                                    for delta in [-3., 3., 0.] {
                                        native.update(cx, |_, window, cx| {
                                            window.dispatch_event(
                                                gpui::PlatformInput::MouseMove(
                                                    gpui::MouseMoveEvent {
                                                        position: seam + point(px(0.), px(delta)),
                                                        pressed_button: Some(
                                                            gpui::MouseButton::Left,
                                                        ),
                                                        modifiers: Default::default(),
                                                    },
                                                ),
                                                cx,
                                            );
                                        })?;
                                        pause(cx, 300).await;
                                        let target = window.update(cx, |shell, _, cx| {
                                            shell.fixture_panel_axis_state(cx).2
                                        })?;
                                        assert_eq!(
                                            target,
                                            if expected_rows == 3 {
                                                Some((0, "bottom"))
                                            } else {
                                                None
                                            }
                                        );
                                    }
                                    capture(
                                        native,
                                        cx,
                                        &output,
                                        &format!("axes-{tone}-{width}-stacked-seam"),
                                    )?;
                                    native.update(cx, |_, window, cx| {
                                        window.dispatch_event(
                                            gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                                                position: seam,
                                                button: gpui::MouseButton::Left,
                                                click_count: 1,
                                                ..Default::default()
                                            }),
                                            cx,
                                        );
                                    })?;
                                    pause(cx, 300).await;
                                    let state = window.update(cx, |shell, _, cx| {
                                        shell.fixture_panel_axis_state(cx)
                                    })?;
                                    assert_eq!(state.1.len(), expected_rows);
                                    assert_eq!(
                                        window.update(cx, |shell, _, cx| shell
                                            .fixture_panel_limit_state(cx)
                                            .1)?,
                                        3
                                    );
                                    window.update(cx, |shell, window, cx| {
                                        shell.fixture_panel_layout(43, window, cx)
                                    })?;
                                    pause(cx, 150).await;
                                    capture(
                                        native,
                                        cx,
                                        &output,
                                        &format!("axes-{tone}-{width}-height-limit-menu"),
                                    )?;
                                    if expected_rows == 3 {
                                        window.update(cx, |shell, window, cx| {
                                            shell.fixture_panel_layout(44, window, cx);
                                            window.resize(size(px(1200.), px(760.)));
                                        })?;
                                        pause(cx, 300).await;
                                        let state = window.update(cx, |shell, _, cx| {
                                            shell.fixture_panel_axis_state(cx)
                                        })?;
                                        assert_eq!(state.1.len(), 2);
                                        assert_eq!(
                                            window.update(cx, |shell, _, cx| shell
                                                .fixture_panel_limit_state(cx)
                                                .1)?,
                                            3
                                        );
                                        capture(
                                            native,
                                            cx,
                                            &output,
                                            &format!("axes-{tone}-resized-to-laptop"),
                                        )?;
                                    }
                                }
                                active_window = None;
                                continue;
                            }
                            if panel_stability {
                                let native: gpui::AnyWindowHandle = window.into();
                                for (width, height) in [(1200., 760.), (980., 700.)] {
                                    window.update(cx, |shell, window, cx| {
                                        window.resize(size(px(width), px(height)));
                                        shell.fixture_panel_layout(30, window, cx);
                                    })?;
                                    pause(cx, 250).await;
                                    window.update(cx, |shell, window, cx| {
                                        shell.fixture_panel_layout(31, window, cx)
                                    })?;
                                    let mut baseline = None;
                                    for (name, hover) in [("idle", false), ("hover", true)] {
                                        native.update(cx, |_, window, cx| {
                                            window.dispatch_event(
                                                gpui::PlatformInput::MouseMove(
                                                    gpui::MouseMoveEvent {
                                                        position: if hover {
                                                            point(px(400.), px(300.))
                                                        } else {
                                                            point(px(120.), px(180.))
                                                        },
                                                        pressed_button: None,
                                                        modifiers: Default::default(),
                                                    },
                                                ),
                                                cx,
                                            );
                                        })?;
                                        pause(cx, 250).await;
                                        let state = window.update(cx, |shell, _, cx| {
                                            shell.fixture_panel_stability_state(cx)
                                        })?;
                                        if let Some((offset, bounds)) = baseline {
                                            assert_eq!((state.0, state.1), (offset, bounds));
                                        }
                                        baseline = Some((state.0, state.1));
                                        capture(
                                            native,
                                            cx,
                                            &output,
                                            &format!("stability-{tone}-{width}-{name}"),
                                        )?;
                                    }
                                    window.update(cx, |shell, window, cx| {
                                        shell.fixture_panel_layout(30, window, cx)
                                    })?;
                                    pause(cx, 250).await;
                                    let start = point(px(350.), px(20.));
                                    let seam = point(px(272. + (width - 280.) / 2.), px(280.));
                                    native.update(cx, |_, window, cx| {
                                        window.dispatch_event(
                                            gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                                                position: start,
                                                button: gpui::MouseButton::Left,
                                                click_count: 1,
                                                ..Default::default()
                                            }),
                                            cx,
                                        );
                                        window.dispatch_event(
                                            gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                                                position: start + point(px(12.), px(4.)),
                                                pressed_button: Some(gpui::MouseButton::Left),
                                                modifiers: Default::default(),
                                            }),
                                            cx,
                                        );
                                    })?;
                                    pause(cx, 80).await;
                                    for (name, delta) in [
                                        ("seam-left", -3.),
                                        ("seam-right", 3.),
                                        ("seam-center", 0.),
                                    ] {
                                        native.update(cx, |_, window, cx| {
                                            window.dispatch_event(
                                                gpui::PlatformInput::MouseMove(
                                                    gpui::MouseMoveEvent {
                                                        position: seam + point(px(delta), px(0.)),
                                                        pressed_button: Some(
                                                            gpui::MouseButton::Left,
                                                        ),
                                                        modifiers: Default::default(),
                                                    },
                                                ),
                                                cx,
                                            );
                                        })?;
                                        pause(cx, 300).await;
                                        let target = window.update(cx, |shell, _, cx| {
                                            shell.fixture_panel_stability_state(cx).2
                                        })?;
                                        assert_eq!(target, Some((0, true)));
                                        capture(
                                            native,
                                            cx,
                                            &output,
                                            &format!("stability-{tone}-{width}-{name}"),
                                        )?;
                                    }
                                    native.update(cx, |_, window, cx| {
                                        window.dispatch_event(
                                            gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                                                position: seam,
                                                button: gpui::MouseButton::Left,
                                                click_count: 1,
                                                ..Default::default()
                                            }),
                                            cx,
                                        );
                                    })?;
                                    pause(cx, 350).await;
                                    capture(
                                        native,
                                        cx,
                                        &output,
                                        &format!("stability-{tone}-{width}-dropped"),
                                    )?;
                                }
                                active_window = None;
                                continue;
                            }
                            if panel_edge_drag {
                                let native: gpui::AnyWindowHandle = window.into();
                                for (width, height) in [(1200., 760.), (980., 700.)] {
                                    for (right, side) in [(true, "right"), (false, "left")] {
                                        window.update(cx, |shell, window, cx| {
                                            window.resize(size(px(width), px(height)));
                                            shell.fixture_panel_layout(12, window, cx);
                                        })?;
                                        pause(cx, 300).await;
                                        capture(
                                            native,
                                            cx,
                                            &output,
                                            &format!("edge-drag-{tone}-{width}-{side}-before"),
                                        )?;
                                        let start = point(px(350.), px(20.));
                                        let end = point(
                                            px(if right { width - 12. } else { 284. }),
                                            px(280.),
                                        );
                                        native.update(cx, |_, window, cx| {
                                            window.dispatch_event(
                                                gpui::PlatformInput::MouseDown(
                                                    gpui::MouseDownEvent {
                                                        position: start,
                                                        button: gpui::MouseButton::Left,
                                                        click_count: 1,
                                                        ..Default::default()
                                                    },
                                                ),
                                                cx,
                                            );
                                            window.dispatch_event(
                                                gpui::PlatformInput::MouseMove(
                                                    gpui::MouseMoveEvent {
                                                        position: start + point(px(12.), px(4.)),
                                                        pressed_button: Some(
                                                            gpui::MouseButton::Left,
                                                        ),
                                                        modifiers: Default::default(),
                                                    },
                                                ),
                                                cx,
                                            );
                                        })?;
                                        pause(cx, 80).await;
                                        native.update(cx, |_, window, cx| {
                                            window.dispatch_event(
                                                gpui::PlatformInput::MouseMove(
                                                    gpui::MouseMoveEvent {
                                                        position: end,
                                                        pressed_button: Some(
                                                            gpui::MouseButton::Left,
                                                        ),
                                                        modifiers: Default::default(),
                                                    },
                                                ),
                                                cx,
                                            );
                                        })?;
                                        pause(cx, 300).await;
                                        capture(
                                            native,
                                            cx,
                                            &output,
                                            &format!("edge-drag-{tone}-{width}-{side}-preview"),
                                        )?;
                                        // Leave the split zone without dropping: the live page
                                        // returns to its original width and no tab is created.
                                        let cancel = point(
                                            px(272.
                                                + (width - 280.) * if right { 0.25 } else { 0.75 }),
                                            px(300.),
                                        );
                                        native.update(cx, |_, window, cx| {
                                            window.dispatch_event(
                                                gpui::PlatformInput::MouseMove(
                                                    gpui::MouseMoveEvent {
                                                        position: cancel,
                                                        pressed_button: Some(
                                                            gpui::MouseButton::Left,
                                                        ),
                                                        modifiers: Default::default(),
                                                    },
                                                ),
                                                cx,
                                            );
                                        })?;
                                        pause(cx, 300).await;
                                        capture(
                                            native,
                                            cx,
                                            &output,
                                            &format!("edge-drag-{tone}-{width}-{side}-cancelled"),
                                        )?;
                                        native.update(cx, |_, window, cx| {
                                            window.dispatch_event(
                                                gpui::PlatformInput::MouseMove(
                                                    gpui::MouseMoveEvent {
                                                        position: end,
                                                        pressed_button: Some(
                                                            gpui::MouseButton::Left,
                                                        ),
                                                        modifiers: Default::default(),
                                                    },
                                                ),
                                                cx,
                                            );
                                        })?;
                                        pause(cx, 300).await;
                                        native.update(cx, |_, window, cx| {
                                            window.dispatch_event(
                                                gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                                                    position: end,
                                                    button: gpui::MouseButton::Left,
                                                    click_count: 1,
                                                    ..Default::default()
                                                }),
                                                cx,
                                            );
                                        })?;
                                        pause(cx, 300).await;
                                        capture(
                                            native,
                                            cx,
                                            &output,
                                            &format!("edge-drag-{tone}-{width}-{side}-after"),
                                        )?;
                                    }
                                }
                                // Keep peer transcript windows alive until app quit;
                                // their queued paints can outlive native window removal.
                                active_window = None;
                                continue;
                            }
                            if panel_placement {
                                let native: gpui::AnyWindowHandle = window.into();
                                for (width, height) in [(1500., 900.), (980., 700.)] {
                                    window.update(cx, |shell, window, cx| {
                                        window.resize(size(px(width), px(height)));
                                        shell.fixture_panel_layout(9, window, cx);
                                    })?;
                                    for (phase, name) in
                                        [(13, "menu"), (14, "added"), (15, "middle-menu")]
                                    {
                                        window.update(cx, |shell, window, cx| {
                                            shell.fixture_panel_layout(phase, window, cx)
                                        })?;
                                        if phase == 13 || phase == 15 {
                                            pause(cx, 200).await;
                                            native.update(cx, |_, window, cx| {
                                                let keystroke =
                                                    gpui::Keystroke::parse("enter").unwrap();
                                                window.dispatch_event(
                                                    gpui::PlatformInput::KeyDown(
                                                        gpui::KeyDownEvent {
                                                            keystroke: keystroke.clone(),
                                                            is_held: false,
                                                            prefer_character_input: false,
                                                        },
                                                    ),
                                                    cx,
                                                );
                                                window.dispatch_event(
                                                    gpui::PlatformInput::KeyUp(gpui::KeyUpEvent {
                                                        keystroke,
                                                    }),
                                                    cx,
                                                );
                                            })?;
                                        }
                                        pause(cx, 350).await;
                                        capture(
                                            window.into(),
                                            cx,
                                            &output,
                                            &format!("panel-placement-{tone}-{width}-{name}"),
                                        )?;
                                    }
                                }
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }
                            if tab_density {
                                let native: gpui::AnyWindowHandle = window.into();
                                for (width, height) in [(980., 700.), (1200., 760.), (1600., 900.)]
                                {
                                    window.update(cx, |shell, window, cx| {
                                        window.resize(size(px(width), px(height)));
                                        shell.fixture_panel_layout(16, window, cx);
                                    })?;
                                    for (name, hover, delay) in [
                                        ("idle", false, 250),
                                        ("entering", true, 60),
                                        ("hover", true, 180),
                                        ("leaving", false, 60),
                                        ("restored", false, 180),
                                    ] {
                                        native.update(cx, |_, window, cx| {
                                            window.dispatch_event(
                                                gpui::PlatformInput::MouseMove(
                                                    gpui::MouseMoveEvent {
                                                        position: if hover {
                                                            point(
                                                                px(272. + (width - 280.) * 0.5),
                                                                px(300.),
                                                            )
                                                        } else {
                                                            point(px(120.), px(180.))
                                                        },
                                                        pressed_button: None,
                                                        modifiers: Default::default(),
                                                    },
                                                ),
                                                cx,
                                            );
                                        })?;
                                        pause(cx, delay).await;
                                        capture(
                                            window.into(),
                                            cx,
                                            &output,
                                            &format!("tab-density-{tone}-{width}-{name}"),
                                        )?;
                                    }
                                }
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }
                            if panel_controls {
                                let native: gpui::AnyWindowHandle = window.into();
                                for (width, height) in [(1200., 760.), (980., 700.)] {
                                    window.update(cx, |shell, window, cx| {
                                        window.resize(size(px(width), px(height)));
                                        shell.fixture_panel_layout(9, window, cx);
                                    })?;
                                    for (name, position) in [
                                        ("idle", point(px(120.), px(180.))),
                                        (
                                            "hover",
                                            point(px(272. + (width - 280.) * 0.75), px(300.)),
                                        ),
                                        ("placement", point(px(width - 102.), px(21.))),
                                        ("gap", point(px(width - 89.), px(21.))),
                                        ("add-tab", point(px(width - 76.), px(21.))),
                                        ("expand", point(px(width - 50.), px(21.))),
                                        ("close", point(px(width - 24.), px(21.))),
                                        ("leave", point(px(120.), px(180.))),
                                    ] {
                                        native.update(cx, |_, window, cx| {
                                            window.dispatch_event(
                                                gpui::PlatformInput::MouseMove(
                                                    gpui::MouseMoveEvent {
                                                        position,
                                                        pressed_button: None,
                                                        modifiers: Default::default(),
                                                    },
                                                ),
                                                cx,
                                            );
                                        })?;
                                        pause(cx, 300).await;
                                        capture(
                                            window.into(),
                                            cx,
                                            &output,
                                            &format!("panel-controls-{tone}-{width}-{name}"),
                                        )?;
                                    }
                                    native.update(cx, |_, window, cx| {
                                        window.dispatch_event(
                                            gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                                                position: point(px(120.), px(180.)),
                                                pressed_button: None,
                                                modifiers: Default::default(),
                                            }),
                                            cx,
                                        );
                                    })?;
                                    window.update(cx, |shell, window, cx| {
                                        shell.fixture_panel_layout(3, window, cx);
                                        window.blur();
                                    })?;
                                    pause(cx, 300).await;
                                    native.update(cx, |_, window, cx| {
                                        window.dispatch_event(
                                            gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                                                position: point(px(-10.), px(-10.)),
                                                pressed_button: None,
                                                modifiers: Default::default(),
                                            }),
                                            cx,
                                        );
                                    })?;
                                    pause(cx, 300).await;
                                    capture(
                                        native,
                                        cx,
                                        &output,
                                        &format!("panel-controls-{tone}-{width}-expanded-idle"),
                                    )?;
                                    let restore = point(px(width - 50.), px(21.));
                                    native.update(cx, |_, window, cx| {
                                        window.dispatch_event(
                                            gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                                                position: restore,
                                                pressed_button: None,
                                                modifiers: Default::default(),
                                            }),
                                            cx,
                                        );
                                    })?;
                                    pause(cx, 300).await;
                                    capture(
                                        native,
                                        cx,
                                        &output,
                                        &format!("panel-controls-{tone}-{width}-expanded-hover"),
                                    )?;
                                    native.update(cx, |_, window, cx| {
                                        window.dispatch_event(
                                            gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                                                position: restore,
                                                button: gpui::MouseButton::Left,
                                                click_count: 1,
                                                ..Default::default()
                                            }),
                                            cx,
                                        );
                                        window.dispatch_event(
                                            gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                                                position: restore,
                                                button: gpui::MouseButton::Left,
                                                click_count: 1,
                                                ..Default::default()
                                            }),
                                            cx,
                                        );
                                    })?;
                                    pause(cx, 300).await;
                                    native.update(cx, |_, window, cx| {
                                        window.dispatch_event(
                                            gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                                                position: point(px(-10.), px(-10.)),
                                                pressed_button: None,
                                                modifiers: Default::default(),
                                            }),
                                            cx,
                                        );
                                    })?;
                                    pause(cx, 300).await;
                                    capture(
                                        native,
                                        cx,
                                        &output,
                                        &format!("panel-controls-{tone}-{width}-restored"),
                                    )?;
                                    window.update(cx, |shell, window, cx| {
                                        shell.fixture_panel_layout(10, window, cx);
                                    })?;
                                    pause(cx, 300).await;
                                    capture(
                                        window.into(),
                                        cx,
                                        &output,
                                        &format!("panel-controls-{tone}-{width}-focus"),
                                    )?;
                                    window.update(cx, |shell, window, cx| {
                                        shell.fixture_panel_layout(11, window, cx)
                                    })?;
                                    pause(cx, 300).await;
                                    capture(
                                        window.into(),
                                        cx,
                                        &output,
                                        &format!("panel-controls-{tone}-{width}-closed"),
                                    )?;
                                }
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }
                            if panel_review {
                                window.update(cx, |shell, window, cx| shell.fixture_panel_layout(0, window, cx))?;
                                for (width,height) in [(1500.,900.),(1200.,760.)] {
                                    window.update(cx, |_, window, _| window.resize(size(px(width),px(height))))?;
                                    pause(cx, 500).await;
                                    capture(window.into(), cx, &output, &format!("panels-{tone}-{width}"))?;
                                }
                                for (phase,name) in [(7,"files-hidden"),(8,"files-restored"),(1,"reordered"),(2,"transferred"),(3,"expanded"),(4,"restored"),(5,"menu"),(6,"draft")] {
                                    window.update(cx, |shell, window, cx| shell.fixture_panel_layout(phase, window, cx))?;
                                    pause(cx,350).await;
                                    capture(window.into(), cx, &output, &format!("panels-{tone}-{name}"))?;
                                }
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }
                            if sidebar_matrix {
                                window.update(cx, |_, window, _| {
                                    window.resize(size(px(1200.), px(760.)))
                                })?;
                                for sidebar_width in [220., 272., 360.] {
                                    for mask in 0..32 {
                                        window.update(cx, |shell, _, cx| {
                                            shell.fixture_sidebar_display_options(
                                                mask,
                                                sidebar_width,
                                                cx,
                                            )
                                        })?;
                                        pause(cx, 60).await;
                                        capture(
                                            window.into(),
                                            cx,
                                            &output,
                                            &format!("sidebar-{tone}-{sidebar_width}-{mask:02}"),
                                        )?;
                                    }
                                }
                                window.update(cx, |shell, window, cx| {
                                    shell.fixture_sidebar_display_options(31, 272., cx);
                                    shell.fixture_sidebar_display_menu(false, window, cx);
                                })?;
                                pause(cx, 350).await;
                                capture(
                                    window.into(),
                                    cx,
                                    &output,
                                    &format!("sidebar-menu-{tone}"),
                                )?;
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }



                            if sidebar_hover_motion {
                                let native: gpui::AnyWindowHandle = window.into();
                                let scale = motion::speed_scale();
                                // Let the app entrance settle even when the measurement
                                // knob stretches motion for native capture sampling.
                                pause(cx, (650.0 * scale) as u64).await;
                                for sidebar_width in [220., 340.] {
                                    window.update(cx, |shell, window, cx| {
                                        window.resize(size(px(980.), px(700.)));
                                        shell.fixture_sidebar_display_options(25, sidebar_width, cx);
                                        shell.fixture_sidebar_display_details(false, cx);
                                    })?;
                                    for (name, hovered, delay) in [
                                        ("rest", false, 220),
                                        ("entering", true, 0),
                                        ("middle", true, 30),
                                        ("hover", true, 200),
                                        ("leaving", false, 0),
                                        ("exit-middle", false, 30),
                                        ("restored", false, 200),
                                    ] {
                                        native.update(cx, |_, window, cx| {
                                            window.dispatch_event(
                                                gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                                                    position: if hovered {
                                                        point(px(150.), px(201.))
                                                    } else {
                                                        point(px(900.), px(500.))
                                                    },
                                                    pressed_button: None,
                                                    modifiers: Default::default(),
                                                }), cx,
                                            );
                                        })?;
                                        pause(cx, (delay as f32 * scale) as u64).await;
                                        capture(native, cx, &output,
                                            &format!("sidebar-hover-{tone}-{sidebar_width}-{name}"))?;
                                    }
                                }
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }
                            if simple_sidebar {
                                for sidebar_width in [220., 340.] {
                                    for expanded in [false, true] {
                                        window.update(cx, |shell, _, cx| {
                                            shell.fixture_sidebar_display_options(25, sidebar_width, cx);
                                            shell.fixture_sidebar_display_details(expanded, cx);
                                        })?;
                                        let native: gpui::AnyWindowHandle = window.into();
                                        for hovered in [false, true] {
                                            native.update(cx, |_, window, cx| {
                                                window.dispatch_event(gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                                                    position: if hovered { point(px(160.), px(201.)) } else { point(px(900.), px(500.)) },
                                                    pressed_button: None,
                                                    modifiers: Default::default(),
                                                }), cx);
                                            })?;
                                            pause(cx, 350).await;
                                            let mode = if expanded { "expanded" } else { "compact" };
                                            let state = if hovered { "hover" } else { "rest" };
                                            capture(native, cx, &output, &format!("sidebar-{tone}-{sidebar_width}-{mode}-{state}"))?;
                                        }
                                    }
                                }
                                for sidebar_width in [220., 340.] {
                                    for compact in [true, false] {
                                        let native: gpui::AnyWindowHandle = window.into();
                                        native.update(cx, |_, window, cx| {
                                            window.dispatch_event(gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                                                position: point(px(1000.), px(40.)),
                                                pressed_button: None,
                                                modifiers: Default::default(),
                                            }), cx);
                                        })?;
                                        pause(cx, 150).await;
                                        window.update(cx, |shell, window, cx| {
                                            shell.fixture_sidebar_display_options(25, sidebar_width, cx);
                                            shell.fixture_sidebar_display_menu(compact, window, cx);
                                        })?;
                                        pause(cx, 350).await;
                                        let mode = if compact { "compact" } else { "expanded" };
                                        capture(window.into(), cx, &output, &format!("sidebar-{tone}-{sidebar_width}-menu-{mode}"))?;
                                    }
                                }
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }
                            if tabs_review || panel_review {
                                window.update(cx, |shell, window, cx| {
                                    shell.fixture_workspace_tabs(window, cx)
                                })?;
                                for (width, height) in [(1200., 760.), (980., 700.)] {
                                    window.update(cx, |_, window, _| {
                                        window.resize(size(px(width), px(height)))
                                    })?;
                                    pause(cx, 600).await;
                                    capture(
                                        window.into(),
                                        cx,
                                        &output,
                                        &format!("workspace-tabs-{tone}-{width}"),
                                    )?;
                                    if width == 980.0 {
                                        let native: gpui::AnyWindowHandle = window.into();
                                        native.update(cx, |_, window, cx| {
                                            window.blur();
                                            window.focus_next(cx);
                                            window.dispatch_keystroke(gpui::Keystroke::parse("left").unwrap(), cx);
                                        })?;
                                        pause(cx, 150).await;
                                        capture(window.into(), cx, &output, &format!("session-switcher-focus-{tone}"))?;
                                    }
                                    window.update(cx, |shell, window, cx| shell.fixture_session_overview(true, window, cx))?;
                                    pause(cx, 350).await;
                                    capture(window.into(), cx, &output, &format!("session-overview-{tone}-{width}"))?;
                                    window.update(cx, |shell, window, cx| shell.fixture_session_overview(false, window, cx))?;
                                }
                                window.update(cx, |shell, window, cx| {
                                    shell.fixture_chat_tab(Some(1), window, cx)
                                })?;
                                pause(cx, 500).await;
                                capture(
                                    window.into(),
                                    cx,
                                    &output,
                                    &format!("workspace-tabs-{tone}-switched"),
                                )?;
                                window.update(cx, |shell, window, cx| {
                                    shell.fixture_chat_tab(Some(2), window, cx);
                                    window.dispatch_action(Box::new(shell::NewConversation), cx);
                                })?;
                                pause(cx, 500).await;
                                capture(window.into(), cx, &output, &format!("project-tabs-{tone}-empty"))?;
                                window.update(cx, |_, window, cx| {
                                    window.dispatch_action(Box::new(shell::ToggleSidebar), cx);
                                })?;
                                pause(cx, 600).await;
                                capture(window.into(), cx, &output, &format!("project-tabs-{tone}-empty-collapsed"))?;
                                window.update(cx, |shell, window, cx| {
                                    shell.fixture_chat_tab(Some(1), window, cx)
                                })?;
                                pause(cx, 500).await;
                                capture(window.into(), cx, &output, &format!("project-tabs-{tone}-collapsed"))?;
                                window.update(cx, |shell, window, cx| shell.fixture_chat_tab(None, window, cx))?;
                                pause(cx, 500).await;
                                capture(window.into(), cx, &output, &format!("project-tabs-{tone}-picker"))?;
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }
                            if sidebar_review {
                                for (width, height) in [(1200., 760.), (980., 700.)] {
                                    window.update(cx, |_, window, _| {
                                        window.resize(size(px(width), px(height)));
                                    })?;
                                    pause(cx, 500).await;
                                    for stage in ["open", "closed", "reopened"] {
                                        if stage != "open" {
                                            window.update(cx, |_, window, cx| {
                                                window.dispatch_action(
                                                    Box::new(shell::ToggleSidebar),
                                                    cx,
                                                );
                                            })?;
                                            pause(cx, 60).await;
                                            capture(
                                                window.into(),
                                                cx,
                                                &output,
                                                &format!(
                                                    "{}-{tone}-{width}-{stage}-moving",
                                                    candidate.palette
                                                ),
                                            )?;
                                            pause(cx, 1000).await;
                                        }
                                        capture(
                                            window.into(),
                                            cx,
                                            &output,
                                            &format!(
                                                "{}-{tone}-{width}-{stage}",
                                                candidate.palette
                                            ),
                                        )?;
                                    }
                                }
                                window.update(cx, |_, window, _| window.remove_window())?;
                                active_window = None;
                                continue;
                            }
                            capture(
                                window.into(),
                                cx,
                                &output,
                                &format!("candidate-{}-{tone}", candidate.key),
                            )?;
                            if matches!(candidate.key, "a" | "b") {
                                let palette = candidate.palette;
                                capture(
                                    window.into(),
                                    cx,
                                    &output,
                                    &format!("{palette}-{tone}-1200"),
                                )?;
                                window.update(cx, |shell, window, cx| {
                                    window.resize(size(px(980.), px(700.)));
                                    shell.fixture_appshots_transcript_start(cx);
                                })?;
                                pause(cx, 500).await;
                                capture(
                                    window.into(),
                                    cx,
                                    &output,
                                    &format!("{palette}-{tone}-980"),
                                )?;
                                if candidate.key == "b" {
                                    if hover_review {
                                        for (state, x, y) in [
                                            ("sidebar-hover", 150., 218.),
                                            ("tab-button-hover", 936., 21.),
                                            ("composer-hover", 316., 627.),
                                        ] {
                                            let native: gpui::AnyWindowHandle = window.into();
                                            native.update(cx, |_, window, cx| {
                                                window.dispatch_event(gpui::PlatformInput::MouseMove(
                                                    gpui::MouseMoveEvent {
                                                        position: point(px(x), px(y)),
                                                        pressed_button: None,
                                                        modifiers: Default::default(),
                                                    },
                                                ), cx);
                                            })?;
                                            pause(cx, 350).await;
                                            native.update(cx, |_, window, _| {
                                                window.refresh();
                                            })?;
                                            capture(window.into(), cx, &output,
                                                &format!("{palette}-{tone}-{state}"))?;
                                        }
                                    }
                                    if nested_review {
                                        for group in 0..2 {
                                            window.update(cx, |shell, window, cx| {
                                                shell.fixture_sidebar_submenu(
                                                    Some(group),
                                                    window,
                                                    cx,
                                                );
                                            })?;
                                            // Start the entrance clock before waiting, including
                                            // when this fixture's window is in the background.
                                            let native: gpui::AnyWindowHandle = window.into();
                                            native.update(cx, |_, window, cx| {
                                                window.draw(cx).clear();
                                            })?;
                                            pause(cx, 350).await;
                                            native.update(cx, |_, window, _| window.refresh())?;
                                            capture(
                                                window.into(),
                                                cx,
                                                &output,
                                                &format!(
                                                    "{palette}-{tone}-sidebar-submenu-{group}"
                                                ),
                                            )?;
                                        }
                                        window.update(cx, |shell, window, cx| {
                                            shell.fixture_sidebar_submenu(None, window, cx);
                                        })?;
                                        pause(cx, 200).await;
                                    }
                                    window.update(cx, |shell, window, cx| {
                                        let composer = shell.fixture_appshots_composer();
                                        let pickers = composer.read(cx).pickers().clone();
                                        pickers.update(cx, |pickers, cx| {
                                            pickers.open_model_menu(window, cx);
                                        });
                                    })?;
                                    pause(cx, 500).await;
                                    capture(
                                        window.into(),
                                        cx,
                                        &output,
                                        &format!("{palette}-{tone}-menu"),
                                    )?;
                                }
                            }
                            window.update(cx, |_, window, _| window.remove_window())?;
                            active_window = None;
                        }
                    }
                    Ok(())
                }
                .await;
                if let Err(error) = run {
                    eprintln!("Harp fixture failed: {error:#}");
                    *result.lock().unwrap() = Some(format!("{error:#}"));
                    if shared_header || tab_insertion || chat_history || cloud_preview {
                        // AppKit may exit directly from quit before main can
                        // report the failure; the per-tone result is saved.
                        std::process::exit(1);
                    }
                }
                if let Some(window) = active_window {
                    let _ = window.update(cx, |_, window, _| window.remove_window());
                }
                pause(cx, 100).await;
                cx.update(|cx| cx.quit());
            })
            .detach();
        });
    runtime.block_on(core.shutdown());
    if let Some(error) = failure.lock().unwrap().take() {
        anyhow::bail!(error);
    }
    Ok(())
}
