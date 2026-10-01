//! OTLP on the wire: spans encoded as OTLP/HTTP JSON
//! (`ExportTraceServiceRequest`), the standard `OTEL_EXPORTER_OTLP_*`
//! settings, and where requests go: an OTLP/HTTP endpoint, or a file of JSON
//! lines (one request per line, the format the collector's `otlpjsonfile`
//! receiver reads).

use std::io::Write;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, anyhow, bail};
use serde_json::{Value, json};

use crate::otel::{Attr, AttrValue, Span, SpanKind, Status};

/// Wall-clock start of a run. Traces carry only milliseconds since the run
/// started, so the start is the trace file's last write minus the run's
/// latest event time.
pub fn run_start_unix_ms(modified: SystemTime, last_t: u64) -> u64 {
    let modified = modified
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64);
    modified.saturating_sub(last_t)
}

/// One OTLP/HTTP JSON `ExportTraceServiceRequest`.
pub fn export_request(resource: &[Attr], spans: &[Span], run_start_unix_ms: u64) -> Value {
    let spans: Vec<Value> = spans
        .iter()
        .map(|span| span_json(span, run_start_unix_ms))
        .collect();
    json!({
        "resourceSpans": [{
            "resource": { "attributes": attrs_json(resource) },
            "scopeSpans": [{
                "scope": { "name": "harness-observe", "version": env!("CARGO_PKG_VERSION") },
                "spans": spans,
            }],
        }],
    })
}

fn span_json(span: &Span, base: u64) -> Value {
    let events: Vec<Value> = span
        .events
        .iter()
        .map(|e| json!({ "timeUnixNano": nanos(base + e.at_ms), "name": e.name, "attributes": attrs_json(&e.attrs) }))
        .collect();
    let mut value = json!({
        "traceId": hex(&span.trace_id),
        "spanId": hex(&span.span_id),
        "name": span.name,
        "kind": match span.kind { SpanKind::Internal => 1, SpanKind::Client => 3 },
        "startTimeUnixNano": nanos(base + span.start_ms),
        "endTimeUnixNano": nanos(base + span.end_ms),
        "attributes": attrs_json(&span.attrs),
        "events": events,
        "status": match &span.status {
            Status::Unset => json!({}),
            Status::Error(message) => json!({ "code": 2, "message": message }),
        },
    });
    if let Some(parent) = span.parent {
        value["parentSpanId"] = json!(hex(&parent));
    }
    value
}

fn attrs_json(attrs: &[Attr]) -> Vec<Value> {
    attrs
        .iter()
        .map(|a| {
            let value = match &a.value {
                AttrValue::Str(v) => json!({ "stringValue": v }),
                // OTLP JSON carries 64-bit integers as strings.
                AttrValue::Int(v) => json!({ "intValue": v.to_string() }),
                AttrValue::Double(v) => json!({ "doubleValue": v }),
                AttrValue::Bool(v) => json!({ "boolValue": v }),
            };
            json!({ "key": a.key, "value": value })
        })
        .collect()
}

