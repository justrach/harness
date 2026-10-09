//! The edge the phone talks to: socket URLs minted per dial, and the plain-HTTPS transports the sync clients fall
//! back to (registry pull/push, chat2 checkpoint, rows pull/push). The paths and query items are the ones the iOS
//! `AppConfig` builds; a bearer header carries the token on HTTP, and the socket dialer moves the `token` query item
//! into a header before the upgrade.

use std::sync::Arc;
use std::time::Duration;

use futures::future::BoxFuture;
use harness_sync::chat_client::{ChatTransport, CheckpointFetcher};
use harness_sync::{RegistryTransport, SyncError, UrlProvider};

/// Supplies the bearer for every request: the CodeGraff access token (refreshed by the app when it runs out) or a
/// dev-edge bearer. Called on a blocking thread, so an implementation may refresh synchronously.
#[uniffi::export(with_foreign)]
pub trait TokenSource: Send + Sync {
    /// The current bearer, or None when there is no usable sign-in.
    fn bearer(&self) -> Option<String>;
}

#[derive(Clone)]
pub struct Edge {
    base: String,
    pub org_id: String,
    pub device_id: String,
    tokens: Arc<dyn TokenSource>,
    http: reqwest::Client,
}

fn encode(component: &str) -> String {
    let mut out = String::with_capacity(component.len());
    for b in component.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

impl Edge {
    pub fn new(base: &str, org_id: &str, device_id: &str, tokens: Arc<dyn TokenSource>) -> Self {
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(20))
            .build()
            .expect("an HTTP client with default TLS builds");
        Self {
            base: base.trim_end_matches('/').to_owned(),
            org_id: org_id.to_owned(),
            device_id: device_id.to_owned(),
            tokens,
            http,
        }
    }

    pub fn base(&self) -> &str {
        &self.base
    }

    /// The bearer, read off the networking threads.
    pub async fn bearer(&self) -> Result<String, SyncError> {
        let tokens = self.tokens.clone();
        tokio::task::spawn_blocking(move || tokens.bearer())
            .await
            .map_err(|_| SyncError::Closed)?
            .ok_or_else(|| SyncError::Auth("no sign-in".into()))
    }

    fn ws_base(&self) -> String {
        if let Some(rest) = self.base.strip_prefix("http://") {
            format!("ws://{rest}")
        } else if let Some(rest) = self.base.strip_prefix("https://") {
            format!("wss://{rest}")
        } else {
            self.base.clone()
        }
    }

    async fn socket_url(&self, path: &str) -> Result<String, SyncError> {
        let token = self.bearer().await?;
        Ok(format!(
            "{}/{path}?token={}&device={}",
            self.ws_base(),
            encode(&token),
            encode(&self.device_id)
        ))
    }

    pub fn registry_socket(&self) -> Arc<dyn UrlProvider> {
        Arc::new(SocketUrl {
            edge: self.clone(),
            path: format!("registry/{}/ws", encode(&self.org_id)),
        })
    }

    pub fn chat_socket(&self, chat_id: &str) -> Arc<dyn UrlProvider> {
        Arc::new(SocketUrl {
            edge: self.clone(),
            path: format!("chat2/{}/ws", encode(chat_id)),
        })
    }

    pub fn registry_transport(&self) -> Arc<dyn RegistryTransport> {
        Arc::new(RegistryHttp { edge: self.clone() })
    }

    pub fn chat_transport(&self, chat_id: &str) -> Arc<dyn ChatTransport> {
        Arc::new(ChatHttp {
            edge: self.clone(),
            chat_id: chat_id.to_owned(),
        })
    }

    pub fn checkpoint_fetcher(&self, chat_id: &str) -> Arc<dyn CheckpointFetcher> {
        Arc::new(CheckpointHttp {
            edge: self.clone(),
            chat_id: chat_id.to_owned(),
            partial: Arc::new(std::sync::Mutex::new(Partial::default())),
        })
    }
}

fn transport_error(err: reqwest::Error) -> SyncError {
    // The error's own text never carries the bearer (it is a header, not part of the URL).
    SyncError::WebSocket(err.without_url().to_string())
}

struct SocketUrl {
    edge: Edge,
    path: String,
}

impl UrlProvider for SocketUrl {
    fn url(&self) -> BoxFuture<'static, Result<String, SyncError>> {
        let edge = self.edge.clone();
        let path = self.path.clone();
        Box::pin(async move { edge.socket_url(&path).await })
    }
}

