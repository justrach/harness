//! A small Chrome DevTools Protocol client: numbered requests matched to
//! their replies, and events routed by the flattened session they belong to.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use serde_json::Value;
use tokio::sync::{mpsc, oneshot};

/// A command the browser hasn't answered in this long has failed.
const CALL_TIMEOUT: Duration = Duration::from_secs(20);
pub const CLOSED: &str = "the browser closed";

#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    pub method: String,
    pub params: Value,
}

#[derive(Debug, PartialEq)]
pub enum Incoming {
    Reply {
        id: u64,
        result: Result<Value, String>,
    },
    Event {
        session: Option<String>,
        event: Event,
    },
}

/// One request on the wire.
pub fn encode(id: u64, session: Option<&str>, method: &str, params: &Value) -> String {
    let mut message = serde_json::json!({ "id": id, "method": method, "params": params });
    if let Some(session) = session {
        message["sessionId"] = Value::String(session.to_string());
    }
    message.to_string()
}

/// One message from the browser; None for anything that isn't a reply or event.
pub fn decode(text: &str) -> Option<Incoming> {
    let mut value: Value = serde_json::from_str(text).ok()?;
    let session = value
        .get("sessionId")
        .and_then(Value::as_str)
        .map(str::to_string);
    if let Some(id) = value.get("id").and_then(Value::as_u64) {
        let result = match value.get_mut("error") {
            Some(error) => Err(error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("the browser refused the command")
                .to_string()),
            None => Ok(value
                .get_mut("result")
                .map(Value::take)
                .unwrap_or(Value::Null)),
        };
        return Some(Incoming::Reply { id, result });
    }
    let method = value.get("method")?.as_str()?.to_string();
    let params = value
        .get_mut("params")
        .map(Value::take)
        .unwrap_or(Value::Null);
    Some(Incoming::Event {
        session,
        event: Event { method, params },
    })
}

type Reply = oneshot::Sender<Result<Value, String>>;

#[derive(Clone)]
pub struct Cdp {
    inner: Arc<Inner>,
}

struct Inner {
    tx: mpsc::UnboundedSender<String>,
    next_id: AtomicU64,
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    closed: bool,
    pending: HashMap<u64, Reply>,
    /// Each attached session's event queue; `""` holds browser-level events.
    sessions: HashMap<String, mpsc::UnboundedSender<Event>>,
}

impl Cdp {
    /// Start reading `rx` (the browser's messages) and writing to `tx`.
    pub fn start(
        tx: mpsc::UnboundedSender<String>,
        mut rx: mpsc::UnboundedReceiver<String>,
    ) -> Self {
        let inner = Arc::new(Inner {
            tx,
            next_id: AtomicU64::new(1),
            state: Mutex::new(State::default()),
        });
        let reader = Arc::downgrade(&inner);
        tokio::spawn(async move {
            while let Some(text) = rx.recv().await {
                let Some(inner) = reader.upgrade() else {
                    return;
                };
                inner.dispatch(&text);
            }
            if let Some(inner) = reader.upgrade() {
                inner.close();
            }
        });
        Self { inner }
    }

    /// Send a command and wait for its reply.
    pub async fn call(
        &self,
        session: Option<&str>,
        method: &str,
        params: Value,
    ) -> Result<Value, String> {
        let id = self.inner.next_id.fetch_add(1, Ordering::Relaxed);
        let (reply, rx) = oneshot::channel();
        {
            let mut state = self.inner.lock();
            if state.closed {
                return Err(CLOSED.into());
            }
            state.pending.insert(id, reply);
        }
        if self
            .inner
            .tx
            .send(encode(id, session, method, &params))
            .is_err()
        {
            self.inner.lock().pending.remove(&id);
            return Err(CLOSED.into());
        }
        match tokio::time::timeout(CALL_TIMEOUT, rx).await {
            Ok(Ok(result)) => result.map_err(|e| {
                if e == CLOSED {
                    e
                } else {
                    format!("{method}: {e}")
                }
            }),
            Ok(Err(_)) => Err(CLOSED.into()),
            Err(_) => {
                self.inner.lock().pending.remove(&id);
                Err(format!("{method}: the browser didn't answer"))
            }
        }
    }

    /// Events for one session (or `""`, the browser itself), from now on.
    /// The receiver ends when the browser goes away or [`Cdp::forget`] runs.
    pub fn events(&self, session: &str) -> mpsc::UnboundedReceiver<Event> {
        let (tx, rx) = mpsc::unbounded_channel();
        let mut state = self.inner.lock();
        if !state.closed {
            state.sessions.insert(session.to_string(), tx);
        }
        rx
    }

