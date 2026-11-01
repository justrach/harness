use super::*;
use tokio::sync::mpsc;

fn state(seq: u64, image_seq: u64, jpeg: Option<&str>) -> PageState {
    PageState {
        seq,
        image_seq,
        jpeg: jpeg.map(Arc::from),
        width: 390,
        height: 700,
        url: "http://localhost:3000/".into(),
        title: "Garden planner".into(),
        ..PageState::default()
    }
}

#[test]
fn a_viewer_gets_the_jpeg_only_when_the_picture_changed() {
    let mut last = 0;
    assert_eq!(viewer_event(&state(1, 0, None), "page-1", &mut last), None);
    let Some(PageEvent::Frame(first)) =
        viewer_event(&state(2, 1, Some("AAA")), "page-1", &mut last)
    else {
        panic!("a frame");
    };
    assert_eq!(first.jpeg.as_deref(), Some("AAA"));
    assert_eq!(
        (first.width, first.height, first.view_id.as_str()),
        (390, 700, "page-1")
    );
    let mut loading = state(3, 1, Some("AAA"));
    loading.loading = true;
    let Some(PageEvent::Frame(same)) = viewer_event(&loading, "page-1", &mut last) else {
        panic!("a frame");
    };
    assert_eq!(same.jpeg, None, "only the state changed");
    assert!(same.loading);
    let Some(PageEvent::Frame(next)) = viewer_event(&state(4, 2, Some("BBB")), "page-1", &mut last)
    else {
        panic!("a frame");
    };
    assert_eq!(next.jpeg.as_deref(), Some("BBB"));

    let mut ended = state(5, 2, Some("BBB"));
    ended.ended = Some("The page crashed on Studio Mac.".into());
    assert_eq!(
        viewer_event(&ended, "page-1", &mut last),
        Some(PageEvent::Ended {
            message: "The page crashed on Studio Mac.".into()
        })
    );
}

#[test]
fn frames_and_the_end_have_the_wire_shape_the_phone_reads() {
    let mut last = 0;
    let frame = viewer_event(&state(2, 1, Some("AAA")), "page-1", &mut last).unwrap();
    assert_eq!(
        serde_json::to_value(&frame).unwrap(),
        json!({
            "kind": "frame", "viewId": "page-1", "seq": 2, "jpeg": "AAA",
            "width": 390, "height": 700, "url": "http://localhost:3000/",
            "title": "Garden planner", "canGoBack": false, "canGoForward": false,
            "loading": false
        })
    );
    assert_eq!(
        serde_json::to_value(PageEvent::Ended {
            message: "gone".into()
        })
        .unwrap(),
        json!({ "kind": "ended", "message": "gone" })
    );
}

#[test]
fn only_the_engines_own_page_ids_are_looked_up() {
    assert!(check_view_id("page-1").is_ok());
    assert!(check_view_id("page-123456").is_ok());
    for bad in [
        "",
        "page-",
        "page-x",
        "1",
        "page-1/..",
        "tab-1",
        "page-1 ",
        "page-123456789012345678901",
    ] {
        assert!(check_view_id(bad).is_err(), "{bad:?}");
    }
}

#[test]
fn only_off_loopback_loads_of_the_tabs_own_frame_are_refused() {
    let paused = |url: &str, kind: &str, frame: &str| json!({ "requestId": "r1", "resourceType": kind, "frameId": frame, "request": { "url": url } });
    assert_eq!(
        refused_navigation(
            &paused("https://example.com/login", "Document", "MAIN"),
            "MAIN"
        ),
        Some("example.com".into())
    );
    assert_eq!(
        refused_navigation(
            &paused("http://localhost:3000/next", "Document", "MAIN"),
            "MAIN"
        ),
        None
    );
    assert_eq!(
        refused_navigation(
            &paused("https://example.com/embed", "Document", "CHILD"),
            "MAIN"
        ),
        None,
        "a frame inside the page loads like it would on the computer"
    );
    assert_eq!(
        refused_navigation(
            &paused("https://cdn.example.com/app.js", "Script", "MAIN"),
            "MAIN"
        ),
        None
    );
}