/// GET /registry/{org}/rows?device=&beat=1&since= and POST /registry/{org}/push?device=. The GET doubles as this
/// device's presence beat, as on iOS.
struct RegistryHttp {
    edge: Edge,
}

impl RegistryTransport for RegistryHttp {
    fn fetch(&self, since: u64) -> BoxFuture<'static, Result<String, SyncError>> {
        let edge = self.edge.clone();
        Box::pin(async move {
            let bearer = edge.bearer().await?;
            let mut query = vec![("device", edge.device_id.clone()), ("beat", "1".to_owned())];
            if since > 0 {
                query.push(("since", since.to_string()));
            }
            let res = edge
                .http
                .get(format!(
                    "{}/registry/{}/rows",
                    edge.base,
                    encode(&edge.org_id)
                ))
                .query(&query)
                .bearer_auth(bearer)
                .timeout(Duration::from_secs(60))
                .send()
                .await
                .map_err(transport_error)?;
            if res.status().as_u16() != 200 {
                return Err(SyncError::Protocol(format!(
                    "registry pull http {}",
                    res.status().as_u16()
                )));
            }
            res.text().await.map_err(transport_error)
        })
    }

    fn push(&self, body: String) -> BoxFuture<'static, Result<String, SyncError>> {
        let edge = self.edge.clone();
        Box::pin(async move {
            let bearer = edge.bearer().await?;
            let res = edge
                .http
                .post(format!(
                    "{}/registry/{}/push",
                    edge.base,
                    encode(&edge.org_id)
                ))
                .query(&[("device", edge.device_id.clone())])
                .bearer_auth(bearer)
                .header("content-type", "application/json")
                .body(body)
                .timeout(Duration::from_secs(60))
                .send()
                .await
                .map_err(transport_error)?;
            if res.status().as_u16() != 200 {
                return Err(SyncError::Protocol(format!(
                    "registry push http {}",
                    res.status().as_u16()
                )));
            }
            res.text().await.map_err(transport_error)
        })
    }
}

/// GET and POST /chat2/{chatId}/rows.
struct ChatHttp {
    edge: Edge,
    chat_id: String,
}

impl ChatHttp {
    fn url(&self) -> String {
        format!("{}/chat2/{}/rows", self.edge.base, encode(&self.chat_id))
    }
}

impl ChatTransport for ChatHttp {
    fn fetch_rows(&self, after: u64) -> BoxFuture<'static, Result<Vec<u8>, SyncError>> {
        let edge = self.edge.clone();
        let url = self.url();
        Box::pin(async move {
            let bearer = edge.bearer().await?;
            let res = edge
                .http
                .get(url)
                .query(&[
                    ("after", after.to_string()),
                    ("device", edge.device_id.clone()),
                ])
                .bearer_auth(bearer)
                .timeout(Duration::from_secs(120))
                .send()
                .await
                .map_err(transport_error)?;
            if !res.status().is_success() {
                return Err(SyncError::Protocol(format!(
                    "chat pull http {}",
                    res.status().as_u16()
                )));
            }
            Ok(res.bytes().await.map_err(transport_error)?.to_vec())
        })
    }

    fn push(
        &self,
        batch_id: String,
        bytes: Vec<u8>,
    ) -> BoxFuture<'static, Result<String, SyncError>> {
        let edge = self.edge.clone();
        let url = self.url();
        Box::pin(async move {
            let bearer = edge.bearer().await?;
            let res = edge
                .http
                .post(url)
                .query(&[("batchId", batch_id), ("device", edge.device_id.clone())])
                .bearer_auth(bearer)
                .body(bytes)
                .timeout(Duration::from_secs(120))
                .send()
                .await
                .map_err(transport_error)?;
            if !res.status().is_success() {
                return Err(SyncError::Protocol(format!(
                    "chat push http {}",
                    res.status().as_u16()
                )));
            }
            res.text().await.map_err(transport_error)
        })
    }
}

/// The bytes of a checkpoint download so far, and the checkpoint they belong to.
#[derive(Default)]
struct Partial {
    bytes: Vec<u8>,
    seq: Option<String>,
}

