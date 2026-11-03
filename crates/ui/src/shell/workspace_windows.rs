//! Window-local navigation over the shared engine and canonical settings writer.
use super::*;
use crate::settings::SavedWorkspaceWindow;

#[derive(Default)]
struct AppServicesOwner(Option<gpui::WeakEntity<Shell>>);
impl gpui::Global for AppServicesOwner {}

/// These legacy top-level fields are each Shell's working navigation, rather
/// than shared preferences. Their canonical home is its SavedWorkspaceWindow.
fn window_navigation_setting(key: &str) -> bool {
    matches!(
        key,
        "windowGeometry"
            | "workspaceWindows"
            // Recovery has its own canonical read-modify-write API. A stale
            // window must not replay a formerly observed list as a local edit.
            | "recentlyClosedChats"
            | "hiddenHistoryEntries"
            | "chatTabs"
            | "chatTab"
            | "lastSpaceId"
            | "spaceFilter"
            | "lastChatId"
            | "chatLayout"
            | "openTabs"
            | "projectTabsVersion"
    )
}

/// A stale window may publish only preferences it actually edited. Omitted
/// optional fields participate in the comparison so an explicit reset still
/// removes the old value instead of resurrecting it from another snapshot.
fn merge_local_preferences(
    baseline: &UiSettings,
    local: &UiSettings,
    latest: &UiSettings,
) -> Result<UiSettings, serde_json::Error> {
    let baseline = serde_json::to_value(baseline)?;
    let local = serde_json::to_value(local)?;
    let mut merged = serde_json::to_value(latest)?;
    let baseline = baseline
        .as_object()
        .expect("settings serialize as an object");
    let local = local.as_object().expect("settings serialize as an object");
    let merged = merged
        .as_object_mut()
        .expect("settings serialize as an object");
    let keys: std::collections::HashSet<_> = baseline.keys().chain(local.keys()).collect();
    for key in keys {
        if window_navigation_setting(key) || baseline.get(key) == local.get(key) {
            continue;
        }
        if let Some(value) = local.get(key) {
            merged.insert(key.clone(), value.clone());
        } else {
            merged.remove(key);
        }
    }
    serde_json::from_value(serde_json::Value::Object(std::mem::take(merged)))
}

fn rebase_window_preferences(
    id: &str,
    baseline: &UiSettings,
    local: &UiSettings,
    latest: &UiSettings,
) -> Result<(UiSettings, UiSettings), serde_json::Error> {
    let mut own_navigation = SavedWorkspaceWindow::from_settings(id.into(), local);
    if let Some(saved) = latest
        .workspace_windows
        .as_ref()
        .and_then(|windows| windows.iter().find(|window| window.id == id))
    {
        own_navigation.geometry = saved.geometry;
    }
    let mut next_local = merge_local_preferences(baseline, local, latest)?;
    own_navigation.apply_to_settings(&mut next_local);
    // Do not absorb pending local edits into the baseline: a later save still
    // needs to publish them. Only the canonical preferences advance here.
    let mut next_baseline = latest.clone();
    own_navigation.apply_to_settings(&mut next_baseline);
    Ok((next_local, next_baseline))
}

fn notification_preferences(settings: &UiSettings) -> [bool; 8] {
    [
        settings.sound_enabled,
        settings.sound_completion_enabled,
        settings.sound_input_enabled,
        settings.sound_attention_enabled,
        settings.attach_sound_enabled,
        settings.notifications_enabled,
        settings.notifications_background_only,
        settings.share_performance_stats,
    ]
}

fn file_preferences(settings: &UiSettings) -> (bool, u64, bool, bool) {
    (
        settings.files_autosave_enabled,
        settings.files_autosave_delay_ms,
        settings.files_word_wrap,
        settings.files_show_all,
    )
}