    pub fn forget(&self, session: &str) {
        self.inner.lock().sessions.remove(session);
    }

    pub fn is_closed(&self) -> bool {
        self.inner.lock().closed
    }
}

impl Inner {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn dispatch(&self, text: &str) {
        match decode(text) {
            Some(Incoming::Reply { id, result }) => {
                if let Some(reply) = self.lock().pending.remove(&id) {
                    let _ = reply.send(result);
                }
            }
            Some(Incoming::Event { session, event }) => {
                let key = session.unwrap_or_default();
                let mut state = self.lock();
                if let Some(tx) = state.sessions.get(&key)
                    && tx.send(event).is_err()
                {
                    state.sessions.remove(&key);
                }
            }
            None => {}
        }
    }

    /// The browser went away: every waiting call fails, every event queue ends.
    fn close(&self) {
        let mut state = self.lock();
        state.closed = true;
        for (_, reply) in state.pending.drain() {
            let _ = reply.send(Err(CLOSED.into()));
        }
        state.sessions.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requests_carry_an_id_the_method_and_the_session_when_there_is_one() {
        let browser: Value = serde_json::from_str(&encode(
            7,
            None,
            "Target.createTarget",
            &serde_json::json!({ "url": "about:blank" }),
        ))
        .unwrap();
        assert_eq!(
            browser,
            serde_json::json!({ "id": 7, "method": "Target.createTarget", "params": { "url": "about:blank" } })
        );
        let page: Value = serde_json::from_str(&encode(
            8,
            Some("S1"),
            "Page.enable",
            &serde_json::json!({}),
        ))
        .unwrap();
        assert_eq!(page["sessionId"], "S1");
    }

    #[test]
    fn replies_errors_and_events_are_told_apart() {
        assert_eq!(
            decode(r#"{"id":3,"result":{"targetId":"T"}}"#),
            Some(Incoming::Reply {
                id: 3,
                result: Ok(serde_json::json!({ "targetId": "T" }))
            })
        );
        assert_eq!(
            decode(r#"{"id":4,"error":{"code":-32000,"message":"No target"}}"#),
            Some(Incoming::Reply {
                id: 4,
                result: Err("No target".into())
            })
        );
        assert_eq!(
            decode(r#"{"method":"Page.loadEventFired","params":{"timestamp":1},"sessionId":"S"}"#),
            Some(Incoming::Event {
                session: Some("S".into()),
                event: Event {
                    method: "Page.loadEventFired".into(),
                    params: serde_json::json!({ "timestamp": 1 })
                }
            })
        );
        assert_eq!(decode("not json"), None);
        assert_eq!(decode(r#"{"neither":true}"#), None);
    }

    #[tokio::test]
    async fn calls_get_their_own_replies_and_fail_when_the_browser_goes_away() {
        let (tx, mut browser_in) = mpsc::unbounded_channel::<String>();
        let (browser_out, rx) = mpsc::unbounded_channel::<String>();
        let cdp = Cdp::start(tx, rx);
        let mut events = cdp.events("S");
        let call = tokio::spawn({
            let cdp = cdp.clone();
            async move { cdp.call(Some("S"), "Page.enable", Value::Null).await }
        });
        let sent: Value = serde_json::from_str(&browser_in.recv().await.unwrap()).unwrap();
        let id = sent["id"].as_u64().unwrap();
        browser_out
            .send(r#"{"method":"Page.frameStartedLoading","params":{},"sessionId":"S"}"#.into())
            .unwrap();
        browser_out
            .send(r#"{"method":"Page.frameStartedLoading","params":{},"sessionId":"OTHER"}"#.into())
            .unwrap();
        browser_out
            .send(format!(r#"{{"id":{id},"result":{{"ok":1}}}}"#))
            .unwrap();
        assert_eq!(call.await.unwrap(), Ok(serde_json::json!({ "ok": 1 })));
        assert_eq!(
            events.recv().await.unwrap().method,
            "Page.frameStartedLoading"
        );

        let waiting = tokio::spawn({
            let cdp = cdp.clone();
            async move { cdp.call(None, "Browser.getVersion", Value::Null).await }
        });
        let _ = browser_in.recv().await.unwrap();
        drop(browser_out);
        assert_eq!(waiting.await.unwrap(), Err(CLOSED.to_string()));
        assert!(events.recv().await.is_none(), "event queues end too");
        assert!(cdp.is_closed());
        assert_eq!(
            cdp.call(None, "Browser.close", Value::Null).await,
            Err(CLOSED.to_string())
        );
    }
}