/// GET /chat2/{chatId}/checkpoint, resumed with `Range` after a dropped stream, and restarted from byte 0 when the
/// checkpoint was replaced mid-download (`x-chat2-checkpoint-seq` changed). The partial download outlives a fetch:
/// the chat client redials and fetches again when a slow link trips its deadlines, and on such a link starting over
/// each time never finishes (iOS keeps `partialCheckpoint` across redials for the same reason).
struct CheckpointHttp {
    edge: Edge,
    chat_id: String,
    partial: Arc<std::sync::Mutex<Partial>>,
}

impl CheckpointFetcher for CheckpointHttp {
    fn fetch(&self) -> BoxFuture<'static, Result<Vec<u8>, SyncError>> {
        let edge = self.edge.clone();
        let url = format!("{}/chat2/{}/checkpoint", edge.base, encode(&self.chat_id));
        let partial = self.partial.clone();
        Box::pin(async move {
            let (mut got, mut seen_seq) = {
                let mut kept = crate::workspace::lock(&partial);
                (std::mem::take(&mut kept.bytes), kept.seq.take())
            };
            let keep = |bytes: Vec<u8>, seq: Option<String>| {
                *crate::workspace::lock(&partial) = Partial { bytes, seq };
            };
            let mut last_failure: Option<String> = None;
            for _attempt in 0..4 {
                let bearer = edge.bearer().await?;
                let mut req = edge
                    .http
                    .get(&url)
                    .bearer_auth(bearer)
                    .timeout(Duration::from_secs(300));
                if !got.is_empty() {
                    req = req.header("range", format!("bytes={}-", got.len()));
                }
                let mut res = match req.send().await {
                    Ok(res) => res,
                    Err(err) => {
                        last_failure = Some(err.without_url().to_string());
                        continue;
                    }
                };
                let seq = res
                    .headers()
                    .get("x-chat2-checkpoint-seq")
                    .and_then(|v| v.to_str().ok())
                    .map(str::to_owned);
                if seq.is_some() && seen_seq.is_some() && seq != seen_seq {
                    got.clear();
                    seen_seq = seq;
                    continue;
                }
                if seq.is_some() {
                    seen_seq = seq;
                }
                match res.status().as_u16() {
                    200 => got.clear(),
                    206 => {}
                    // A kept offset past the end of a smaller replacement: start over next time.
                    416 => return Err(SyncError::Protocol("checkpoint range beyond end".into())),
                    404 => return Err(SyncError::Protocol("no checkpoint".into())),
                    code => return Err(SyncError::Protocol(format!("checkpoint HTTP {code}"))),
                }
                loop {
                    match res.chunk().await {
                        Ok(Some(chunk)) => got.extend_from_slice(&chunk),
                        Ok(None) => return Ok(got),
                        Err(err) => {
                            // Keep the bytes; the next attempt resumes at this offset.
                            last_failure = Some(err.without_url().to_string());
                            break;
                        }
                    }
                }
            }
            keep(got, seen_seq);
            Err(SyncError::Protocol(match last_failure {
                Some(failure) => format!("checkpoint fetch exhausted resume attempts: {failure}"),
                None => "checkpoint fetch exhausted resume attempts".into(),
            }))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixed(Option<String>);
    impl TokenSource for Fixed {
        fn bearer(&self) -> Option<String> {
            self.0.clone()
        }
    }

    #[tokio::test]
    async fn socket_urls_match_the_ios_app() {
        let edge = Edge::new(
            "https://edge.example/",
            "org 1",
            "android-1",
            Arc::new(Fixed(Some("a+b".into()))),
        );
        assert_eq!(
            edge.registry_socket().url().await.unwrap(),
            "wss://edge.example/registry/org%201/ws?token=a%2Bb&device=android-1"
        );
        assert_eq!(
            edge.chat_socket("c1").url().await.unwrap(),
            "wss://edge.example/chat2/c1/ws?token=a%2Bb&device=android-1"
        );
        let local = Edge::new(
            "http://10.0.2.2:27640",
            "o",
            "d",
            Arc::new(Fixed(Some("u@o".into()))),
        );
        assert_eq!(
            local.chat_socket("c").url().await.unwrap(),
            "ws://10.0.2.2:27640/chat2/c/ws?token=u%40o&device=d"
        );
    }

    #[tokio::test]
    async fn no_sign_in_is_an_auth_error() {
        let edge = Edge::new("https://edge.example", "o", "d", Arc::new(Fixed(None)));
        assert!(matches!(
            edge.registry_socket().url().await,
            Err(SyncError::Auth(_))
        ));
    }
}