impl Shell {
    pub(crate) fn new_for_window(
        state: Entity<AppState>,
        boot: EngineBootConfig,
        record: SavedWorkspaceWindow,
        cx: &mut Context<Self>,
    ) -> Self {
        let has_saved_navigation = !record.chat_tabs.is_empty()
            || record.last_chat_id.is_some()
            || record.chat_layout.is_some();
        if has_saved_navigation
            && state.read(cx).is_window_fork()
            && state.read(cx).selected_chat.is_none()
        {
            // A runtime fork suppresses automatic selection while a live tab
            // transfer installs its destination. Reopening a saved window is
            // different: its descriptor must pass through ordinary boot
            // restoration, including every workspace and pending tool slot.
            state.update(cx, |state, _| state.auto_selected = false);
        }
        if record.chat_tabs.is_empty() && record.last_chat_id.is_none() {
            state.update(cx, |state, cx| state.select_chat(None, cx));
        }
        let mut shell = Self::new(state, boot, cx);
        shell.window_id = record.id.clone();
        record.apply_to_settings(&mut shell.settings);
        shell.restore_window_chat_drafts(&record.chat_drafts, cx);
        shell.route = Route::Chat;
        shell.nav = NavHistory::new(NavEntry::Chat(String::new()));
        shell
    }

    pub(crate) fn window_id(&self) -> &str {
        &self.window_id
    }

    pub(crate) fn window_runtime(&self) -> (Entity<AppState>, EngineBootConfig) {
        (self.state.clone(), self.boot.clone())
    }

    pub(crate) fn open_window_deep_link(&mut self, url: &str, cx: &mut Context<Self>) {
        self.state
            .update(cx, |state, cx| state.open_deep_link(url, cx));
    }

    pub(crate) fn save_window_record(&mut self, cx: &mut Context<Self>) {
        if self.boot_restored {
            self.persist_chat_tabs(cx);
            self.schedule_save(cx);
        }
    }

    /// Geometry is written by the native window observer. Only replace this
    /// window's navigation while retaining the latest geometry and peer records.
    pub(super) fn merge_window_record(&mut self, cx: &App) {
        let latest = settings::current(cx);
        let mut record =
            SavedWorkspaceWindow::from_settings(self.window_id.clone(), &self.settings);
        record.chat_drafts = self.saved_window_chat_drafts(cx);
        if let Some(saved) = latest
            .workspace_windows
            .as_ref()
            .and_then(|windows| windows.iter().find(|window| window.id == self.window_id))
        {
            record.geometry = saved.geometry.clone();
        }
        self.settings.workspace_windows = latest.workspace_windows;
        self.settings.upsert_workspace_window(record);
    }

    /// Publish a preference delta plus this window's navigation, using the
    /// latest store for every unrelated preference and peer window record.
    /// Serialization is confined to saves; ordinary renders remain unchanged.
    pub(super) fn publish_window_settings(&mut self, cx: &mut Context<Self>) {
        let latest = settings::current(cx);
        let mut record =
            SavedWorkspaceWindow::from_settings(self.window_id.clone(), &self.settings);
        record.chat_drafts = self.saved_window_chat_drafts(cx);
        if let Some(saved) = latest
            .workspace_windows
            .as_ref()
            .and_then(|windows| windows.iter().find(|window| window.id == self.window_id))
        {
            record.geometry = saved.geometry;
        }
        let mut merged = match merge_local_preferences(
            &self.settings_baseline,
            &self.settings,
            &latest,
        ) {
            Ok(merged) => merged,
            Err(error) => {
                tracing::warn!(%error, "could not merge window preferences; retaining canonical preferences");
                latest.clone()
            }
        };
        let shared_preferences_changed = merged != latest;
        merged.upsert_workspace_window(record.clone());
        settings::replace(merged, SavePolicy::Debounced, cx);
        self.settings = settings::current(cx);
        // The shared store retains legacy fields for old readers. This Shell
        // continues navigating its own record regardless of the last writer.
        record.apply_to_settings(&mut self.settings);
        self.settings_baseline = self.settings.clone();
        self.settings_revision = settings::revision(cx);
        if shared_preferences_changed {
            cx.refresh_windows();
        }
    }

