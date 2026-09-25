//! Exo over ACP. Exo (github.com/exoharness/exo) ships no ACP server: its
//! programmatic entry point is the `agent-cli` adapter, a unix socket
//! (`~/.exo/agent-cli.sock`, or `EXO_AGENT_CLI_SOCKET`) that takes ONE JSON
//! line `{"cwd","prompt"}` per connection and answers with
//! `{"type":"reply","text"}` or `{"type":"error","message"}` — the protocol of
//! Exo's own `exo-cli` client.
//!
//! `harness exo-acp` serves ACP v1 on stdio and forwards each
//! `session/prompt` to that socket, so the shared [`super::AcpHarness`]
//! drives Exo exactly like the native ACP agents (lifecycle, interrupts,
//! turn-boundary steering, error chips).
//!
//! Exo keeps a single long-lived conversation per agent, so sessions here are
//! thin: an id plus the cwd Exo maps into its sandbox mount. `session/load`
//! always succeeds without replay — the history lives in Exo. The reply
//! arrives whole (agent-cli does not stream), as one `agent_message_chunk`.
//! Cancelling drops the socket, which Exo nacks instead of delivering.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;

/// Overrides the agent-cli socket, same variable `exo-cli` reads.
pub const SOCKET_ENV: &str = "EXO_AGENT_CLI_SOCKET";

const METHOD_NOT_FOUND: i64 = -32601;
const INVALID_PARAMS: i64 = -32602;
const INTERNAL_ERROR: i64 = -32603;

/// The agent-cli socket Exo listens on.
pub fn socket_path() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os(SOCKET_ENV).filter(|p| !p.is_empty()) {
        return Some(PathBuf::from(path));
    }
    crate::executable::home_dir().map(|home| home.join(".exo").join("agent-cli.sock"))
}

/// Serve ACP on this process's stdin/stdout until stdin closes.
pub async fn serve() -> std::io::Result<()> {
    serve_with(tokio::io::stdin(), tokio::io::stdout(), socket_path()).await
}

type Out<W> = Arc<Mutex<W>>;

struct Session {
    cwd: String,
    /// The in-flight prompt's cancel handle (`session/cancel`).
    turn: Option<CancellationToken>,
}

/// The bridge over arbitrary streams; `socket` is the agent-cli socket.
pub async fn serve_with<R, W>(input: R, output: W, socket: Option<PathBuf>) -> std::io::Result<()>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let out: Out<W> = Arc::new(Mutex::new(output));
    let mut lines = BufReader::new(input).lines();
    let mut sessions: HashMap<String, Session> = HashMap::new();
    while let Some(line) = lines.next_line().await? {
        let Ok(message) = serde_json::from_str::<Value>(line.trim()) else {
            continue;
        };
        let method = message.get("method").and_then(Value::as_str).unwrap_or_default();
        let params = message.get("params").cloned().unwrap_or(Value::Null);
        let Some(id) = message.get("id").cloned() else {
            // Notifications: only cancel matters.
            if method == "session/cancel"
                && let Some(turn) = session_of(&params)
                    .and_then(|sid| sessions.get_mut(sid))
                    .and_then(|s| s.turn.take())
            {
                turn.cancel();
            }
            continue;
        };
        if method.is_empty() {
            // A response to a request we never send.
            continue;
        }
        match method {
            "initialize" => respond(&out, id, initialize_result()).await?,
            "session/new" | "session/load" => {
                let session_id = match (method, session_of(&params)) {
                    ("session/load", Some(sid)) => sid.to_owned(),
                    _ => uuid::Uuid::new_v4().to_string(),
                };
                let cwd = params
                    .get("cwd")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                sessions.insert(session_id.clone(), Session { cwd, turn: None });
                let result = if method == "session/new" {
                    json!({ "sessionId": session_id })
                } else {
                    json!({})
                };
                respond(&out, id, result).await?;
            }
            "session/prompt" => {
                let Some(session) = session_of(&params).and_then(|sid| sessions.get_mut(sid)) else {
                    fail(&out, id, INVALID_PARAMS, "unknown sessionId".into()).await?;
                    continue;
                };
                let session_id = session_of(&params).unwrap_or_default().to_owned();
                let turn = CancellationToken::new();
                if let Some(previous) = session.turn.replace(turn.clone()) {
                    previous.cancel();
                }
                let prompt = prompt_text(&params);
                let cwd = session.cwd.clone();
                let socket = socket.clone();
                let out = Arc::clone(&out);
                tokio::spawn(async move {
                    let outcome = tokio::select! {
                        _ = turn.cancelled() => Ok(None),
                        reply = ask(socket, &cwd, &prompt) => reply.map(Some),
                    };
                    let _ = match outcome {
                        Ok(Some(text)) => {
                            if !text.is_empty() {
                                let _ = notify(&out, "session/update", json!({
                                    "sessionId": session_id,
                                    "update": {
                                        "sessionUpdate": "agent_message_chunk",
                                        "content": { "type": "text", "text": text },
                                    },
                                }))
                                .await;
                            }
                            respond(&out, id, json!({ "stopReason": "end_turn" })).await
                        }
                        Ok(None) => respond(&out, id, json!({ "stopReason": "cancelled" })).await,
                        Err(message) => fail(&out, id, INTERNAL_ERROR, message).await,
                    };
                });
            }
            _ => fail(&out, id, METHOD_NOT_FOUND, format!("{method} is not supported")).await?,
        }
    }
    for session in sessions.into_values() {
        if let Some(turn) = session.turn {
            turn.cancel();
        }
    }
    Ok(())
}