#[test]
fn a_failed_load_says_what_was_unreachable_and_where() {
    assert_eq!(
        navigation_notice(
            "http://localhost:3000/",
            "net::ERR_CONNECTION_REFUSED",
            "Studio Mac"
        ),
        "Nothing is running at localhost:3000 on Studio Mac."
    );
    assert_eq!(
        navigation_notice("http://localhost/", "net::ERR_TIMED_OUT", "Studio Mac"),
        "localhost didn't load on Studio Mac (net::ERR_TIMED_OUT)."
    );
}

#[tokio::test]
async fn without_a_browser_the_watch_says_which_ones_it_needs() {
    let view = LocalhostView::build(
        "Studio Mac".into(),
        Duration::from_millis(200),
        Box::new(|| None),
        Transport::Pipe,
    );
    let request = |url: &str| WatchRequest {
        url: url.into(),
        width: 390.0,
        height: 700.0,
        ..WatchRequest::default()
    };
    let error = view.watch(request("localhost:3000")).await.err().unwrap();
    assert_eq!(
        error,
        "Viewing localhost on your phone needs Google Chrome, Microsoft Edge, Brave or Chromium on Studio Mac."
    );
    let refused = view
        .watch(request("https://example.com"))
        .await
        .err()
        .unwrap();
    assert!(refused.contains("Only pages on this computer"), "{refused}");
    let bad_id = view
        .watch(WatchRequest {
            view_id: Some("../x".into()),
            ..request("localhost:3000")
        })
        .await
        .err()
        .unwrap();
    assert!(bad_id.contains("not a page id"), "{bad_id}");
    let closed = view.input("page-9", PageInput::Reload).await.unwrap_err();
    assert!(closed.contains("closed"), "{closed}");
}

/// A tab with no browser behind it: commands go nowhere, state is real.
fn fake_tab() -> (
    Arc<Tab>,
    mpsc::UnboundedReceiver<String>,
    mpsc::UnboundedSender<String>,
) {
    let (tx, sent) = mpsc::unbounded_channel();
    let (replies, rx) = mpsc::unbounded_channel();
    let (state, _) = watch::channel(Arc::new(PageState::default()));
    let tab = Arc::new(Tab {
        id: "page-1".into(),
        opened_at: "http://localhost:3000/".into(),
        target_id: "MAIN".into(),
        session_id: "S".into(),
        cdp: Cdp::start(tx, rx),
        device: "Studio Mac".into(),
        state,
        settings: Mutex::new(Settings {
            viewport: Viewport::default(),
            quality: 70,
        }),
        viewers: Mutex::new(HashMap::new()),
        idle_since: Mutex::new(None),
        casting: AtomicBool::new(true),
    });
    (tab, sent, replies)
}

#[tokio::test]
async fn a_viewer_gets_the_newest_frame_at_its_own_rate_and_leaving_stops_the_cast() {
    let (tab, mut sent, _replies) = fake_tab();
    lock(&tab.viewers).insert(1, 4);
    let guard = ViewerGuard {
        tab: tab.clone(),
        viewer: 1,
        inner: Weak::new(),
    };
    tab.publish_image("frame1", Some(390), Some(700));
    let mut events = viewer_events(tab.state.subscribe(), tab.id.clone(), 4, guard);
    let start = Instant::now();
    let Some(PageEvent::Frame(first)) = events.next().await else {
        panic!("a frame")
    };
    assert_eq!(
        first.jpeg.as_deref(),
        Some("frame1"),
        "the current frame at once"
    );
    for n in 2..=11 {
        tab.publish_image(&format!("frame{n}"), None, None);
    }
    let Some(PageEvent::Frame(newest)) = events.next().await else {
        panic!("a frame")
    };
    assert_eq!(newest.jpeg.as_deref(), Some("frame11"), "only the newest");
    assert!(start.elapsed() >= Duration::from_millis(250), "4 a second");

    drop(events);
    assert!(lock(&tab.viewers).is_empty());
    assert!(lock(&tab.idle_since).is_some());
    let stop: Value = serde_json::from_str(&sent.recv().await.unwrap()).unwrap();
    assert_eq!(stop["method"], "Page.stopScreencast");
    assert_eq!(stop["sessionId"], "S");
}

