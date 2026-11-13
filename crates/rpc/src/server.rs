//! Server side: dispatch loop over string frames + the WebSocket acceptor.

use std::collections::HashMap;
use std::sync::Arc;

use futures::StreamExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::handshake::server::{
    ErrorResponse, Request as HandshakeRequest, Response as HandshakeResponse,
};
use tokio_tungstenite::tungstenite::http::StatusCode;

use crate::{ClientFrame, RpcError, RpcReply, RpcService};

/// Serve one connection: read client frames from `inbound`, write server frames to `out`.
/// Returns when `inbound` closes; all in-flight request tasks are aborted on exit.
pub async fn serve_connection(
    service: Arc<dyn RpcService>,
    out: mpsc::Sender<String>,
    mut inbound: mpsc::Receiver<String>,
) {
    let mut running: HashMap<u64, tokio::task::AbortHandle> = HashMap::new();
    while let Some(payload) = inbound.recv().await {
        // ndjson: a transport may batch several frames per message.
        for line in payload.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            let frame: ClientFrame = match serde_json::from_str(line) {
                Ok(frame) => frame,
                Err(err) => {
                    tracing::warn!(error = %err, "rpc: dropping malformed client frame");
                    continue;
                }
            };
            running.retain(|_, task| !task.is_finished());
            if frame.cancel {
                if let Some(task) = running.remove(&frame.id) {
                    task.abort();
                }
                continue;
            }
            let Some(method) = frame.method else {
                tracing::warn!(id = frame.id, "rpc: frame has neither method nor cancel");
                continue;
            };
            let task = tokio::spawn(handle_request(
                service.clone(),
                out.clone(),
                frame.id,
                method,
                frame.params,
            ));
            running.insert(frame.id, task.abort_handle());
        }
    }
    for (_, task) in running {
        task.abort();
    }
}

enum OutgoingPayload<'a> {
    Value(&'a serde_json::Value),
    Raw(&'a serde_json::value::RawValue),
}

impl serde::Serialize for OutgoingPayload<'_> {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            OutgoingPayload::Value(v) => v.serialize(serializer),
            OutgoingPayload::Raw(r) => r.serialize(serializer),
        }
    }
}

#[derive(Default, serde::Serialize)]
struct OutgoingServerFrame<'a> {
    id: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    ok: Option<OutgoingPayload<'a>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    err: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    item: Option<OutgoingPayload<'a>>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    done: bool,
}

async fn send_frame(
    out: &mpsc::Sender<String>,
    frame: OutgoingServerFrame<'_>,
) -> Result<(), RpcError> {
    match serde_json::to_string(&frame) {
        Ok(json) => out.send(json).await.map_err(|_| RpcError::Closed),
        Err(err) => {
            tracing::error!(error = %err, "rpc: failed to serialize server frame");
            Err(RpcError::Closed)
        }
    }
}

