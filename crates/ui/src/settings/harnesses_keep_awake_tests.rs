use super::*;
use crate::state::EngineHandle;
use gpui::TestAppContext;
use serde_json::{Value, json};
use tokio::sync::mpsc;

fn fixture(
    cx: &mut TestAppContext,
) -> (
    Entity<HarnessesPage>,
    mpsc::Receiver<String>,
    mpsc::Sender<String>,
) {
    let (out, requests) = mpsc::channel(32);
    let (replies, inbound) = mpsc::channel(32);
    let engine = EngineHandle::from_test_client(harness_rpc::RpcClient::new(out, inbound));
    let state = cx.new(|_| AppState::new());
    // Construct without an engine so this test only probes the setting's RPCs.
    let page = cx.new(|cx| HarnessesPage::new(state.clone(), cx));
    state.update(cx, |state, _| state.set_test_engine(engine));
    (page, requests, replies)
}

fn request(cx: &mut TestAppContext, requests: &mut mpsc::Receiver<String>) -> Value {
    cx.run_until_parked();
    serde_json::from_str(&requests.try_recv().expect("setting sends its request")).unwrap()
}

fn reply(
    runtime: &tokio::runtime::Runtime,
    cx: &mut TestAppContext,
    replies: &mpsc::Sender<String>,
    value: Value,
) {
    runtime.block_on(async {
        replies.send(value.to_string()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(1), async {
            while replies.capacity() < replies.max_capacity() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("RPC client consumes reply");
    });
    cx.run_until_parked();
}

#[gpui::test]
fn keep_awake_settings_target_the_selected_computer_and_preserve_failed_saves(
    cx: &mut TestAppContext,
) {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let _guard = runtime.enter();
    let (page, mut requests, replies) = fixture(cx);
    page.update(cx, |page, cx| {
        page.target_device = Some("studio-computer".into());
        page.load_keep_awake(None, cx);
    });
    let get = request(cx, &mut requests);
    assert_eq!(get["method"], methods::GET_KEEP_AWAKE);
    assert_eq!(get["params"], json!({"targetDeviceId": "studio-computer"}));
    reply(
        &runtime,
        cx,
        &replies,
        json!({"id": get["id"], "ok": {"enabled": false, "supported": true}}),
    );
    page.update(cx, |page, cx| {
        page.load_keep_awake(Some(true), cx);
        page.load_keep_awake(Some(true), cx); // A held key/second click must not duplicate it.
        assert!(page.keep_awake_saving);
    });
    let set = request(cx, &mut requests);
    assert_eq!(set["method"], methods::SET_KEEP_AWAKE);
    assert_eq!(
        set["params"],
        json!({"enabled": true, "targetDeviceId": "studio-computer"})
    );
    assert!(requests.try_recv().is_err());
    reply(
        &runtime,
        cx,
        &replies,
        json!({"id": set["id"], "err": "remote computer disconnected"}),
    );
    page.update(cx, |page, _| {
        assert!(matches!(
            page.keep_awake,
            Loadable::Ready(KeepAwake {
                enabled: false,
                supported: true
            })
        ));
        assert!(!page.keep_awake_saving);
        assert!(
            page.error
                .as_deref()
                .unwrap()
                .contains("remote computer disconnected")
        );
    });
}

#[gpui::test]
fn keep_awake_settings_ignore_an_old_device_reply_and_gate_unsupported_hosts(
    cx: &mut TestAppContext,
) {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let _guard = runtime.enter();
    let (page, mut requests, replies) = fixture(cx);
    page.update(cx, |page, cx| {
        page.target_device = Some("old-computer".into());
        page.load_keep_awake(None, cx);
    });
    let old = request(cx, &mut requests);
    // Exercise the response guard independently of normal task cancellation.
    page.update(cx, |page, _| {
        page.target_device = Some("new-computer".into())
    });
    reply(
        &runtime,
        cx,
        &replies,
        json!({"id": old["id"], "ok": {"enabled": true, "supported": true}}),
    );
    page.update(cx, |page, cx| {
        assert!(matches!(page.keep_awake, Loadable::Loading));
        page.load_keep_awake(None, cx);
    });
    let current = request(cx, &mut requests);
    assert_eq!(current["params"]["targetDeviceId"], "new-computer");
    reply(
        &runtime,
        cx,
        &replies,
        json!({"id": current["id"], "ok": {"enabled": false, "supported": false}}),
    );
    page.update(cx, |page, cx| {
        page.load_keep_awake(Some(true), cx);
        assert!(!page.keep_awake_saving);
    });
    cx.run_until_parked();
    assert!(
        requests.try_recv().is_err(),
        "unsupported devices cannot be enabled"
    );
    page.update(cx, |page, cx| page.load_keep_awake(None, cx));
    let legacy = request(cx, &mut requests);
    reply(
        &runtime,
        cx,
        &replies,
        json!({"id": legacy["id"], "err": "unknown method GetKeepAwake"}),
    );
    page.update(cx, |page, cx| {
        assert!(matches!(page.keep_awake, Loadable::Error(_)));
        page.load_keep_awake(Some(true), cx);
        assert!(!page.keep_awake_saving);
    });
    cx.run_until_parked();
    assert!(
        requests.try_recv().is_err(),
        "old engines never receive the setter"
    );
}