#[tokio::test]
async fn a_viewer_is_told_when_the_page_ends() {
    let (tab, _sent, _replies) = fake_tab();
    lock(&tab.viewers).insert(1, 30);
    let guard = ViewerGuard {
        tab: tab.clone(),
        viewer: 1,
        inner: Weak::new(),
    };
    tab.publish_image("frame1", None, None);
    let mut events = viewer_events(tab.state.subscribe(), tab.id.clone(), 30, guard);
    assert!(matches!(events.next().await, Some(PageEvent::Frame(_))));
    tab.end("The page crashed on Studio Mac.".into());
    assert_eq!(
        events.next().await,
        Some(PageEvent::Ended {
            message: "The page crashed on Studio Mac.".into()
        })
    );
    assert_eq!(events.next().await, None);
}

#[tokio::test]
async fn the_fastest_viewer_sets_the_pace() {
    let (tab, _sent, _replies) = fake_tab();
    assert_eq!(tab.fps(), 15, "the default with nobody watching");
    lock(&tab.viewers).insert(1, 6);
    lock(&tab.viewers).insert(2, 20);
    assert_eq!(tab.fps(), 20);
}

/// Real browser, real page: serves a synthetic page on 127.0.0.1, watches it,
/// taps, types, and checks a page-initiated load off loopback is refused.
/// Needs Chrome, Edge, Brave or Chromium:
/// `cargo test -p harness-engine --lib localhost_view::tests::real_browser -- --ignored`
#[tokio::test]
#[ignore = "needs a Chromium-family browser on this computer"]
async fn real_browser_streams_a_local_page_and_takes_input() {
    for transport in [Transport::Pipe, Transport::Port] {
        real_browser_round_trip(transport).await;
    }
}

const GARDEN_PAGE: &str = r#"<!doctype html>
<html><head><title>Garden planner</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { margin: 0; font: 20px system-ui; background: #f4f1e8; }
  #water { position: absolute; left: 0; top: 0; width: 390px; height: 200px; font-size: 28px; }
  #plant { position: absolute; left: 0; top: 220px; width: 390px; height: 60px; font-size: 22px; }
  #away { position: absolute; left: 0; top: 300px; width: 390px; height: 60px; }
  .watered { background: #3a7d44 !important; }
</style></head>
<body>
  <button id="water">Water the tomatoes</button>
  <form id="f"><input id="plant" placeholder="Plant name"></form>
  <button id="away">Leave</button>
  <div style="height: 3000px"></div>
  <script>
    document.getElementById('water').addEventListener('click', () => {
      document.body.classList.add('watered');
      location.hash = 'watered';
    });
    document.getElementById('f').addEventListener('submit', (e) => {
      e.preventDefault();
      location.hash = 'planted-' + encodeURIComponent(document.getElementById('plant').value);
    });
    document.getElementById('away').addEventListener('click', () => {
      location.href = 'http://192.0.2.1/elsewhere';
    });
    addEventListener('scroll', () => { if (scrollY > 100) history.replaceState(null, '', '#scrolled'); });
  </script>
</body></html>"#;

async fn serve_garden_page() -> u16 {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                return;
            };
            tokio::spawn(async move {
                let mut buf = [0u8; 4096];
                let _ = socket.read(&mut buf).await;
                let response = format!(
                    "HTTP/1.1 200 OK\r\ncontent-type: text/html\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{GARDEN_PAGE}",
                    GARDEN_PAGE.len()
                );
                let _ = socket.write_all(response.as_bytes()).await;
            });
        }
    });
    port
}

async fn frame_where(
    events: &mut BoxStream<'static, PageEvent>,
    what: &str,
    check: impl Fn(&PageFrame) -> bool,
) -> PageFrame {
    let found = tokio::time::timeout(Duration::from_secs(20), async {
        while let Some(event) = events.next().await {
            match event {
                PageEvent::Frame(frame) if check(&frame) => return frame,
                PageEvent::Frame(_) => {}
                PageEvent::Ended { message } => panic!("ended: {message}"),
            }
        }
        panic!("stream ended waiting for {what}");
    })
    .await;
    found.unwrap_or_else(|_| panic!("timed out waiting for {what}"))
}

