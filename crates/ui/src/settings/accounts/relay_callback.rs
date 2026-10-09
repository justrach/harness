//! Catching ChatGPT's loopback redirect on this computer, for a graff sign-in
//! that finishes on another one (a relayed sign-in).
//!
//! OpenAI's authorize page sends the browser to `http://127.0.0.1:<port>/…`,
//! which only the computer running graff listens on. When Settings signs in
//! a different computer, the browser here lands on that address instead, so
//! Harness listens on it briefly, hands the full address to the execution
//! device (`CompleteAgentLogin`), and graff there exchanges the code with its
//! own PKCE verifier. Tokens never pass through this computer. A busy port
//! (a local sign-in already waiting) leaves the paste field as the way back.

use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// How long the listener waits for the browser before giving the port back.
pub(super) const WAIT: Duration = Duration::from_secs(10 * 60);

const DONE_PAGE: &str = "<!doctype html><meta charset=utf-8><title>Harness</title>\
<body style=\"font-family:-apple-system,system-ui,sans-serif;margin:4rem auto;max-width:28rem\">\
<h2>Sign-in sent to Harness</h2><p>You can close this tab and go back to Harness.</p></body>";

/// The loopback address the authorize page redirects to: its port and path.
/// `None` for anything but an `http://127.0.0.1:<port>` redirect.
pub(super) fn callback_target(authorize_url: &str) -> Option<(u16, String)> {
    let url = url::Url::parse(authorize_url).ok()?;
    let redirect = url
        .query_pairs()
        .find(|(key, _)| key == "redirect_uri")?
        .1
        .into_owned();
    let redirect = url::Url::parse(&redirect).ok()?;
    if redirect.scheme() != "http" || redirect.host_str() != Some("127.0.0.1") {
        return None;
    }
    Some((redirect.port()?, redirect.path().to_string()))
}

/// Listens on the callback port until the browser arrives, the deadline
/// passes, or the sign-in dialog closes (`cancelled`). Dropping the guard
/// cancels; the listener thread then frees the port within a poll interval.
pub(super) struct Capture {
    cancelled: Arc<AtomicBool>,
}

impl Drop for Capture {
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::Relaxed);
    }
}

/// Bind the callback port and wait on a background thread. Returns `None`
/// when the port is taken, so the caller relies on pasting the address.
pub(super) fn start(
    port: u16,
    path: String,
) -> Option<(Capture, futures::channel::oneshot::Receiver<String>)> {
    let listener = TcpListener::bind(("127.0.0.1", port)).ok()?;
    listener.set_nonblocking(true).ok()?;
    let cancelled = Arc::new(AtomicBool::new(false));
    let (tx, rx) = futures::channel::oneshot::channel();
    let flag = cancelled.clone();
    std::thread::Builder::new()
        .name("chatgpt-relay-callback".into())
        .spawn(move || {
            if let Some(landed) = accept(&listener, port, &path, Instant::now() + WAIT, &flag) {
                let _ = tx.send(landed);
            }
        })
        .ok()?;
    Some((Capture { cancelled }, rx))
}

fn accept(
    listener: &TcpListener,
    port: u16,
    path: &str,
    deadline: Instant,
    cancelled: &AtomicBool,
) -> Option<String> {
    while !cancelled.load(Ordering::Relaxed) && Instant::now() < deadline {
        match listener.accept() {
            Ok((stream, _)) => {
                if let Some(target) = answer(stream, path) {
                    return Some(format!("http://127.0.0.1:{port}{target}"));
                }
            }
            Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(_) => return None,
        }
    }
    None
}

/// Reply to one request; `Some(request target)` when it is the callback.
/// Anything else (a favicon request) gets a 404 and the wait continues.
fn answer(mut stream: TcpStream, path: &str) -> Option<String> {
    stream.set_nonblocking(false).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(5))).ok()?;
    let mut line = String::new();
    BufReader::new(&stream).read_line(&mut line).ok()?;
    let target = request_target(&line, path);
    let response = match &target {
        Some(_) => format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{DONE_PAGE}",
            DONE_PAGE.len()
        ),
        None => "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".into(),
    };
    let _ = stream.write_all(response.as_bytes());
    target
}

/// `GET <path>?<query> HTTP/1.1` → `<path>?<query>`, only for the callback path.
fn request_target(request_line: &str, path: &str) -> Option<String> {
    let mut parts = request_line.split_whitespace();
    if parts.next()? != "GET" {
        return None;
    }
    let target = parts.next()?;
    let (target_path, query) = target.split_once('?')?;
    (target_path == path && !query.is_empty()).then(|| target.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const AUTHORIZE: &str = "https://auth.openai.com/api/accounts/authorize?client_id=c&response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback&state=s";

    #[test]
    fn the_callback_target_comes_only_from_a_loopback_redirect() {
        assert_eq!(
            callback_target(AUTHORIZE),
            Some((1455, "/auth/callback".into()))
        );
        for other in [
            AUTHORIZE.replace("127.0.0.1", "localhost"),
            AUTHORIZE.replace("http%3A%2F%2F", "https%3A%2F%2F"),
            AUTHORIZE.replace("%3A1455", ""),
            "https://auth.openai.com/authorize?state=s".into(),
        ] {
            assert_eq!(callback_target(&other), None, "{other}");
        }
    }

    #[test]
    fn only_the_callback_request_counts() {
        let path = "/auth/callback";
        assert_eq!(
            request_target("GET /auth/callback?code=a&state=s HTTP/1.1\r\n", path).as_deref(),
            Some("/auth/callback?code=a&state=s")
        );
        assert_eq!(request_target("GET /favicon.ico HTTP/1.1\r\n", path), None);
        assert_eq!(
            request_target("GET /auth/callback HTTP/1.1\r\n", path),
            None
        );
        assert_eq!(
            request_target("POST /auth/callback?code=a HTTP/1.1\r\n", path),
            None
        );
    }

    #[test]
    fn a_browser_redirect_is_captured_and_answered() {
        let probe = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = probe.local_addr().unwrap().port();
        drop(probe);
        let (capture, rx) = start(port, "/auth/callback".into()).expect("port is free");
        let mut favicon = TcpStream::connect(("127.0.0.1", port)).unwrap();
        favicon
            .write_all(b"GET /favicon.ico HTTP/1.1\r\n\r\n")
            .unwrap();
        let mut browser = TcpStream::connect(("127.0.0.1", port)).unwrap();
        browser
            .write_all(b"GET /auth/callback?code=abc&state=st HTTP/1.1\r\nHost: x\r\n\r\n")
            .unwrap();
        let landed = futures::executor::block_on(rx).unwrap();
        assert_eq!(
            landed,
            format!("http://127.0.0.1:{port}/auth/callback?code=abc&state=st")
        );
        let mut reply = String::new();
        BufReader::new(&browser).read_line(&mut reply).unwrap();
        assert!(reply.starts_with("HTTP/1.1 200"), "{reply}");
        drop(capture);
    }

    #[test]
    fn a_busy_port_falls_back_to_pasting() {
        let taken = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = taken.local_addr().unwrap().port();
        assert!(start(port, "/auth/callback".into()).is_none());
    }
}