fn nanos(ms: u64) -> String {
    (u128::from(ms) * 1_000_000).to_string()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The OTLP/HTTP traces URL: `--endpoint` (with `/v1/traces` added), else
/// `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` as is, else
/// `OTEL_EXPORTER_OTLP_ENDPOINT` with `/v1/traces` added.
pub fn traces_endpoint(flag: Option<&str>, env: &dyn Fn(&str) -> Option<String>) -> Option<String> {
    let with_path = |base: &str| {
        let base = base.trim_end_matches('/');
        if base.ends_with("/v1/traces") {
            base.to_string()
        } else {
            format!("{base}/v1/traces")
        }
    };
    let var = |name: &str| env(name).filter(|v| !v.trim().is_empty());
    if let Some(flag) = flag {
        return Some(with_path(flag));
    }
    if let Some(url) = var("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT") {
        return Some(url);
    }
    var("OTEL_EXPORTER_OTLP_ENDPOINT").map(|base| with_path(&base))
}

/// Request headers: `OTEL_EXPORTER_OTLP_HEADERS`, then
/// `OTEL_EXPORTER_OTLP_TRACES_HEADERS` (comma-separated, percent-encoded
/// `key=value` pairs), then each `--header key=value`.
pub fn export_headers(
    flags: &[String],
    env: &dyn Fn(&str) -> Option<String>,
) -> anyhow::Result<Vec<(String, String)>> {
    let mut headers = Vec::new();
    for name in [
        "OTEL_EXPORTER_OTLP_HEADERS",
        "OTEL_EXPORTER_OTLP_TRACES_HEADERS",
    ] {
        for pair in env(name)
            .unwrap_or_default()
            .split(',')
            .filter(|p| !p.trim().is_empty())
        {
            let (key, value) = pair
                .split_once('=')
                .ok_or_else(|| anyhow!("{name}: `{}` is not key=value", pair.trim()))?;
            headers.push((percent_decode(key.trim()), percent_decode(value.trim())));
        }
    }
    for flag in flags {
        let (key, value) = flag
            .split_once('=')
            .ok_or_else(|| anyhow!("--header `{flag}` is not key=value"))?;
        headers.push((key.trim().to_string(), value.trim().to_string()));
    }
    Ok(headers)
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let pair = bytes
            .get(i + 1..i + 3)
            .and_then(|h| std::str::from_utf8(h).ok());
        match (bytes[i], pair.and_then(|h| u8::from_str_radix(h, 16).ok())) {
            (b'%', Some(byte)) => {
                out.push(byte);
                i += 3;
            }
            (byte, _) => {
                out.push(byte);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Where export requests go.
pub enum Sink {
    /// One JSON request per line.
    Lines(Box<dyn Write>),
    Http(Http),
}

pub struct Http {
    url: String,
    headers: Vec<(String, String)>,
    client: reqwest::Client,
    runtime: tokio::runtime::Runtime,
}

impl Sink {
    pub fn lines(out: Box<dyn Write>) -> Self {
        Sink::Lines(out)
    }

    pub fn http(url: &str, headers: Vec<(String, String)>) -> anyhow::Result<Self> {
        let mut client = reqwest::Client::builder().timeout(Duration::from_secs(30));
        // A collector on this machine is reached directly, whatever the system proxy says.
        if is_loopback(url) {
            client = client.no_proxy();
        }
        Ok(Sink::Http(Http {
            url: url.to_string(),
            headers,
            client: client.build()?,
            runtime: tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()?,
        }))
    }

    /// Where requests go, for status lines.
    pub fn target(&self) -> &str {
        match self {
            Sink::Lines(_) => "the output file",
            Sink::Http(http) => &http.url,
        }
    }

    /// Sends one request. Returns how many spans the backend reported rejecting.
    pub fn send(&mut self, request: &Value) -> anyhow::Result<u64> {
        match self {
            Sink::Lines(out) => {
                serde_json::to_writer(&mut *out, request)?;
                writeln!(out)?;
                out.flush()?;
                Ok(0)
            }
            Sink::Http(http) => http.post(request),
        }
    }
}

impl Http {
    fn post(&self, request: &Value) -> anyhow::Result<u64> {
        let body = serde_json::to_vec(request)?;
        let mut post = self
            .client
            .post(&self.url)
            .header("content-type", "application/json")
            .body(body);
        for (key, value) in &self.headers {
            post = post.header(key.as_str(), value.as_str());
        }
        self.runtime.block_on(async {
            let response = post
                .send()
                .await
                .with_context(|| format!("sending to {}", self.url))?;
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            if !status.is_success() {
                bail!(
                    "{} answered {status}: {}",
                    self.url,
                    text.chars().take(300).collect::<String>()
                );
            }
            // OTLP reports spans it dropped in `partialSuccess`.
            let rejected = serde_json::from_str::<Value>(&text)
                .ok()
                .and_then(|v| {
                    v["partialSuccess"]["rejectedSpans"]
                        .as_str()
                        .and_then(|n| n.parse().ok())
                        .or(v["partialSuccess"]["rejectedSpans"].as_u64())
                })
                .unwrap_or(0);
            Ok(rejected)
        })
    }
}

fn is_loopback(url: &str) -> bool {
    let rest = url.split_once("://").map_or(url, |(_, rest)| rest);
    let authority = rest.split('/').next().unwrap_or("");
    let host = match authority.strip_prefix('[') {
        Some(v6) => v6.split(']').next().unwrap_or(""),
        None => authority.split(':').next().unwrap_or(""),
    };
    matches!(host, "localhost" | "127.0.0.1" | "::1")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::otel::{Converter, s};
    use crate::summary::tests::RUN;
    use std::io::{BufRead, BufReader, Read};
    use std::net::TcpListener;

    fn spans() -> Vec<Span> {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("r1.jsonl");
        std::fs::write(&path, RUN).unwrap();
        let mut converter = Converter::new(&crate::discover::TraceFile::open(&path).unwrap());
        for line in RUN.lines() {
            converter.push_line(line);
        }
        let mut spans = converter.take();
        spans.extend(converter.finish());
        spans
    }

    #[test]
    fn otlp_json_shape() {
        let spans = spans();
        let request = export_request(&[s("service.name", "graff")], &spans[..1], 1_000);
        let span = &request["resourceSpans"][0]["scopeSpans"][0]["spans"][0];
        assert_eq!(span["traceId"].as_str().unwrap().len(), 32);
        assert_eq!(span["spanId"].as_str().unwrap().len(), 16);
        assert_eq!(span["parentSpanId"].as_str().unwrap().len(), 16);
        assert_eq!(span["kind"], 3);
        let start: u128 = span["startTimeUnixNano"].as_str().unwrap().parse().unwrap();
        assert_eq!(start, u128::from(1_000 + spans[0].start_ms) * 1_000_000);
        let attrs = span["attributes"].as_array().unwrap();
        let tokens = attrs
            .iter()
            .find(|a| a["key"] == "graff.context_tokens")
            .unwrap();
        assert!(tokens["value"]["intValue"].is_string());
        let resource = &request["resourceSpans"][0]["resource"]["attributes"][0];
        assert_eq!(resource["value"]["stringValue"], "graff");
        assert_eq!(
            request["resourceSpans"][0]["scopeSpans"][0]["scope"]["name"],
            "harness-observe"
        );
        let failed = spans
            .iter()
            .find(|s| matches!(s.status, Status::Error(_)))
            .unwrap();
        let failed = export_request(&[], std::slice::from_ref(failed), 0);
        assert_eq!(
            failed["resourceSpans"][0]["scopeSpans"][0]["spans"][0]["status"]["code"],
            2
        );
        assert_eq!(
            run_start_unix_ms(UNIX_EPOCH + Duration::from_millis(10_000), 4_000),
            6_000
        );
    }

    #[test]
    fn endpoint_and_headers_follow_the_otel_environment() {
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |name: &str| {
                pairs
                    .iter()
                    .find(|(k, _)| *k == name)
                    .map(|(_, v)| v.to_string())
            }
        };
        let none = env(&[]);
        assert_eq!(
            traces_endpoint(Some("http://localhost:4318/"), &none).unwrap(),
            "http://localhost:4318/v1/traces"
        );
        assert_eq!(
            traces_endpoint(Some("https://x.example/otel/v1/traces"), &none).unwrap(),
            "https://x.example/otel/v1/traces"
        );
        assert_eq!(traces_endpoint(None, &none), None);
        let base = env(&[("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318")]);
        assert_eq!(
            traces_endpoint(None, &base).unwrap(),
            "http://collector:4318/v1/traces"
        );
        let exact = env(&[
            ("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318"),
            (
                "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
                "http://traces:9999/custom",
            ),
        ]);
        assert_eq!(
            traces_endpoint(None, &exact).unwrap(),
            "http://traces:9999/custom"
        );
        let headers = env(&[(
            "OTEL_EXPORTER_OTLP_HEADERS",
            "authorization=Basic%20abc, x-team = obs",
        )]);
        let got = export_headers(&["x-extra=1".into()], &headers).unwrap();
        assert_eq!(
            got,
            [
                ("authorization".to_string(), "Basic abc".to_string()),
                ("x-team".to_string(), "obs".to_string()),
                ("x-extra".to_string(), "1".to_string())
            ]
        );
        assert!(export_headers(&["broken".into()], &none).is_err());
        assert_eq!(percent_decode("a%2Cb%zz"), "a,b%zz");
        assert!(is_loopback("http://localhost:4318/v1/traces"));
        assert!(is_loopback("http://[::1]:4318"));
        assert!(!is_loopback("https://otel.example.com/v1/traces"));
    }

    #[test]
    fn posts_json_to_the_collector_and_reads_partial_success() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/v1/traces", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut head = Vec::new();
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if line == "\r\n" {
                    break;
                }
                head.push(line.trim_end().to_string());
            }
            let length: usize = head
                .iter()
                .find_map(|h| {
                    h.to_ascii_lowercase()
                        .strip_prefix("content-length:")
                        .map(|v| v.trim().parse().unwrap())
                })
                .unwrap();
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            let reply = r#"{"partialSuccess":{"rejectedSpans":"2"}}"#;
            write!(&stream, "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{reply}", reply.len()).unwrap();
            (head, body)
        });
        let mut sink = Sink::http(&url, vec![("x-token".into(), "secret".into())]).unwrap();
        let request = export_request(&[s("service.name", "graff")], &spans(), 0);
        assert_eq!(sink.send(&request).unwrap(), 2);
        let (head, body) = server.join().unwrap();
        assert_eq!(head[0], "POST /v1/traces HTTP/1.1");
        assert!(
            head.iter()
                .any(|h| h.eq_ignore_ascii_case("content-type: application/json"))
        );
        assert!(
            head.iter()
                .any(|h| h.eq_ignore_ascii_case("x-token: secret"))
        );
        let sent: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(
            sent["resourceSpans"][0]["scopeSpans"][0]["spans"]
                .as_array()
                .unwrap()
                .len(),
            15
        );
    }

    #[test]
    fn writes_one_request_per_line() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("spans.jsonl");
        let mut sink = Sink::lines(Box::new(std::fs::File::create(&path).unwrap()));
        let request = export_request(&[], &spans()[..2], 0);
        sink.send(&request).unwrap();
        sink.send(&request).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert_eq!(text.lines().count(), 2);
        assert!(
            text.lines()
                .all(|l| serde_json::from_str::<Value>(l).is_ok())
        );
    }
}
