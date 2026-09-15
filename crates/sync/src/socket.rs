//! WebSocket pump shared by the binary chat and text registry protocols.

use std::time::Duration;
use futures::{SinkExt, StreamExt};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::mpsc;
use tokio_tungstenite::{WebSocketStream, tungstenite::Message as WsMessage};

const PING_INTERVAL: Duration = Duration::from_secs(15);
const SILENCE_LEASE: Duration = Duration::from_secs(45);

pub(crate) async fn pump<S, T>(
    ws: WebSocketStream<S>,
    mut out_rx: mpsc::Receiver<T>,
    in_tx: mpsc::Sender<T>,
    encode: fn(T) -> WsMessage,
    decode: fn(WsMessage) -> Option<T>,
)
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let (mut sink, mut stream) = ws.split();
    let mut ping = tokio::time::interval(PING_INTERVAL);
    ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    ping.tick().await;
    let mut last_rx = tokio::time::Instant::now();
    loop {
        tokio::select! {
            frame = out_rx.recv() => match frame {
                Some(bytes) => {
                    if sink.send(encode(bytes)).await.is_err() {
                        break;
                    }
                }
                None => {
                    let _ = sink.send(WsMessage::Close(None)).await;
                    break;
                }
            },
            frame = stream.next() => match frame {
                Some(Ok(frame)) => {
                    last_rx = tokio::time::Instant::now();
                    if let Some(value) = decode(frame) {
                        if in_tx.send(value).await.is_err() {
                            break;
                        }
                    }
                }
                Some(Err(_)) | None => break,
            },
            _ = ping.tick() => {
                if sink.send(WsMessage::Text("ping".into())).await.is_err() {
                    break;
                }
            }
            _ = tokio::time::sleep_until(last_rx + SILENCE_LEASE) => {
                tracing::warn!("chat2 socket silent past lease; treating as dead");
                break;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::DuplexStream;
    use tokio::task::JoinHandle;
    use tokio_tungstenite::tungstenite::protocol::Role;

    struct Harness {
        server: WebSocketStream<DuplexStream>,
        tx: mpsc::Sender<WsMessage>,
        rx: mpsc::Receiver<WsMessage>,
        task: JoinHandle<()>,
    }

    async fn harness() -> Harness {
        // The byte pipe fills inside one frame, deterministically reproducing
        // an uplink that stops accepting bytes. Real WebSocket framing, no OS
        // buffer-size assumptions or unreachable public addresses.
        let (client, server) = tokio::io::duplex(64);
        let client = WebSocketStream::from_raw_socket(client, Role::Client, None).await;
        let server = WebSocketStream::from_raw_socket(server, Role::Server, None).await;
        let (tx, out) = mpsc::channel(2);
        let (incoming, rx) = mpsc::channel(1);
        let task = tokio::spawn(pump(client, out, incoming, |v| v, |v| {
            match v {
                WsMessage::Text(ref text) if text == "pong" => None,
                WsMessage::Text(_) | WsMessage::Binary(_) => Some(v),
                _ => None,
            }
        }));
        Harness { server, tx, rx, task }
    }

    async fn stall(h: &Harness) {
        h.tx.send(WsMessage::Binary(vec![7; 4096])).await.unwrap();
        tokio::task::yield_now().await;
    }

    async fn finishes(mut task: JoinHandle<()>, within: Duration) {
        if tokio::time::timeout(within, &mut task).await.is_err() {
            task.abort();
            panic!("socket pump did not terminate within {within:?}");
        }
    }

    #[tokio::test(start_paused = true)]
    async fn stalled_write_cannot_disable_silence_deadline() {
        let h = harness().await;
        stall(&h).await;
        finishes(h.task, SILENCE_LEASE + Duration::from_secs(1)).await;
    }

    #[tokio::test(start_paused = true)]
    async fn stalled_write_does_not_block_inbound_frames() {
        let mut h = harness().await;
        stall(&h).await;
        h.server.send(WsMessage::Text("ack".into())).await.unwrap();
        let received = tokio::time::timeout(Duration::from_secs(1), h.rx.recv()).await;
        h.task.abort();
        assert_eq!(received.unwrap(), Some(WsMessage::Text("ack".into())));
    }

    #[tokio::test(start_paused = true)]
    async fn dropping_consumer_cancels_a_stalled_write() {
        let h = harness().await;
        stall(&h).await;
        drop(h.rx);
        finishes(h.task, Duration::from_secs(1)).await;
    }

    #[tokio::test(start_paused = true)]
    async fn full_inbound_queue_has_a_deadline() {
        let mut h = harness().await;
        for _ in 0..2 {
            h.server.send(WsMessage::Text("row".into())).await.unwrap();
            tokio::task::yield_now().await;
        }
        finishes(h.task, SILENCE_LEASE + Duration::from_secs(1)).await;
    }

    #[tokio::test(start_paused = true)]
    async fn pongs_do_not_extend_a_stalled_write_forever() {
        let mut h = harness().await;
        stall(&h).await;
        let peer = tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(5)).await;
                if h.server.send(WsMessage::Text("pong".into())).await.is_err() {
                    return;
                }
            }
        });
        finishes(h.task, SILENCE_LEASE + Duration::from_secs(1)).await;
        peer.abort();
    }

    #[tokio::test(start_paused = true)]
    async fn slow_healthy_link_preserves_text_and_binary_order() {
        let mut h = harness().await;
        let peer = tokio::spawn(async move {
            while let Some(Ok(frame)) = h.server.next().await {
                tokio::time::sleep(Duration::from_secs(2)).await;
                let reply = match frame {
                    WsMessage::Text(ref text) if text == "ping" => WsMessage::Text("pong".into()),
                    other => other,
                };
                if h.server.send(reply).await.is_err() { break; }
            }
        });
        let started = tokio::time::Instant::now();
        for i in 0..30 {
            let frame = if i % 2 == 0 { WsMessage::Text(format!("row-{i}")) }
                else { WsMessage::Binary(vec![i; 8]) };
            h.tx.send(frame.clone()).await.unwrap();
            assert_eq!(tokio::time::timeout(Duration::from_secs(10), h.rx.recv()).await.unwrap(), Some(frame));
        }
        assert!(started.elapsed() > SILENCE_LEASE);
        drop(h.tx);
        finishes(h.task, Duration::from_secs(1)).await;
        peer.abort();
    }
}