async fn real_browser_round_trip(transport: Transport) {
    let port = serve_garden_page().await;
    let view = LocalhostView::build(
        "Test computer".into(),
        Duration::from_secs(5),
        Box::new(browser::find),
        transport,
    );
    let mut events = view
        .watch(WatchRequest {
            url: format!("0.0.0.0:{port}/"),
            width: 390.0,
            height: 700.0,
            scale: Some(2.0),
            fps: Some(30),
            ..WatchRequest::default()
        })
        .await
        .expect("watch");
    let first = frame_where(&mut events, "the loaded page", |f| {
        f.title == "Garden planner" && !f.loading
    })
    .await;
    assert_eq!(first.url, format!("http://localhost:{port}/"));
    assert_eq!((first.width, first.height), (390, 700));
    let view_id = first.view_id.clone();

    // A second viewer of the same address shares the page.
    let mut second = view
        .watch(WatchRequest {
            url: format!("http://0.0.0.0:{port}/"),
            width: 390.0,
            height: 700.0,
            ..WatchRequest::default()
        })
        .await
        .unwrap();
    let shared = frame_where(&mut second, "the shared page", |f| f.jpeg.is_some()).await;
    assert_eq!(shared.view_id, view_id);
    let jpeg = base64::Engine::decode(
        &base64::engine::general_purpose::STANDARD,
        shared.jpeg.unwrap(),
    )
    .unwrap();
    assert_eq!(&jpeg[..3], &[0xFF, 0xD8, 0xFF], "a JPEG");
    // To look at what the browser drew: LOCALHOST_VIEW_FRAME_OUT=/tmp/frame.jpg
    if let Some(out) = std::env::var_os("LOCALHOST_VIEW_FRAME_OUT") {
        std::fs::write(out, &jpeg).unwrap();
    }
    drop(second);
    assert_eq!(view.tab_count(), 1);

    view.input(&view_id, PageInput::Tap { x: 195.0, y: 100.0 })
        .await
        .unwrap();
    frame_where(&mut events, "the tap's effect", |f| {
        f.url.ends_with("#watered")
    })
    .await;

    view.input(&view_id, PageInput::Tap { x: 195.0, y: 250.0 })
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    view.input(
        &view_id,
        PageInput::Text {
            text: "Basil".into(),
        },
    )
    .await
    .unwrap();
    view.input(
        &view_id,
        PageInput::Key {
            name: "Enter".into(),
        },
    )
    .await
    .unwrap();
    frame_where(&mut events, "the typed text", |f| {
        f.url.ends_with("#planted-Basil")
    })
    .await;
    let back = frame_where(&mut events, "history", |f| f.can_go_back).await;
    assert!(!back.can_go_forward);

    view.input(
        &view_id,
        PageInput::Scroll {
            x: 195.0,
            y: 500.0,
            dx: 0.0,
            dy: 600.0,
        },
    )
    .await
    .unwrap();
    frame_where(&mut events, "the scroll", |f| f.url.ends_with("#scrolled")).await;
    view.input(
        &view_id,
        PageInput::Scroll {
            x: 195.0,
            y: 500.0,
            dx: 0.0,
            dy: -5000.0,
        },
    )
    .await
    .unwrap();

    assert!(
        view.input(
            &view_id,
            PageInput::Navigate {
                url: "https://example.com".into()
            }
        )
        .await
        .is_err(),
        "the phone can't send the page off loopback"
    );
    tokio::time::sleep(Duration::from_millis(300)).await;
    view.input(&view_id, PageInput::Tap { x: 195.0, y: 330.0 })
        .await
        .unwrap();
    let refused = frame_where(&mut events, "the refused load", |f| f.notice.is_some()).await;
    assert!(
        refused.notice.as_deref().unwrap().contains("192.0.2.1"),
        "{:?}",
        refused.notice
    );

    view.input(&view_id, PageInput::Back).await.unwrap();
    view.input(
        &view_id,
        PageInput::Resize {
            width: 430.0,
            height: 800.0,
            scale: Some(2.0),
        },
    )
    .await
    .unwrap();
    frame_where(&mut events, "the new size", |f| {
        f.width == 430 && f.height == 800
    })
    .await;

    view.shutdown().await;
    let ended = tokio::time::timeout(Duration::from_secs(5), async {
        while let Some(event) = events.next().await {
            if let PageEvent::Ended { message } = event {
                return message;
            }
        }
        String::new()
    })
    .await
    .unwrap();
    assert!(ended.contains("stopped"), "{ended}");
}
