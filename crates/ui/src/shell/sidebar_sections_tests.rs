//! The chat sidebar's sections, and what it costs to find a chat in a long
//! list. Runs through the whole shell, so the row order on screen and the
//! keyboard's order can't drift apart.
use super::sidebar_motion_tests::sidebar_shell;
use super::*;

fn settle(cx: &mut gpui::VisualTestContext) {
    cx.run_until_parked();
    cx.update(|window, cx| {
        window.refresh();
        let _ = window.draw(cx);
    });
}

fn set_session(
    shell: &Entity<Shell>,
    chat: &str,
    status: harness_proto::SessionStatus,
    cx: &mut gpui::VisualTestContext,
) {
    let now = Utc::now();
    shell.update(cx, |shell, cx| {
        shell.settings.sidebar_organization = SidebarOrganization::ByProject;
        shell.state.update(cx, |state, _| {
            state.sessions.push(harness_proto::Session {
                last_completed_turn: None,
                last_completed_peer_only: false,
                chat_id: chat.into(),
                device_id: "local".into(),
                status,
                started_at: Some(now),
                updated_at: now,
            });
        });
        cx.notify();
    });
    settle(cx);
}

#[test]
fn a_saved_by_status_setting_still_loads() {
    // `main`'s default. Refusing it would reset every other setting too.
    let saved: settings::UiSettings =
        serde_json::from_str(r#"{"sidebarOrganization":"byStatus","sidebarWidth":300.0}"#).unwrap();
    assert_eq!(saved.sidebar_organization, SidebarOrganization::ByStatus);
    assert_eq!(saved.sidebar_width, 300.0);
}

#[test]
fn folding_only_hides_rows_that_are_finished_and_seen() {
    let rows: Vec<usize> = (0..9).collect();
    let (visible, hidden) = spaces::fold_sidebar_group(rows, |row| *row == 7);
    assert_eq!(visible, [0, 1, 2, 3, 4, 7]);
    assert_eq!(hidden, 3);
    // Hiding one row would only swap it for a row saying so.
    let (visible, hidden) = spaces::fold_sidebar_group((0..6).collect::<Vec<_>>(), |_| false);
    assert_eq!(visible.len(), 6);
    assert_eq!(hidden, 0);
}

#[gpui::test]
fn a_chat_waiting_on_you_rises_above_the_project_list(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = sidebar_shell(cx, 4, None, 800.0);
    set_session(
        &shell,
        "chat-2",
        harness_proto::SessionStatus::AwaitingInput,
        cx,
    );
    shell.update(cx, |shell, cx| {
        assert_eq!(shell.sidebar_visible_order(cx)[0], "chat-2");
    });
    let waiting = cx.debug_bounds("session-slot-chat-2").unwrap();
    let others = cx.debug_bounds("session-slot-chat-0").unwrap();
    assert!(waiting.top() < others.top(), "it sits above the other rows");
}

#[gpui::test]
fn a_long_project_folds_and_the_keyboard_follows_it(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = sidebar_shell(cx, 12, None, 800.0);
    shell.update(cx, |shell, cx| {
        shell.settings.sidebar_organization = SidebarOrganization::ByProject;
        cx.notify();
    });
    settle(cx);
    let visible = |shell: &Entity<Shell>, cx: &mut gpui::VisualTestContext| {
        shell.update(cx, |shell, cx| shell.sidebar_visible_order(cx))
    };
    let folded = visible(&shell, cx);
    assert_eq!(folded.len(), 5);

    let fold = "sidebar-fold-project:home:local";
    let at = cx
        .debug_bounds(fold)
        .expect("a folded project offers the rest")
        .center();
    cx.simulate_mouse_move(at, None, Default::default());
    cx.simulate_click(at, Default::default());
    settle(cx);
    assert_eq!(visible(&shell, cx).len(), 12);

    // "Show less" takes its place.
    let at = cx.debug_bounds(fold).unwrap().center();
    cx.simulate_click(at, Default::default());
    settle(cx);
    assert_eq!(visible(&shell, cx), folded);
}

#[gpui::test]
fn the_open_chat_is_never_folded_away(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = sidebar_shell(cx, 12, None, 800.0);
    shell.update(cx, |shell, cx| {
        shell.settings.sidebar_organization = SidebarOrganization::ByProject;
        let last = shell.sidebar_visible_order(cx).last().unwrap().clone();
        shell.state.update(cx, |state, cx| {
            state.select_chat(Some(last.clone()), cx);
        });
        assert!(shell.sidebar_visible_order(cx).contains(&last));
    });
}