async fn handle_request(
    service: Arc<dyn RpcService>,
    out: mpsc::Sender<String>,
    id: u64,
    method: String,
    params: serde_json::Value,
) {
    match service.handle(&method, params).await {
        Ok(RpcReply::Value(value)) => {
            let _ = send_frame(
                &out,
                OutgoingServerFrame {
                    id,
                    ok: Some(OutgoingPayload::Value(&value)),
                    ..Default::default()
                },
            )
            .await;
        }
        Ok(RpcReply::Raw(raw)) => {
            let _ = send_frame(
                &out,
                OutgoingServerFrame {
                    id,
                    ok: Some(OutgoingPayload::Raw(&raw)),
                    ..Default::default()
                },
            )
            .await;
        }
        Ok(RpcReply::Stream(mut stream)) => {
            // Only the versioned checkout-PR stream uses an explicit readiness
            // frame. Sending it for legacy streams would make older clients remove
            // their pending stream as if it were a unary response.
            if method == crate::methods::WATCH_CHECKOUT_CHANGE_REQUEST {
                let ready = serde_json::value::RawValue::from_string(r#"{"stream":true}"#.into())
                    .expect("static valid json");
                if send_frame(
                    &out,
                    OutgoingServerFrame {
                        id,
                        ok: Some(OutgoingPayload::Raw(&ready)),
                        ..Default::default()
                    },
                )
                .await
                .is_err()
                {
                    return;
                }
            }
            while let Some(item) = stream.next().await {
                if send_frame(
                    &out,
                    OutgoingServerFrame {
                        id,
                        item: Some(OutgoingPayload::Value(&item)),
                        ..Default::default()
                    },
                )
                .await
                .is_err()
                {
                    return; // connection gone
                }
            }
            let _ = send_frame(
                &out,
                OutgoingServerFrame {
                    id,
                    done: true,
                    ..Default::default()
                },
            )
            .await;
        }
        Ok(RpcReply::StreamRaw(mut stream)) => {
            if method == crate::methods::WATCH_CHECKOUT_CHANGE_REQUEST {
                let ready = serde_json::value::RawValue::from_string(r#"{"stream":true}"#.into())
                    .expect("static valid json");
                if send_frame(
                    &out,
                    OutgoingServerFrame {
                        id,
                        ok: Some(OutgoingPayload::Raw(&ready)),
                        ..Default::default()
                    },
                )
                .await
                .is_err()
                {
                    return;
                }
            }
            while let Some(item) = stream.next().await {
                if send_frame(
                    &out,
                    OutgoingServerFrame {
                        id,
                        item: Some(OutgoingPayload::Raw(&item)),
                        ..Default::default()
                    },
                )
                .await
                .is_err()
                {
                    return;
                }
            }
            let _ = send_frame(
                &out,
                OutgoingServerFrame {
                    id,
                    done: true,
                    ..Default::default()
                },
            )
            .await;
        }
        Err(err) => {
            let err_msg = err.to_string();
            let _ = send_frame(
                &out,
                OutgoingServerFrame {
                    id,
                    err: Some(&err_msg),
                    ..Default::default()
                },
            )
            .await;
        }
    }
}

/// Accept WebSocket connections forever, serving each with `service`.
pub async fn serve_ws_listener(listener: TcpListener, service: Arc<dyn RpcService>) {
    loop {
        match listener.accept().await {
            Ok((stream, peer)) => {
                tracing::debug!(%peer, "rpc: connection accepted");
                tokio::spawn(serve_ws_socket(stream, service.clone()));
            }
            Err(err) => {
                tracing::warn!(error = %err, "rpc: accept failed");
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
        }
    }
}

async fn serve_ws_socket(stream: TcpStream, service: Arc<dyn RpcService>) {
    // Native viewports dial this socket with a bare `connect_async` and send
    // no `Origin` header. A browser always attaches `Origin` to a WebSocket
    // handshake and cannot forge or suppress it from script, and WebSockets
    // are exempt from the Same-Origin Policy — so only rejecting any handshake
    // that carries `Origin` keeps a page the user happens to visit from
    // reaching this local socket. Keep this check.
    //
    // The large `Err` (ErrorResponse) is the shape tungstenite's Callback
    // trait requires; it can't be boxed away here.
    #[allow(clippy::result_large_err)]
    let reject_cross_origin = |req: &HandshakeRequest, resp: HandshakeResponse| {
        if let Some(origin) = req.headers().get("origin") {
            tracing::warn!(
                origin = %String::from_utf8_lossy(origin.as_bytes()),
                "rpc: rejecting handshake carrying an Origin header (cross-origin browser dial)"
            );
            let mut err = ErrorResponse::new(Some("origin not allowed on local IPC".to_string()));
            *err.status_mut() = StatusCode::FORBIDDEN;
            return Err(err);
        }
        Ok(resp)
    };
    let ws = match tokio_tungstenite::accept_hdr_async_with_config(
        stream,
        reject_cross_origin,
        Some(crate::ws::config()),
    )
    .await
    {
        Ok(ws) => ws,
        Err(err) => {
            tracing::warn!(error = %err, "rpc: websocket handshake failed");
            return;
        }
    };
    let (out_tx, out_rx) = mpsc::channel::<String>(256);
    let (in_tx, in_rx) = mpsc::channel::<String>(256);

    // Pump: socket <-> string channels. Ends when either side closes.
    let pump = tokio::spawn(async move {
        if let Some(reason) = crate::ws::pump(ws, out_rx, in_tx).await {
            tracing::warn!(%reason, "rpc: lost a viewport connection");
        }
    });

    serve_connection(service, out_tx, in_rx).await;
    pump.abort();
}