fn session_of(params: &Value) -> Option<&str> {
    params.get("sessionId").and_then(Value::as_str)
}

fn initialize_result() -> Value {
    json!({
        "protocolVersion": 1,
        "agentCapabilities": {
            "loadSession": true,
            "promptCapabilities": { "image": false, "audio": false, "embeddedContext": false },
        },
        "agentInfo": {
            "name": "harness-exo-acp",
            "title": "Exo",
            "version": env!("CARGO_PKG_VERSION"),
        },
        "authMethods": [],
    })
}

/// The prompt's text blocks, with linked resources kept as their uri (Exo
/// reads files itself through its sandbox mount).
fn prompt_text(params: &Value) -> String {
    params
        .get("prompt")
        .and_then(Value::as_array)
        .map(|blocks| {
            blocks
                .iter()
                .filter_map(|block| match block.get("type").and_then(Value::as_str) {
                    Some("text") => block.get("text").and_then(Value::as_str).map(str::to_owned),
                    Some("resource_link") => block.get("uri").and_then(Value::as_str).map(str::to_owned),
                    Some("resource") => block
                        .pointer("/resource/uri")
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                    _ => None,
                })
                .collect::<Vec<_>>()
                .join("\n\n")
        })
        .unwrap_or_default()
}

/// One agent-cli exchange: send `{cwd, prompt}`, await the reply line.
#[cfg(unix)]
async fn ask(socket: Option<PathBuf>, cwd: &str, prompt: &str) -> Result<String, String> {
    let socket = socket.ok_or_else(|| "no home directory to locate Exo's agent-cli socket".to_owned())?;
    let stream = tokio::net::UnixStream::connect(&socket).await.map_err(|err| {
        use std::io::ErrorKind;
        match err.kind() {
            ErrorKind::NotFound | ErrorKind::ConnectionRefused => format!(
                "Exo's agent-cli adapter isn't listening on {}. Start Exo with `./exo.sh --setup agent-cli` \
                 (or run `exo-cli` once to bootstrap it), or point {SOCKET_ENV} at its socket.",
                socket.display()
            ),
            _ => format!("couldn't reach Exo at {}: {err}", socket.display()),
        }
    })?;
    let (read, mut write) = stream.into_split();
    let mut request = serde_json::to_string(&json!({ "cwd": cwd, "prompt": prompt }))
        .map_err(|err| err.to_string())?;
    request.push('\n');
    write
        .write_all(request.as_bytes())
        .await
        .map_err(|err| format!("couldn't send the prompt to Exo: {err}"))?;
    let mut lines = BufReader::new(read).lines();
    loop {
        let line = lines
            .next_line()
            .await
            .map_err(|err| format!("lost the connection to Exo: {err}"))?
            .ok_or_else(|| "Exo closed the connection before replying".to_owned())?;
        if line.trim().is_empty() {
            continue;
        }
        let reply: Value = serde_json::from_str(&line)
            .map_err(|_| format!("unexpected reply from Exo: {line}"))?;
        match reply.get("type").and_then(Value::as_str) {
            Some("reply") => {
                return Ok(reply.get("text").and_then(Value::as_str).unwrap_or_default().to_owned());
            }
            Some("error") => {
                let message = reply.get("message").and_then(Value::as_str).unwrap_or("unknown error");
                return Err(format!("Exo: {message}"));
            }
            // Forward-compatible: later adapter versions may interleave
            // progress lines before the reply.
            _ => continue,
        }
    }
}

