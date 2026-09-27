//! The local relay agents reach browse through. Agents speak plain MCP over
//! HTTP (`POST /mcp`, JSON in and out) with a per-run bearer token; the relay
//! signs for them, tags each `tools/call` with the run's page session
//! (`_meta["browse/session"]`), and hands back browse's signed answer.
//! Refusals come back as tool errors the model can read, not HTTP failures.
//!
//! Deliberately small: `Content-Length` bodies only, loopback only.
//! Connections are kept alive: graff's MCP client reuses one and hung when
//! the relay closed it after the first answer.

use std::sync::Weak;

use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::{TcpListener, TcpStream};

use super::{BrowseLink, LinkError, wire};

const MAX_HEAD: usize = 32 * 1024;
const MAX_BODY: usize = 8 * 1024 * 1024;
/// An idle kept-alive connection is closed after this.
const IDLE: std::time::Duration = std::time::Duration::from_secs(120);

pub struct Relay {
    port: u16,
    task: tokio::task::JoinHandle<()>,
}

impl Relay {
    pub async fn start(link: Weak<BrowseLink>) -> std::io::Result<Self> {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
        let port = listener.local_addr()?.port();
        let task = tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    continue;
                };
                let link = link.clone();
                tokio::spawn(async move {
                    if let Err(error) = serve(stream, link, port).await {
                        tracing::debug!(%error, "browse relay connection");
                    }
                });
            }
        });
        Ok(Self { port, task })
    }

    pub fn port(&self) -> u16 {
        self.port
    }
}

impl Drop for Relay {
    fn drop(&mut self) {
        self.task.abort();
    }
}

#[derive(Debug, PartialEq)]
pub(super) struct Head {
    pub method: String,
    pub path: String,
    /// Lowercased names.
    pub headers: Vec<(String, String)>,
}

impl Head {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v.as_str())
    }
}

/// Parse a request head (everything before the blank line).
pub(super) fn parse_head(bytes: &[u8]) -> Option<Head> {
    let text = std::str::from_utf8(bytes).ok()?;
    let mut lines = text.split("\r\n");
    let mut request = lines.next()?.split(' ');
    let method = request.next()?.to_owned();
    let path = request.next()?.to_owned();
    request.next()?.starts_with("HTTP/1.").then_some(())?;
    let headers = lines
        .filter(|line| !line.is_empty())
        .filter_map(|line| {
            let (name, value) = line.split_once(':')?;
            Some((name.trim().to_ascii_lowercase(), value.trim().to_owned()))
        })
        .collect();
    Some(Head {
        method,
        path,
        headers,
    })
}

/// Read one request: its head and a `Content-Length` body. `Ok(None)` when
/// the client closed the connection between requests.
pub(super) async fn read_request(
    stream: &mut TcpStream,
) -> Result<Option<(Head, Vec<u8>)>, (u16, &'static str)> {
    let mut buffer = Vec::with_capacity(4096);
    let mut chunk = [0u8; 4096];
    let split = loop {
        if let Some(at) = buffer.windows(4).position(|w| w == b"\r\n\r\n") {
            break at;
        }
        if buffer.len() > MAX_HEAD {
            return Err((431, "header too large"));
        }
        let n = stream
            .read(&mut chunk)
            .await
            .map_err(|_| (400, "read failed"))?;
        if n == 0 {
            if buffer.is_empty() {
                return Ok(None);
            }
            return Err((400, "connection closed"));
        }
        buffer.extend_from_slice(&chunk[..n]);
    };
    let head = parse_head(&buffer[..split]).ok_or((400, "bad request"))?;
    if head.header("transfer-encoding").is_some() {
        return Err((411, "send a Content-Length"));
    }
    let length: usize = head
        .header("content-length")
        .map(|v| v.parse().map_err(|_| (400, "bad Content-Length")))
        .transpose()?
        .unwrap_or(0);
    if length > MAX_BODY {
        return Err((413, "body too large"));
    }
    let mut body = buffer[split + 4..].to_vec();
    while body.len() < length {
        let n = stream
            .read(&mut chunk)
            .await
            .map_err(|_| (400, "read failed"))?;
        if n == 0 {
            return Err((400, "connection closed"));
        }
        body.extend_from_slice(&chunk[..n]);
    }
    body.truncate(length);
    Ok(Some((head, body)))
}

pub(super) fn response(status: u16, body: &[u8]) -> Vec<u8> {
    response_with(status, body, false)
}