    /// Refresh shared preferences only when the canonical store changes. This
    /// performs no writes and retains both local navigation and pending edits.
    pub(super) fn refresh_window_preferences(&mut self, cx: &App) {
        let revision = settings::revision(cx);
        if self.settings_revision == revision {
            return;
        }
        let latest = settings::current(cx);
        let previous_notifications = notification_preferences(&self.settings);
        let previous_files = file_preferences(&self.settings);
        match rebase_window_preferences(
            &self.window_id,
            &self.settings_baseline,
            &self.settings,
            &latest,
        ) {
            Ok((local, baseline)) => {
                self.settings = local;
                self.settings_baseline = baseline;
                self.settings_revision = revision;
                // These pages cache their checkbox values. Rebuild only the
                // affected controls when another window edits their choices.
                if previous_notifications != notification_preferences(&self.settings) {
                    self.notifications_sub = None;
                    self.notifications_page = None;
                }
                if previous_files != file_preferences(&self.settings) {
                    self.files_settings_sub = None;
                    self.files_settings_page = None;
                }
            }
            Err(error) => {
                tracing::warn!(%error, "could not refresh window preferences");
            }
        }
    }

    /// One live Shell handles process-wide effects. Closing it hands ownership
    /// to a remaining window on its next state notification without retaining
    /// the closed view or starting another engine.
    pub(super) fn owns_app_services(&self, cx: &mut Context<Self>) -> bool {
        let owner = cx
            .try_global::<AppServicesOwner>()
            .and_then(|owner| owner.0.clone())
            .filter(|owner| owner.upgrade().is_some());
        if let Some(owner) = owner {
            return owner.entity_id() == cx.entity_id();
        }
        cx.set_global(AppServicesOwner(Some(cx.weak_entity())));
        true
    }

    /// Forward process-wide UI actions to the elected live owner. When the
    /// previous owner closed, this Shell takes over instead of forwarding.
    pub(super) fn app_services_peer(
        &self,
        cx: &mut Context<Self>,
    ) -> Option<gpui::WeakEntity<Shell>> {
        if self.owns_app_services(cx) {
            return None;
        }
        cx.try_global::<AppServicesOwner>()
            .and_then(|owner| owner.0.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_new_window_is_empty(
        window: gpui::WindowHandle<Shell>,
        runtime: &Entity<AppState>,
        cx: &mut gpui::TestAppContext,
    ) -> String {
        window
            .update(cx, |shell, _, cx| {
                let state = shell.state.clone();
                shell.on_state_changed(&state, cx);
                shell.ensure_workspace_sessions(cx);
                shell.sync_panel_workspace(cx);
                assert!(shell.state.read(cx).is_window_fork());
                assert_ne!(shell.state.entity_id(), runtime.entity_id());
                assert_eq!(
                    AppState::runtime_owner(&shell.state, cx).entity_id(),
                    runtime.entity_id()
                );
                assert!(shell.state.read(cx).selected_chat.is_none());
                assert_eq!(shell.chat_tabs.len(), 1);
                assert!(shell.chat_tabs[0].selected.is_none());
                assert!(shell.composer.read(cx).input.read(cx).text().is_empty());
                let layout = shell.panel_layout(cx).unwrap();
                assert_eq!(layout.panels.len(), 1);
                assert!(layout.panels[0].tabs.iter().all(|tab| matches!(
                    tab,
                    workspace_panels::PanelTab::Draft(_) | workspace_panels::PanelTab::New(_)
                )));
                shell.window_id.clone()
            })
            .unwrap()
    }

    #[gpui::test]
    fn new_window_menu_and_shortcut_preserve_source_tabs_and_unsent_input(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, source) = chat_tabs::navigation_tests::fixture(cx, true, Some(true));
        let (runtime, source_id, source_tabs) = source
            .update(cx, |shell, window, cx| {
                shell.boot_restored = true;
                shell.state.update(cx, |state, _| {
                    state.chats_synced = true;
                    state.spaces_synced = true;
                });
                shell.composer.update(cx, |composer, cx| {
                    composer.current_key = "current".into();
                    composer.input.update(cx, |input, cx| {
                        input.set_text("Keep this unsent source draft", cx)
                    });
                });
                shell.save_window_record(cx);
                window.activate_window();
                (
                    shell.state.clone(),
                    shell.window_id.clone(),
                    shell.settings.chat_tabs.clone(),
                )
            })
            .unwrap();
        let mut created_ids = std::collections::HashSet::new();
        for expected_windows in [2, 3] {
            if expected_windows == 2 {
                cx.dispatch_action(source.into(), crate::app_menus::NewWindow);
            } else {
                source
                    .update(cx, |shell, window, cx| {
                        window.focus(&shell.composer.focus_handle(cx), cx);
                    })
                    .unwrap();
                cx.update_window(source.into(), |_, window, cx| window.draw(cx).clear())
                    .unwrap();
                cx.simulate_keystrokes(source.into(), &platform_combo("mod-n"));
            }
            cx.run_until_parked();
            let windows = cx.update(|cx| cx.windows());
            assert_eq!(windows.len(), expected_windows);
            for window in windows {
                let Some(window) = window.downcast::<Shell>() else {
                    panic!("New Window must create a workspace Shell");
                };
                if window == source {
                    continue;
                }
                let id = assert_new_window_is_empty(window, &runtime, cx);
                assert_ne!(id, source_id);
                created_ids.insert(id);
            }
        }
        assert_eq!(created_ids.len(), 2);
        source
            .read_with(cx, |shell, cx| {
                assert_eq!(shell.settings.chat_tabs, source_tabs);
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("current")
                );
                assert_eq!(
                    shell.composer.read(cx).input.read(cx).text(),
                    "Keep this unsent source draft"
                );
            })
            .unwrap();
    }

