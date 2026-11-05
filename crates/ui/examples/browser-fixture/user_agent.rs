//! Native HTTP/JavaScript identity and cookie continuity; no real credentials.
use super::*;
use gpui::{AnyWindowHandle, Entity, WindowHandle};
use serde_json::{Value, json};
use std::{
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};

const BARE_WEBKIT: &str =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)";
const GOOGLE: &str = "https://www.google.com/search?q=web+browsers";

#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    method: String,
    path: String,
    user_agent: String,
    cookie: String,
}

struct Server {
    origin: String,
    requests: Arc<Mutex<Vec<Request>>>,
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Server {
    fn start() -> anyhow::Result<Self> {
        let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
        listener.set_nonblocking(true)?;
        let origin = format!("http://{}", listener.local_addr()?);
        let requests = Arc::new(Mutex::new(Vec::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let recorded = requests.clone();
        let stopped = stop.clone();
        let thread = std::thread::spawn(move || {
            while !stopped.load(Ordering::Relaxed) {
                let Ok((mut stream, _)) = listener.accept() else {
                    std::thread::sleep(Duration::from_millis(5));
                    continue;
                };
                let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
                let mut bytes = Vec::new();
                let mut chunk = [0; 2048];
                while bytes.len() < 32 * 1024 && !bytes.windows(4).any(|w| w == b"\r\n\r\n") {
                    let read = stream.read(&mut chunk).unwrap_or(0);
                    if read == 0 {
                        break;
                    }
                    bytes.extend_from_slice(&chunk[..read]);
                }
                let text = String::from_utf8_lossy(&bytes);
                let mut lines = text.lines();
                let mut first = lines.next().unwrap_or_default().split_whitespace();
                let method = first.next().unwrap_or_default().to_owned();
                let path = first.next().unwrap_or_default().to_owned();
                let mut agent = String::new();
                let mut cookie = String::new();
                let mut content_length = 0;
                for line in lines {
                    if line.is_empty() {
                        break;
                    }
                    if let Some((name, value)) = line.split_once(':') {
                        if name.eq_ignore_ascii_case("user-agent") {
                            agent = value.trim().to_owned();
                        }
                        if name.eq_ignore_ascii_case("cookie") {
                            cookie = value.trim().to_owned();
                        }
                        if name.eq_ignore_ascii_case("content-length") {
                            content_length = value.trim().parse::<usize>().unwrap_or(0).min(4096);
                        }
                    }
                }
                drop(text);
                // Drain the small synthetic POST body before closing the
                // connection, so the 303 cannot race an unread TCP payload.
                let header_end = bytes
                    .windows(4)
                    .position(|w| w == b"\r\n\r\n")
                    .map_or(bytes.len(), |n| n + 4);
                while bytes.len() < header_end + content_length {
                    let read = stream.read(&mut chunk).unwrap_or(0);
                    if read == 0 {
                        break;
                    }
                    bytes.extend_from_slice(&chunk[..read]);
                }
                let route = path.split('?').next().unwrap_or_default();
                let known = matches!(
                    route,
                    "/ordinary" | "/redirect" | "/login" | "/session" | "/account" | "/next"
                );
                // Ignore daemon HEAD discovery and the browser's favicon. Only
                // the explicit local fixture routes enter the identity report.
                if known && matches!(method.as_str(), "GET" | "POST") {
                    recorded.lock().unwrap().push(Request {
                        method: method.clone(),
                        path: path.clone(),
                        user_agent: agent.clone(),
                        cookie,
                    });
                }
                let (status, headers, title) = match route {
                    "/redirect" => (
                        "302 Found",
                        "Location: /login\r\nSet-Cookie: fixture_public=shared; Path=/; SameSite=Lax\r\nSet-Cookie: fixture_prelogin=kept; Path=/; HttpOnly; SameSite=Lax\r\n",
                        "",
                    ),
                    "/session" if method == "POST" => (
                        "303 See Other",
                        "Location: /account\r\nSet-Cookie: fixture_session=kept; Path=/; HttpOnly; SameSite=Lax\r\n",
                        "",
                    ),
                    "/ordinary" => ("200 OK", "", "UA fixture ordinary"),
                    "/login" => ("200 OK", "", "UA fixture login"),
                    "/account" => ("200 OK", "", "UA fixture account"),
                    "/next" => ("200 OK", "", "UA fixture next"),
                    _ => ("204 No Content", "", ""),
                };
                let body = if title.is_empty() {
                    String::new()
                } else {
                    html(title, &agent, route == "/login")
                };
                let _ = write!(
                    stream,
                    "HTTP/1.1 {status}\r\n{headers}Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
            }
        });
        Ok(Self {
            origin,
            requests,
            stop,
            thread: Some(thread),
        })
    }

    fn recorded(&self) -> Vec<Request> {
        self.requests.lock().unwrap().clone()
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn html(title: &str, agent: &str, login: bool) -> String {
    let agent = serde_json::to_string(agent)
        .unwrap()
        .replace('<', "\\u003c");
    let form = if login {
        "<form id=fixture-login method=post action=/session><input type=hidden name=fixture value=synthetic><button>Continue the local fixture</button></form>"
    } else {
        "<a id=next href=/next>Navigate to the next fixture page</a>"
    };
    format!(
        r#"<!doctype html><meta charset=utf-8><title>{title}</title>
<style>body{{margin:0;padding:32px;background:#f5f1e8;color:#2d3e35;font:15px/1.6 system-ui}}h1{{font:36px Georgia}}code{{display:block;overflow-wrap:anywhere;padding:14px;background:#fff;border:1px solid #d3d7cd;border-radius:8px;font:12px/1.6 monospace}}button,a{{display:inline-block;margin-top:20px;padding:10px;color:inherit}}p{{max-width:600px}}</style>
<h1>Native browser identity</h1><p>{title}. This isolated local fixture uses no real account or credentials.</p>
<p>HTTP User-Agent</p><code id=http-agent></code><p>navigator.userAgent</p><code id=js-agent></code>{form}
<script>window.fixtureHttpUserAgent={agent};document.querySelector('#http-agent').textContent=window.fixtureHttpUserAgent;document.querySelector('#js-agent').textContent=navigator.userAgent;</script>"#
    )
}

async fn wait_title(
    page: &Entity<browser::BrowserSurface>,
    expected: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    loop {
        let state = page.read_with(cx, |page, _| page.page.clone());
        anyhow::ensure!(
            state.error.is_none(),
            "native page failed: {:?}",
            state.error
        );
        if state.title == expected && !state.loading {
            return Ok(());
        }
        anyhow::ensure!(
            std::time::Instant::now() < deadline,
            "expected {expected:?}, got {state:?}"
        );
        pause(cx, 40).await;
    }
}

async fn read_json(
    page: &Entity<browser::BrowserSurface>,
    expression: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<Value> {
    static SERIAL: AtomicU64 = AtomicU64::new(0);
    let prefix = format!("ua-fixture-{}:", SERIAL.fetch_add(1, Ordering::Relaxed));
    page.read_with(cx, |page, _| {
        page.fixture_eval(&format!(
            "document.title={prefix:?}+JSON.stringify({expression})"
        ))
    });
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        let title = page.read_with(cx, |page, _| page.page.title.clone());
        if let Some(json) = title.strip_prefix(&prefix) {
            return Ok(serde_json::from_str(json)?);
        }
        anyhow::ensure!(
            std::time::Instant::now() < deadline,
            "JavaScript identity report did not arrive: {title:?}"
        );
        pause(cx, 30).await;
    }
}

async fn identity(
    page: &Entity<browser::BrowserSurface>,
    cx: &mut AsyncApp,
) -> anyhow::Result<Value> {
    let result = read_json(page,"({httpUserAgent:window.fixtureHttpUserAgent,navigatorUserAgent:navigator.userAgent,cookie:document.cookie,url:location.href})",cx).await?;
    anyhow::ensure!(
        result["httpUserAgent"] == result["navigatorUserAgent"],
        "native HTTP and navigator identity disagree: {result}"
    );
    let agent = result["navigatorUserAgent"].as_str().unwrap_or_default();
    anyhow::ensure!(
        agent.contains("Version/") && agent.contains("Safari/") && !agent.contains("Chrome/"),
        "ordinary page lacks Safari-compatible identity: {agent}"
    );
    Ok(result)
}

async fn navigate(
    window: WindowHandle<shell::Shell>,
    page: &Entity<browser::BrowserSurface>,
    url: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    window.update(cx, |_, window, cx| {
        page.update(cx, |page, cx| page.navigate(url, window, cx))
    })?;
    Ok(())
}

async fn screenshot(
    window: WindowHandle<shell::Shell>,
    output: &Path,
    name: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let path = output.join(format!("{name}.png"));
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    loop {
        let id = AnyWindowHandle::from(window)
            .update(cx, |_, window, cx| -> anyhow::Result<_> {
                use raw_window_handle::{HasWindowHandle, RawWindowHandle};
                window.draw(cx).clear();
                let RawWindowHandle::AppKit(raw) = HasWindowHandle::window_handle(window)?.as_raw()
                else {
                    anyhow::bail!("expected an AppKit fixture window")
                };
                let view = unsafe { &*raw.ns_view.as_ptr().cast::<objc2_app_kit::NSView>() };
                Ok(view
                    .window()
                    .map(|window| window.windowNumber().to_string()))
            })??
            .ok_or_else(|| anyhow::anyhow!("fixture has no native window"))?;
        let path = path.clone();
        let captured = cx
            .background_executor()
            .spawn(async move {
                std::process::Command::new("/usr/sbin/screencapture")
                    .args(["-x", "-o", "-l", &id])
                    .arg(path)
                    .output()
            })
            .await?;
        if captured.status.success() {
            return Ok(());
        }
        anyhow::ensure!(
            std::time::Instant::now() < deadline,
            "native capture {name} failed: {}",
            String::from_utf8_lossy(&captured.stderr)
        );
        pause(cx, 100).await;
    }
}

async fn google(
    window: WindowHandle<shell::Shell>,
    page: &Entity<browser::BrowserSurface>,
    output: &Path,
    cx: &mut AsyncApp,
) -> anyhow::Result<Value> {
    let native = page.read_with(cx, |page, _| page.fixture_native_identity());
    anyhow::ensure!(native.is_some(), "Google A/B has no native WebKit view");
    let mut cases = vec![];
    for (name, override_agent) in [
        ("google-bare-webkit", Some(BARE_WEBKIT)),
        ("google-safari-compatible", None),
    ] {
        page.read_with(cx, |page, _| page.fixture_set_user_agent(override_agent));
        navigate(window, page, GOOGLE, cx).await?;
        let deadline = std::time::Instant::now() + Duration::from_secs(30);
        loop {
            let state = page.read_with(cx, |page, _| page.page.clone());
            anyhow::ensure!(
                state.error.is_none(),
                "public Google navigation failed: {:?}",
                state.error
            );
            if !state.loading
                && !state.title.is_empty()
                && state
                    .url
                    .as_deref()
                    .is_some_and(|url| url.contains("google."))
            {
                break;
            }
            anyhow::ensure!(
                std::time::Instant::now() < deadline,
                "public Google did not finish: {state:?}"
            );
            pause(cx, 100).await;
        }
        pause(cx, 1000).await;
        screenshot(window, output, name, cx).await?;
        let metadata=read_json(page,r#"({title:document.title,url:location.href,userAgent:navigator.userAgent,scripts:document.scripts.length,externalScripts:document.querySelectorAll('script[src]').length,queryControl:document.querySelector('textarea[name=q],input[name=q]')?.tagName??null,resultHeadings:document.querySelectorAll('a h3').length,mainElement:!!document.querySelector('main'),searchContainer:!!document.getElementById('search'),rsoContainer:!!document.getElementById('rso'),bodyClasses:document.body.className.slice(0,1000),viewport:[innerWidth,innerHeight],cookieNames:document.cookie.split(';').map(value=>value.split('=')[0].trim()).filter(Boolean).sort()})"#,cx).await?;
        let agent = metadata["userAgent"].as_str().unwrap_or_default();
        if override_agent.is_some() {
            anyhow::ensure!(
                agent == BARE_WEBKIT,
                "Google baseline did not use the exact prior identity"
            )
        } else {
            anyhow::ensure!(
                agent.contains("Version/") && agent.contains("Safari/"),
                "Google after page did not use the production identity"
            )
        }
        anyhow::ensure!(
            page.read_with(cx, |page, _| page.fixture_native_identity()) == native,
            "Google A/B recreated WebKit"
        );
        cases.push(
            json!({"capture":format!("{name}.png"),"sameNativePage":true,"metadata":metadata}),
        );
    }
    let result = json!({"query":GOOGLE,"scope":"Same live WebKit view/profile and viewport; no login or consent automation. Public server responses may vary independently of user agent.","cases":cases});
    std::fs::write(
        output.join("google-user-agent-comparison.json"),
        serde_json::to_vec_pretty(&result)?,
    )?;
    Ok(result)
}

async fn run(
    window: WindowHandle<shell::Shell>,
    output: &Path,
    cx: &mut AsyncApp,
) -> anyhow::Result<Value> {
    let server = Server::start()?;
    let (first_id, first) = window.update(cx, |shell, window, cx| {
        shell.fixture_open_browser(Some(format!("{}/ordinary", server.origin)), window, cx)
    })?;
    wait_title(&first, "UA fixture ordinary", cx).await?;
    let ordinary = identity(&first, cx).await?;
    let expected_agent = ordinary["navigatorUserAgent"].as_str().unwrap().to_owned();
    navigate(window, &first, &format!("{}/redirect", server.origin), cx).await?;
    wait_title(&first, "UA fixture login", cx).await?;
    let login = identity(&first, cx).await?;
    first.read_with(cx, |page, _| {
        page.fixture_eval("document.querySelector('#fixture-login button').click()")
    });
    wait_title(&first, "UA fixture account", cx).await?;
    let account = identity(&first, cx).await?;
    first.read_with(cx, |page, _| {
        page.fixture_eval("document.title='UA fixture account'")
    });
    wait_title(&first, "UA fixture account", cx).await?;
    screenshot(window, output, "browser-user-agent-account", cx).await?;
    first.read_with(cx, |page, _| {
        page.fixture_eval("document.querySelector('#next').click()")
    });
    wait_title(&first, "UA fixture next", cx).await?;
    let next = identity(&first, cx).await?;
    let (second_id, second) = window.update(cx, |shell, window, cx| {
        shell.fixture_open_browser(
            Some(format!("{}/account?tab=second", server.origin)),
            window,
            cx,
        )
    })?;
    wait_title(&second, "UA fixture account", cx).await?;
    let second_report = identity(&second, cx).await?;
    anyhow::ensure!(
        second_report["cookie"]
            .as_str()
            .is_some_and(|cookie| cookie.contains("fixture_public=shared")),
        "second ordinary tab lost the shared fixture cookie"
    );
    let recorded = server.recorded();
    for request in &recorded {
        anyhow::ensure!(
            request.user_agent == expected_agent,
            "HTTP identity changed during native navigation: {} {}",
            request.method,
            request.path
        )
    }
    for route in ["/login", "/session", "/account", "/account?tab=second"] {
        let request = recorded
            .iter()
            .find(|request| request.path == route)
            .ok_or_else(|| anyhow::anyhow!("missing native request {route}"))?;
        anyhow::ensure!(
            request.cookie.contains("fixture_prelogin=kept"),
            "redirect/login-shaped navigation lost its HttpOnly cookie at {route}"
        );
        if route.starts_with("/account") {
            anyhow::ensure!(
                request.cookie.contains("fixture_session=kept"),
                "session-shaped cookie did not survive at {route}"
            )
        }
    }
    let (preview_id, preview) = window.update(cx, |shell, window, cx| {
        shell.fixture_open_browser(None, window, cx)
    })?;
    window.update(cx,|_,window,cx|preview.update(cx,|page,cx|page.fixture_document("<h1>Isolated preview identity</h1><script>parent.postMessage('preview:ua:'+navigator.userAgent,'*')</script>",window,cx)))?.map_err(anyhow::Error::msg)?;
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    let isolated = loop {
        let state = preview.read_with(cx, |page, _| page.page.clone());
        anyhow::ensure!(
            state.error.is_none(),
            "isolated preview failed: {:?}",
            state.error
        );
        if let Some(agent) = state.title.strip_prefix("preview:ua:") {
            break agent.to_owned();
        }
        anyhow::ensure!(
            std::time::Instant::now() < deadline,
            "isolated preview identity was not relayed: {state:?}"
        );
        pause(cx, 40).await;
    };
    anyhow::ensure!(
        !isolated.contains("Version/")
            && !isolated.contains("Safari/")
            && isolated != expected_agent,
        "isolated HTML preview inherited the ordinary-page identity: {isolated}"
    );
    window.update(cx, |shell, window, cx| {
        shell.fixture_close_browser(preview_id, window, cx);
        shell.fixture_close_browser(second_id, window, cx);
        shell.fixture_select_browser(first_id, cx);
    })?;
    let public = if std::env::var_os("HARNESS_BROWSER_USER_AGENT_GOOGLE").is_some() {
        Some(google(window, &first, output, cx).await?)
    } else {
        None
    };
    Ok(
        json!({"passed":true,"checks":["HTTP User-Agent equals navigator.userAgent","ordinary pages include Safari Version tokens","302/login-form POST/303 cookie continuity","subsequent tab shares HttpOnly and visible fixture cookies","identity survives DOM navigation","isolated HTML preview keeps default WebKit identity"],"ordinary":ordinary,"login":login,"account":account,"next":next,"secondTab":second_report,"isolatedUserAgent":isolated,"requests":recorded,"google":public}),
    )
}

pub(super) async fn exercise(
    window: WindowHandle<shell::Shell>,
    output: &Path,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let result = run(window, output, cx).await;
    let report = match &result {
        Ok(report) => report.clone(),
        Err(error) => json!({"passed":false,"error":format!("{error:#}")}),
    };
    std::fs::write(
        output.join("user-agent-result.json"),
        serde_json::to_vec_pretty(&report)?,
    )?;
    result.map(|_| ())
}