pub(super) fn response_with(status: u16, body: &[u8], keep_alive: bool) -> Vec<u8> {
    let reason = match status {
        200 => "OK",
        202 => "Accepted",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        411 => "Length Required",
        413 => "Payload Too Large",
        431 => "Request Header Fields Too Large",
        _ => "Error",
    };
    let mut out = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: {}\r\n\r\n",
        body.len(),
        if keep_alive { "keep-alive" } else { "close" },
    )
    .into_bytes();
    out.extend_from_slice(body);
    out
}

fn error_body(code: &str) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({ "error": code })).unwrap_or_default()
}

async fn serve(mut stream: TcpStream, link: Weak<BrowseLink>, port: u16) -> std::io::Result<()> {
    loop {
        let (status, body, keep_alive) =
            match tokio::time::timeout(IDLE, read_request(&mut stream)).await {
                Err(_) | Ok(Ok(None)) => break,
                Ok(Ok(Some((head, body)))) => {
                    let keep_alive = !head
                        .header("connection")
                        .is_some_and(|v| v.eq_ignore_ascii_case("close"));
                    let (status, body) = handle(&link, port, &head, &body).await;
                    (status, body, keep_alive)
                }
                // A malformed request leaves the stream in an unknown state.
                Ok(Err((status, why))) => (status, error_body(why), false),
            };
        stream
            .write_all(&response_with(status, &body, keep_alive))
            .await?;
        if !keep_alive {
            break;
        }
    }
    stream.shutdown().await
}

/// Only local agents: no web page (any `Origin`), no rebinding (`Host`).
fn local_only(head: &Head, port: u16) -> bool {
    head.header("origin").is_none()
        && head.header("host").is_some_and(|host| {
            host == format!("127.0.0.1:{port}") || host == format!("localhost:{port}")
        })
}

async fn handle(link: &Weak<BrowseLink>, port: u16, head: &Head, body: &[u8]) -> (u16, Vec<u8>) {
    if head.path != "/mcp" {
        return (404, error_body("not_found"));
    }
    // No server-initiated stream and no MCP session: GET and DELETE aren't offered.
    if head.method != "POST" {
        return (405, error_body("method_not_allowed"));
    }
    if !local_only(head, port) {
        return (403, error_body("bad_origin"));
    }
    let Some(link) = link.upgrade() else {
        return (404, error_body("not_found"));
    };
    let token = head
        .header("authorization")
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or_default();
    let Some(run_id) = link.run_for_token(token.trim()) else {
        return (401, error_body("unknown_run"));
    };
    let Ok(mut message) = serde_json::from_slice::<serde_json::Value>(body) else {
        return (400, error_body("bad_json"));
    };
    tag_session(&mut message, &wire::session_id(&run_id));
    let forwarded = serde_json::to_vec(&message).unwrap_or_default();
    match link.request("/mcp", &forwarded).await {
        Ok((status, answer)) => (status, answer),
        Err(error) => refusal(&message, &error),
    }
}

/// Put the run's page session on every `tools/call` (single or batched).
pub(super) fn tag_session(message: &mut serde_json::Value, session: &str) {
    match message {
        serde_json::Value::Array(batch) => {
            for item in batch {
                tag_session(item, session);
            }
        }
        serde_json::Value::Object(object) => {
            if object.get("method").and_then(|m| m.as_str()) != Some("tools/call") {
                return;
            }
            let params = object
                .entry("params")
                .or_insert_with(|| serde_json::json!({}));
            if let Some(params) = params.as_object_mut() {
                let meta = params
                    .entry("_meta")
                    .or_insert_with(|| serde_json::json!({}));
                if let Some(meta) = meta.as_object_mut() {
                    meta.insert("browse/session".into(), session.into());
                }
            }
        }
        _ => {}
    }
}

/// A failure answered in MCP terms: a tool call gets a tool error the model
/// can read and act on; other requests get a JSON-RPC error; notifications
/// get the empty 202 they would have.
pub(super) fn refusal(message: &serde_json::Value, error: &LinkError) -> (u16, Vec<u8>) {
    let text = error.to_string();
    let answer = |request: &serde_json::Value| -> Option<serde_json::Value> {
        let id = request.get("id")?.clone();
        Some(
            if request.get("method").and_then(|m| m.as_str()) == Some("tools/call") {
                serde_json::json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": { "content": [{ "type": "text", "text": text }], "isError": true },
                })
            } else {
                serde_json::json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": { "code": -32000, "message": text },
                })
            },
        )
    };
    let reply = match message {
        serde_json::Value::Array(batch) => {
            let answers: Vec<_> = batch.iter().filter_map(answer).collect();
            (!answers.is_empty()).then(|| serde_json::Value::Array(answers))
        }
        request => answer(request),
    };
    match reply {
        Some(reply) => (200, serde_json::to_vec(&reply).unwrap_or_default()),
        None => (202, Vec::new()),
    }
}