    #[gpui::test]
    fn new_window_action_without_windows_uses_retained_runtime_and_starts_empty(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, source) = chat_tabs::navigation_tests::fixture(cx, true, Some(true));
        let runtime = source
            .update(cx, |shell, window, cx| {
                shell.boot_restored = true;
                shell.state.update(cx, |state, _| {
                    state.chats_synced = true;
                    state.spaces_synced = true;
                });
                shell.save_window_record(cx);
                cx.set_global(crate::ReopenState {
                    state: shell.state.clone(),
                    boot: shell.boot.clone(),
                });
                window.remove_window();
                shell.state.clone()
            })
            .unwrap();
        cx.run_until_parked();
        cx.update(|cx| {
            assert!(cx.windows().is_empty());
            assert!(
                settings::current(cx)
                    .restorable_workspace_windows()
                    .iter()
                    .any(|record| !record.chat_tabs.is_empty())
            );
            cx.dispatch_action(&crate::app_menus::NewWindow);
        });
        cx.run_until_parked();
        let windows = cx.update(|cx| cx.windows());
        assert_eq!(windows.len(), 1);
        assert_new_window_is_empty(windows[0].downcast::<Shell>().unwrap(), &runtime, cx);
    }

    #[gpui::test]
    fn attachment_sound_opt_out_refreshes_a_peer_windows_cached_controls(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, source) = chat_tabs::navigation_tests::fixture(cx, false, None);
        let (state, boot) = source
            .update(cx, |shell, _, _| (shell.state.clone(), shell.boot.clone()))
            .unwrap();
        let peer = cx.add_window(|_, cx| {
            let state = cx.new(|cx| AppState::for_window(&state, cx));
            Shell::new(state, boot, cx)
        });
        let peer_view = peer.update(cx, |_, _, cx| cx.entity()).unwrap();
        let mut visual = gpui::VisualTestContext::from_window(peer.into(), cx);
        // AnyElement owns arena-backed entity handles. Build the outlet inside
        // the test draw's arena so those handles are released after each frame.
        visual.draw(
            gpui::Point::default(),
            gpui::size(px(900.0), px(700.0)),
            |window, cx| {
                peer_view.update(cx, |shell, cx| {
                    shell.settings_outlet(SettingsSection::Notifications, window, cx)
                })
            },
        );
        let cached_page = peer
            .read_with(cx, |shell, _| {
                assert!(shell.settings.attach_sound_enabled);
                shell.notifications_page.as_ref().unwrap().entity_id()
            })
            .unwrap();
        source
            .update(cx, |shell, _, cx| {
                shell.settings.attach_sound_enabled = false;
                shell.schedule_save(cx);
            })
            .unwrap();
        peer.update(cx, |shell, _, cx| {
            shell.refresh_window_preferences(cx);
            assert!(!shell.settings.attach_sound_enabled);
            assert!(
                shell.notifications_page.is_none(),
                "a peer opt-out must invalidate the cached page before another switch can publish its old value"
            );
        })
        .unwrap();
        visual.draw(
            gpui::Point::default(),
            gpui::size(px(900.0), px(700.0)),
            |window, cx| {
                peer_view.update(cx, |shell, cx| {
                    shell.settings_outlet(SettingsSection::Notifications, window, cx)
                })
            },
        );
        peer.update(cx, |shell, _, cx| {
            assert_ne!(
                shell.notifications_page.as_ref().unwrap().entity_id(),
                cached_page
            );
            // A subsequent unrelated preference edit must keep the shared opt-out.
            shell.settings.sound_attention_enabled = false;
            shell.schedule_save(cx);
            let persisted = settings::current(cx);
            assert!(!persisted.attach_sound_enabled);
            assert!(!persisted.sound_attention_enabled);
        })
        .unwrap();
        drop(visual);
        drop(peer_view);
    }

    #[gpui::test]
    fn saved_window_forks_restore_their_own_workspace_layouts(cx: &mut gpui::TestAppContext) {
        use crate::settings::{
            SavedChatTab, SavedPanelTab, SavedWorkspacePanel, SavedWorkspacePanels,
        };

        let (_dir, source) = chat_tabs::navigation_tests::fixture(cx, false, None);
        let (runtime, boot) = source
            .update(cx, |shell, _, cx| {
                shell.state.update(cx, |state, _| {
                    state.chats_synced = true;
                    state.spaces_synced = true;
                });
                (shell.state.clone(), shell.boot.clone())
            })
            .unwrap();
        for (window_id, tabs) in [
            (
                "saved-browser-window",
                vec![SavedPanelTab::Browser {
                    owner: "workspace:saved-workspace".into(),
                    url: Some("http://127.0.0.1:1/synthetic".into()),
                }],
            ),
            (
                "saved-chat-window",
                vec![SavedPanelTab::Chat {
                    id: "current".into(),
                }],
            ),
        ] {
            let layout = SavedWorkspacePanels {
                panels: vec![SavedWorkspacePanel {
                    new_panel_target: None,
                    id: 7,
                    tabs,
                    active: 0,
                    share: 1.0,
                }],
                focused: 7,
                ..Default::default()
            };
            let record = SavedWorkspaceWindow {
                id: window_id.into(),
                chat_tabs: vec![SavedChatTab {
                    id: "saved-workspace".into(),
                    title: Some("Saved arrangement".into()),
                    selected: Some("current".into()),
                    project: Some("a".into()),
                    panel_layout: Some(layout.clone()),
                    ..Default::default()
                }],
                last_chat_id: Some("current".into()),
                project_tabs_version: 2,
                ..Default::default()
            };
            let restored = cx.add_window(|_, cx| {
                let state = cx.new(|cx| AppState::for_window(&runtime, cx));
                assert!(state.read(cx).auto_selected);
                Shell::new_for_window(state, boot.clone(), record, cx)
            });
            restored
                .update(cx, |shell, _, cx| {
                    let state = shell.state.clone();
                    shell.on_state_changed(&state, cx);
                    assert!(shell.boot_restored);
                    assert_eq!(shell.chat_tabs.len(), 1);
                    assert_eq!(shell.chat_tabs[0].id, "saved-workspace");
                    assert_eq!(
                        shell.chat_tabs[0].title.as_deref(),
                        Some("Saved arrangement")
                    );
                    assert_eq!(state.read(cx).selected_chat.as_deref(), Some("current"));
                    assert_eq!(
                        shell.saved_workspace_panels("saved-workspace", cx),
                        Some(layout)
                    );
                })
                .unwrap();
        }

        // Empty destinations still suppress recency fallback until their live
        // transfer is adopted; a source window's selection must not leak in.
        let destination = cx.add_window(|_, cx| {
            let state = cx.new(|cx| AppState::for_window(&runtime, cx));
            Shell::new_for_window(
                state,
                boot,
                SavedWorkspaceWindow {
                    id: "live-transfer-destination".into(),
                    project_tabs_version: 2,
                    ..Default::default()
                },
                cx,
            )
        });
        destination
            .update(cx, |shell, _, cx| {
                let state = shell.state.clone();
                shell.on_state_changed(&state, cx);
                assert!(state.read(cx).auto_selected);
                assert!(state.read(cx).selected_chat.is_none());
            })
            .unwrap();
    }

    #[gpui::test]
    fn window_notifications_keep_passive_baseline_for_owner_takeover(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, source) = chat_tabs::navigation_tests::fixture(cx, false, None);
        let (state, boot, mut completed) = source
            .update(cx, |shell, _, cx| {
                assert!(shell.owns_app_services(cx));
                shell.settings.sound_enabled = false;
                shell.settings.notifications_enabled = false;
                let working = harness_proto::Session {
            last_completed_peer_only: false,
                    chat_id: "current".into(),
                    device_id: "local".into(),
                    status: harness_proto::SessionStatus::Working,
                    started_at: None,
                    updated_at: Utc::now(),
                    last_completed_turn: None,
                };
                shell.state.update(cx, |state, _| {
                    state.sessions = vec![working.clone()];
                });
                (shell.state.clone(), shell.boot.clone(), working)
            })
            .unwrap();
        let peer = cx.add_window(|_, cx| {
            let state = cx.new(|cx| AppState::for_window(&state, cx));
            Shell::new(state, boot, cx)
        });
        peer.update(cx, |shell, _, cx| {
            assert!(!shell.owns_app_services(cx));
            shell.settings.sound_enabled = false;
            shell.settings.notifications_enabled = false;
            let state = shell.state.clone();
            shell.on_state_changed(&state, cx);
            assert!(
                shell.sound_prev.contains_key("current"),
                "passive windows must retain the pre-completion baseline"
            );
        })
        .unwrap();
        source
            .update(cx, |_, window, _| window.remove_window())
            .unwrap();
        completed.status = harness_proto::SessionStatus::Idle;
        completed.last_completed_turn = Some("finished-after-source-close".into());
        completed.updated_at = Utc::now();
        peer.update(cx, |shell, _, cx| {
            assert!(shell.owns_app_services(cx));
            let next = crate::sound::SessionNotificationState::new(&completed, false, Utc::now());
            assert_eq!(
                next.sound_since(&shell.sound_prev["current"], false),
                Some(crate::sound::Sound::Done),
                "the first completion after owner close must remain detectable"
            );
            let state = shell.state.clone();
            state.update(cx, |state, _| state.sessions = vec![completed]);
            shell.on_state_changed(&state, cx);
            assert_eq!(
                next.sound_since(&shell.sound_prev["current"], false),
                None,
                "the completion baseline advances after the first delivery"
            );
        })
        .unwrap();
    }

    fn record(id: &str, chat: &str) -> SavedWorkspaceWindow {
        SavedWorkspaceWindow {
            id: id.into(),
            last_chat_id: Some(chat.into()),
            ..Default::default()
        }
    }

    #[test]
    fn closed_chat_history_is_canonical_across_stale_window_saves() {
        let closed = |id: &str| crate::settings::SavedClosedChat {
            id: id.into(),
            chat_id: Some(id.into()),
            ..Default::default()
        };
        let baseline = UiSettings::default();
        let mut stale = baseline.clone();
        stale.recently_closed_chats = vec![closed("already-reopened")];
        stale.hidden_history_entries = vec!["chat:already-unhidden".into()];
        stale.sidebar_width = 310.0;
        let mut latest = baseline.clone();
        latest.recently_closed_chats = vec![closed("other-window-close")];
        latest.hidden_history_entries = vec!["draft:other-window-hide".into()];
        let merged = merge_local_preferences(&baseline, &stale, &latest).unwrap();
        assert_eq!(merged.recently_closed_chats, latest.recently_closed_chats);
        assert_eq!(merged.hidden_history_entries, latest.hidden_history_entries);
        assert_eq!(merged.sidebar_width, 310.0);

        latest.recently_closed_chats.clear();
        latest.hidden_history_entries.clear();
        let (refreshed, _) = rebase_window_preferences("main", &baseline, &stale, &latest).unwrap();
        assert!(refreshed.recently_closed_chats.is_empty(), "consumed records stay consumed");
        assert!(refreshed.hidden_history_entries.is_empty(), "unhidden entries stay visible");
    }

    #[test]
    fn window_settings_delta_preserves_peer_preferences_and_window_records() {
        let baseline = UiSettings::default();
        let mut stale = baseline.clone();
        stale.files_autosave_enabled = true;
        stale.last_chat_id = Some("stale-window-chat".into());
        stale.workspace_windows = Some(vec![record("stale", "stale-window-chat")]);

        let mut latest = baseline.clone();
        latest.sound_enabled = false;
        latest.files_autosave_delay_ms = baseline.files_autosave_delay_ms + 1000;
        latest.last_chat_id = Some("current-window-chat".into());
        latest.workspace_windows = Some(vec![record("peer", "current-window-chat")]);

        let merged = merge_local_preferences(&baseline, &stale, &latest).unwrap();

        assert!(
            !merged.sound_enabled,
            "a stale navigation save cannot restore sound"
        );
        assert!(
            merged.files_autosave_enabled,
            "the local preference edit must land"
        );
        assert_eq!(
            merged.files_autosave_delay_ms,
            latest.files_autosave_delay_ms
        );
        assert_eq!(merged.workspace_windows, latest.workspace_windows);
        assert_eq!(merged.last_chat_id, latest.last_chat_id);
    }

    #[test]
    fn window_settings_delta_applies_explicit_resets_without_resurrecting_optional_values() {
        let mut baseline = UiSettings::default();
        baseline
            .last_project_action_by_space_id
            .insert("project".into(), "build".into());
        let mut local = baseline.clone();
        local.last_project_action_by_space_id.clear();
        let mut latest = baseline.clone();
        latest.sound_enabled = false;

        let merged = merge_local_preferences(&baseline, &local, &latest).unwrap();

        assert!(merged.last_project_action_by_space_id.is_empty());
        assert!(!merged.sound_enabled);
    }

    #[test]
    fn window_settings_refresh_retains_pending_local_edits_and_own_navigation() {
        let baseline = UiSettings::default();
        let mut local = baseline.clone();
        local.last_chat_id = Some("own-chat".into());
        local.files_autosave_enabled = true;
        let mut latest = baseline.clone();
        latest.last_chat_id = Some("peer-chat".into());
        latest.sound_enabled = false;
        latest.workspace_windows = Some(vec![record("peer", "peer-chat")]);

        let (refreshed, next_baseline) =
            rebase_window_preferences("own", &baseline, &local, &latest).unwrap();

        assert!(!refreshed.sound_enabled);
        assert!(refreshed.files_autosave_enabled);
        assert!(!next_baseline.files_autosave_enabled);
        assert_eq!(refreshed.last_chat_id.as_deref(), Some("own-chat"));
        assert_eq!(next_baseline.last_chat_id.as_deref(), Some("own-chat"));
        assert_eq!(refreshed.workspace_windows, latest.workspace_windows);
        let published = merge_local_preferences(&next_baseline, &refreshed, &latest).unwrap();
        assert!(!published.sound_enabled);
        assert!(published.files_autosave_enabled);
    }
}