#[cfg(not(unix))]
async fn ask(_socket: Option<PathBuf>, _cwd: &str, _prompt: &str) -> Result<String, String> {
    Err("Exo's agent-cli adapter uses a unix socket, which this platform doesn't support".into())
}

async fn write_line<W: AsyncWrite + Unpin>(out: &Out<W>, message: Value) -> std::io::Result<()> {
    let mut line = serde_json::to_vec(&message)?;
    line.push(b'\n');
    let mut out = out.lock().await;
    out.write_all(&line).await?;
    out.flush().await
}

async fn respond<W: AsyncWrite + Unpin>(out: &Out<W>, id: Value, result: Value) -> std::io::Result<()> {
    write_line(out, json!({ "jsonrpc": "2.0", "id": id, "result": result })).await
}

async fn fail<W: AsyncWrite + Unpin>(
    out: &Out<W>,
    id: Value,
    code: i64,
    message: String,
) -> std::io::Result<()> {
    write_line(
        out,
        json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } }),
    )
    .await
}

async fn notify<W: AsyncWrite + Unpin>(out: &Out<W>, method: &str, params: Value) -> std::io::Result<()> {
    write_line(out, json!({ "jsonrpc": "2.0", "method": method, "params": params })).await
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

    /// A stand-in for Exo's agent-cli worker: records each request and
    /// answers with `reply` (or never answers when `None`).
    async fn fake_exo(
        dir: &std::path::Path,
        reply: Option<Value>,
    ) -> (PathBuf, tokio::sync::mpsc::UnboundedReceiver<Value>) {
        let path = dir.join("agent-cli.sock");
        let listener = tokio::net::UnixListener::bind(&path).unwrap();
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let (read, mut write) = stream.into_split();
                let mut lines = BufReader::new(read).lines();
                let Ok(Some(line)) = lines.next_line().await else {
                    continue;
                };
                let _ = tx.send(serde_json::from_str::<Value>(&line).unwrap());
                match &reply {
                    Some(reply) => {
                        let _ = write.write_all(b"{\"type\":\"progress\"}\n").await;
                        let mut line = reply.to_string();
                        line.push('\n');
                        let _ = write.write_all(line.as_bytes()).await;
                    }
                    // Hold the connection open until the client drops it.
                    None => {
                        let _ = lines.next_line().await;
                    }
                }
            }
        });
        (path, rx)
    }

    struct Client {
        input: tokio::io::DuplexStream,
        output: tokio::io::Lines<BufReader<tokio::io::DuplexStream>>,
    }

    impl Client {
        fn start(socket: Option<PathBuf>) -> Self {
            let (input, bridge_in) = tokio::io::duplex(1 << 16);
            let (bridge_out, output) = tokio::io::duplex(1 << 16);
            tokio::spawn(serve_with(bridge_in, bridge_out, socket));
            Self {
                input,
                output: BufReader::new(output).lines(),
            }
        }

        async fn send(&mut self, message: Value) {
            let mut line = message.to_string();
            line.push('\n');
            self.input.write_all(line.as_bytes()).await.unwrap();
        }

        async fn recv(&mut self) -> Value {
            let line = tokio::time::timeout(std::time::Duration::from_secs(5), self.output.next_line())
                .await
                .expect("bridge replied in time")
                .unwrap()
                .expect("bridge output open");
            serde_json::from_str(&line).unwrap()
        }

        async fn new_session(&mut self, cwd: &str) -> String {
            self.send(json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}))
                .await;
            let init = self.recv().await;
            assert_eq!(init["result"]["protocolVersion"], 1);
            assert_eq!(init["result"]["agentCapabilities"]["loadSession"], true);
            self.send(json!({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":cwd,"mcpServers":[]}}))
                .await;
            let session = self.recv().await;
            session["result"]["sessionId"].as_str().unwrap().to_owned()
        }
    }

    #[tokio::test]
    async fn prompt_round_trips_through_agent_cli() {
        let dir = tempfile::tempdir().unwrap();
        let (socket, mut requests) =
            fake_exo(dir.path(), Some(json!({"type":"reply","text":"Done: set up node."}))).await;
        let mut client = Client::start(Some(socket));
        let sid = client.new_session("/work/repo").await;
        client
            .send(json!({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{
                "sessionId": sid,
                "prompt": [
                    {"type":"text","text":"Set up node"},
                    {"type":"resource_link","uri":"file:///work/repo/package.json","name":"package.json"},
                    {"type":"image","data":"...","mimeType":"image/png"},
                ],
            }}))
            .await;
        let update = client.recv().await;
        assert_eq!(update["method"], "session/update");
        assert_eq!(update["params"]["sessionId"], sid.as_str());
        assert_eq!(update["params"]["update"]["sessionUpdate"], "agent_message_chunk");
        assert_eq!(update["params"]["update"]["content"]["text"], "Done: set up node.");
        let done = client.recv().await;
        assert_eq!(done["id"], 3);
        assert_eq!(done["result"]["stopReason"], "end_turn");
        let request = requests.recv().await.unwrap();
        assert_eq!(request["cwd"], "/work/repo");
        assert_eq!(
            request["prompt"],
            "Set up node\n\nfile:///work/repo/package.json"
        );
    }

    #[tokio::test]
    async fn exo_errors_and_a_missing_socket_fail_the_turn() {
        let dir = tempfile::tempdir().unwrap();
        let (socket, _requests) =
            fake_exo(dir.path(), Some(json!({"type":"error","message":"sandbox is down"}))).await;
        let mut client = Client::start(Some(socket));
        let sid = client.new_session("/w").await;
        client
            .send(json!({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":sid,"prompt":[{"type":"text","text":"hi"}]}}))
            .await;
        let failed = client.recv().await;
        assert_eq!(failed["id"], 3);
        assert_eq!(failed["error"]["message"], "Exo: sandbox is down");

        let mut offline = Client::start(Some(dir.path().join("missing.sock")));
        let sid = offline.new_session("/w").await;
        offline
            .send(json!({"jsonrpc":"2.0","id":4,"method":"session/prompt","params":{"sessionId":sid,"prompt":[{"type":"text","text":"hi"}]}}))
            .await;
        let failed = offline.recv().await;
        let message = failed["error"]["message"].as_str().unwrap();
        assert!(message.contains("isn't listening"), "{message}");
        assert!(message.contains("exo.sh --setup agent-cli"), "{message}");
    }

    #[tokio::test]
    async fn cancel_ends_the_turn_as_cancelled() {
        let dir = tempfile::tempdir().unwrap();
        let (socket, mut requests) = fake_exo(dir.path(), None).await;
        let mut client = Client::start(Some(socket));
        let sid = client.new_session("/w").await;
        client
            .send(json!({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":sid,"prompt":[{"type":"text","text":"long task"}]}}))
            .await;
        // Exo has the prompt before the cancel races it.
        requests.recv().await.unwrap();
        client
            .send(json!({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":sid}}))
            .await;
        let done = client.recv().await;
        assert_eq!(done["id"], 3);
        assert_eq!(done["result"]["stopReason"], "cancelled");
    }

    #[tokio::test]
    async fn load_resumes_without_replay_and_unknown_methods_error() {
        let mut client = Client::start(None);
        client
            .send(json!({"jsonrpc":"2.0","id":1,"method":"session/load","params":{"sessionId":"prev","cwd":"/w","mcpServers":[]}}))
            .await;
        assert_eq!(client.recv().await, json!({"jsonrpc":"2.0","id":1,"result":{}}));
        client
            .send(json!({"jsonrpc":"2.0","id":2,"method":"session/set_mode","params":{"sessionId":"prev","modeId":"x"}}))
            .await;
        assert_eq!(client.recv().await["error"]["code"], METHOD_NOT_FOUND);
        client
            .send(json!({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"nope","prompt":[]}}))
            .await;
        assert_eq!(client.recv().await["error"]["code"], INVALID_PARAMS);
    }
}
