//! Shared native input and mock-engine helpers for close/recovery tests.
use super::*;

pub(in crate::shell) fn mutations(
    requests: &mut tokio::sync::mpsc::Receiver<String>,
) -> Vec<serde_json::Value> {
    let mut result = Vec::new();
    while let Ok(request) = requests.try_recv() {
        let request: serde_json::Value = serde_json::from_str(&request).unwrap();
        if request["method"] == methods::MUTATE {
            result.push(request);
        }
    }
    result
}

pub(in crate::shell) fn reply(
    runtime: &tokio::runtime::Runtime,
    replies: &tokio::sync::mpsc::Sender<String>,
    request: &serde_json::Value,
) {
    runtime.block_on(async {
        replies
            .send(serde_json::json!({"id": request["id"], "ok": {}}).to_string())
            .await
            .unwrap();
        while replies.capacity() < replies.max_capacity() {
            tokio::task::yield_now().await;
        }
    });
}

pub(in crate::shell) fn press(
    cx: &mut gpui::TestAppContext,
    window: gpui::WindowHandle<Shell>,
    combo: &str,
) {
    let combo = match combo {
        "mod-shift-t" => crate::settings::ShortcutId::ReopenClosedTab.default_combo(),
        "mod-alt-w" => crate::settings::ShortcutId::CloseTabWithoutArchiving.default_combo(),
        "mod-t" => crate::settings::ShortcutId::NewSession.default_combo(),
        "mod-w" if !cfg!(target_os = "macos") => "ctrl-shift-w",
        "mod-d" if !cfg!(target_os = "macos") => "ctrl-shift-o",
        "mod-shift-d" if !cfg!(target_os = "macos") => "ctrl-shift-e",
        combo => combo,
    };
    let keystroke = gpui::Keystroke::parse(&platform_combo(combo)).unwrap();
    cx.update_window(window.into(), |_, window, cx| {
        window.activate_window();
        window.draw(cx).clear();
        window.dispatch_event(
            gpui::PlatformInput::KeyDown(gpui::KeyDownEvent {
                keystroke: keystroke.clone(),
                is_held: false,
                prefer_character_input: false,
            }),
            cx,
        );
        window.dispatch_event(
            gpui::PlatformInput::KeyUp(gpui::KeyUpEvent { keystroke }),
            cx,
        );
    })
    .unwrap();
    cx.run_until_parked();
}
