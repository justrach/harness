//! This computer's iOS Simulators, watched and driven from another device:
//! the phone's Simulators screen shows a booted simulator live and sends
//! taps, swipes, text, and hardware buttons back.
//!
//! Listing, booting, and shutting down use `xcrun simctl` directly. The live
//! screen and input come from the streaming helper ([`hub`]), which runs only
//! after the user sets it up and only on loopback. Nothing reaches it except
//! this module: frames are pulled from its MJPEG route and re-emitted on
//! `WatchSimulatorScreen` (one pump per simulator, shared by every viewer,
//! latest frame wins), and input arrives typed (`SimulatorInput`) and is
//! translated into its HID socket messages. Its shell-exec and dashboard
//! routes are never exposed.

mod hub;
mod keys;
mod mjpeg;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::Duration;

use base64::Engine as _;
use futures::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::sync::watch;
use tokio_tungstenite::tungstenite::Message;

use hub::{Hub, Install};

const SIMCTL_TIMEOUT: Duration = Duration::from_secs(20);
const BOOT_TIMEOUT: Duration = Duration::from_secs(120);
/// A pump whose MJPEG connection drops retries this many times before it ends
/// the viewers' streams.
const PUMP_RETRIES: u32 = 5;
/// Gap between the key presses of typed text: sent back to back, the
/// simulator drops keys and lets Shift run on.
const KEY_GAP: Duration = Duration::from_millis(6);

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SimulatorDevice {
    pub id: String,
    pub name: String,
    /// e.g. `iOS 27.0`.
    pub runtime: String,
    pub booted: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SimulatorList {
    /// False off macOS or without Xcode; `reason` says which.
    pub supported: bool,
    pub reason: Option<String>,
    /// The streaming helper is installed (`SetUpSimulators` has run).
    pub set_up: bool,
    pub devices: Vec<SimulatorDevice>,
}

/// One frame of a simulator's screen.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenFrame {
    pub seq: u64,
    /// Base64 JPEG, downscaled on this computer.
    pub jpeg: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum TouchPhase {
    Begin,
    Move,
    End,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SimulatorButton {
    Home,
    Lock,
    VolumeUp,
    VolumeDown,
}

/// Input from a viewer. Touch coordinates are fractions of the screen (0..1).
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum SimulatorInput {
    Touch { phase: TouchPhase, x: f64, y: f64 },
    Button { button: SimulatorButton },
    Text { text: String },
    Key { key: String },
}

type FrameSender = watch::Sender<Option<Arc<ScreenFrame>>>;

type InputSink = futures::stream::SplitSink<
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    Message,
>;

#[derive(Clone)]
pub struct Simulators {
    inner: Arc<Inner>,
}

struct Inner {
    tools_dir: PathBuf,
    install: Install,
    hub: tokio::sync::Mutex<Option<Hub>>,
    installing: tokio::sync::Mutex<()>,
    /// Each simulator's frame pump, while one runs (the pump owns the sender).
    screens: Mutex<HashMap<String, Weak<FrameSender>>>,
    inputs: tokio::sync::Mutex<HashMap<String, InputSink>>,
    http: reqwest::Client,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Simulator ids are CoreSimulator UDIDs; anything else never reaches a URL or a command line.
fn check_id(id: &str) -> Result<(), String> {
    let ok = id.len() == 36
        && id.chars().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == '-'
            } else {
                c.is_ascii_hexdigit()
            }
        });
    ok.then_some(())
        .ok_or_else(|| format!("not a simulator id: {id}"))
}

impl Simulators {
    /// `tools_dir` holds the streaming helper's install (`<data>/tools`).
    pub fn new(tools_dir: PathBuf) -> Self {
        Self {
            inner: Arc::new(Inner {
                install: Install::new(&tools_dir),
                tools_dir,
                hub: tokio::sync::Mutex::new(None),
                installing: tokio::sync::Mutex::new(()),
                screens: Mutex::new(HashMap::new()),
                inputs: tokio::sync::Mutex::new(HashMap::new()),
                http: reqwest::Client::new(),
            }),
        }
    }

    pub async fn list(&self) -> SimulatorList {
        let set_up = self.inner.install.is_installed();
        match list_devices().await {
            Ok(devices) => SimulatorList {
                supported: true,
                reason: None,
                set_up,
                devices,
            },
            Err(reason) => SimulatorList {
                supported: false,
                reason: Some(reason),
                set_up,
                devices: Vec::new(),
            },
        }
    }

    /// Install the streaming helper (the user's consent step), then list.
    pub async fn set_up(&self) -> Result<SimulatorList, String> {
        {
            let _one = self.inner.installing.lock().await;
            self.inner.install.install().await?;
        }
        Ok(self.list().await)
    }

    pub async fn boot(&self, id: &str) -> Result<(), String> {
        check_id(id)?;
        let out = simctl(&["boot", id], BOOT_TIMEOUT).await;
        // Booting a booted simulator is a no-op, not a failure.
        match out {
            Err(e) if !e.contains("current state: Booted") => Err(e),
            _ => Ok(()),
        }
    }

    pub async fn shutdown_device(&self, id: &str) -> Result<(), String> {
        check_id(id)?;
        match simctl(&["shutdown", id], SIMCTL_TIMEOUT).await {
            Err(e) if !e.contains("current state: Shutdown") => Err(e),
            _ => Ok(()),
        }
    }

    async fn hub_origin(&self) -> Result<String, String> {
        let mut hub = self.inner.hub.lock().await;
        if let Some(running) = hub.as_mut()
            && running.is_alive()
        {
            return Ok(running.origin.clone());
        }
        // A dead hub takes its input sockets with it.
        self.inner.inputs.lock().await.clear();
        std::fs::create_dir_all(&self.inner.tools_dir).map_err(|e| e.to_string())?;
        let started = Hub::start(&self.inner.install, &self.inner.tools_dir).await?;
        let origin = started.origin.clone();
        *hub = Some(started);
        Ok(origin)
    }

    /// The simulator's screen: the latest frame now and every new one after.
    /// Viewers share one pump; it stops when the last one goes.
    pub async fn watch_screen(
        &self,
        id: &str,
    ) -> Result<watch::Receiver<Option<Arc<ScreenFrame>>>, String> {
        check_id(id)?;
        let origin = self.hub_origin().await?;
        let mut screens = lock(&self.inner.screens);
        if let Some(tx) = screens.get(id).and_then(Weak::upgrade) {
            return Ok(tx.subscribe());
        }
        let (tx, rx) = watch::channel(None);
        let tx = Arc::new(tx);
        screens.insert(id.to_string(), Arc::downgrade(&tx));
        let url = format!("{origin}/vendor/serve-sim/helper/{id}/stream.mjpeg");
        tokio::spawn(pump(self.inner.http.clone(), url, tx));
        Ok(rx)
    }

    pub async fn input(&self, id: &str, input: SimulatorInput) -> Result<(), String> {
        check_id(id)?;
        let messages = hid_messages(&input)?;
        let origin = self.hub_origin().await?;
        let mut inputs = self.inner.inputs.lock().await;
        for attempt in 0..2 {
            if !inputs.contains_key(id) {
                let ws = format!(
                    "{}/vendor/serve-sim/helper/ws?device={id}",
                    origin.replacen("http://", "ws://", 1)
                );
                let (socket, _) = tokio_tungstenite::connect_async(ws)
                    .await
                    .map_err(|e| format!("connecting to the simulator: {e}"))?;
                let (sink, mut stream) = socket.split();
                // The helper sends screen config frames; nothing here needs them.
                tokio::spawn(async move { while stream.next().await.is_some() {} });
                inputs.insert(id.to_string(), sink);
            }
            let sink = inputs.get_mut(id).expect("inserted above");
            let mut sent = Ok(());
            for (i, message) in messages.iter().enumerate() {
                if i > 0 {
                    tokio::time::sleep(KEY_GAP).await;
                }
                if let Err(e) = sink.send(Message::Binary(message.clone())).await {
                    sent = Err(e);
                    break;
                }
            }
            match sent {
                Ok(()) => return Ok(()),
                Err(e) if attempt == 1 => return Err(format!("sending input: {e}")),
                Err(_) => {
                    inputs.remove(id);
                }
            }
        }
        Ok(())
    }

    /// Stop the helper; simulators themselves keep running (they're the user's).
    pub async fn shutdown(&self) {
        self.inner.inputs.lock().await.clear();
        lock(&self.inner.screens).clear();
        self.inner.hub.lock().await.take();
    }
}

/// Opcode + JSON, the hub's HID socket framing.
fn hid(op: u8, body: &impl Serialize) -> Vec<u8> {
    let mut out = vec![op];
    out.extend(serde_json::to_vec(body).expect("plain JSON"));
    out
}

const OP_TOUCH: u8 = 3;
const OP_BUTTON: u8 = 4;
const OP_KEY: u8 = 6;

fn hid_messages(input: &SimulatorInput) -> Result<Vec<Vec<u8>>, String> {
    Ok(match input {
        SimulatorInput::Touch { phase, x, y } => {
            if !x.is_finite() || !y.is_finite() {
                return Err("touch outside the screen".into());
            }
            vec![hid(
                OP_TOUCH,
                &serde_json::json!({ "type": phase, "x": x.clamp(0.0, 1.0), "y": y.clamp(0.0, 1.0) }),
            )]
        }
        SimulatorInput::Button { button } => {
            // Home is a named button; the rest are consumer-page HID usages.
            let body = match button {
                SimulatorButton::Home => serde_json::json!({ "button": "home" }),
                SimulatorButton::Lock => {
                    serde_json::json!({ "button": "power", "page": 12, "usage": 48 })
                }
                SimulatorButton::VolumeUp => {
                    serde_json::json!({ "button": "volume-up", "page": 12, "usage": 233 })
                }
                SimulatorButton::VolumeDown => {
                    serde_json::json!({ "button": "volume-down", "page": 12, "usage": 234 })
                }
            };
            vec![hid(OP_BUTTON, &body)]
        }
        SimulatorInput::Text { text } => keys::type_text(text)
            .map_err(|c| format!("{c:?} can't be typed on a US keyboard"))?
            .iter()
            .map(|event| hid(OP_KEY, event))
            .collect(),
        SimulatorInput::Key { key } => {
            let usage = keys::named(key).ok_or_else(|| format!("unknown key {key:?}"))?;
            [keys::KeyKind::Down, keys::KeyKind::Up]
                .into_iter()
                .map(|kind| hid(OP_KEY, &keys::KeyEvent { kind, usage }))
                .collect()
        }
    })
}

/// Pull frames from the helper into `tx` until the last viewer leaves.
async fn pump(http: reqwest::Client, url: String, tx: Arc<FrameSender>) {
    let mut seq = 0u64;
    let mut failures = 0;
    while failures <= PUMP_RETRIES && !tx.is_closed() {
        let response = match http.get(&url).send().await {
            Ok(r) if r.status().is_success() => r,
            Ok(r) => {
                tracing::warn!(status = %r.status(), "simulator stream refused");
                failures += 1;
                tokio::time::sleep(Duration::from_millis(500 * u64::from(failures))).await;
                continue;
            }
            Err(error) => {
                tracing::warn!(%error, "simulator stream unreachable");
                failures += 1;
                tokio::time::sleep(Duration::from_millis(500 * u64::from(failures))).await;
                continue;
            }
        };
        let mut body = response.bytes_stream();
        let mut parser = mjpeg::MjpegParser::default();
        loop {
            let chunk = tokio::select! {
                chunk = body.next() => chunk,
                () = tx.closed() => return,
            };
            let Some(Ok(chunk)) = chunk else { break };
            let Ok(frames) = parser.push(&chunk) else {
                break;
            };
            // Only the newest frame of a chunk matters to a viewer.
            if let Some(jpeg) = frames.last() {
                failures = 0;
                seq += 1;
                let frame = ScreenFrame {
                    seq,
                    jpeg: base64::engine::general_purpose::STANDARD.encode(jpeg),
                };
                if tx.send(Some(Arc::new(frame))).is_err() {
                    return;
                }
            }
        }
        failures += 1;
    }
}

async fn simctl(args: &[&str], timeout: Duration) -> Result<String, String> {
    let mut cmd = tokio::process::Command::new("xcrun");
    cmd.arg("simctl").args(args).kill_on_drop(true);
    let output = tokio::time::timeout(timeout, cmd.output())
        .await
        .map_err(|_| format!("simctl {} timed out", args[0]))?
        .map_err(|_| "Xcode wasn't found on this computer.".to_string())?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

async fn list_devices() -> Result<Vec<SimulatorDevice>, String> {
    if !cfg!(target_os = "macos") {
        return Err("iOS Simulators need a Mac with Xcode.".into());
    }
    let json = simctl(&["list", "devices", "available", "-j"], SIMCTL_TIMEOUT).await?;
    parse_devices(&json)
}

#[derive(Deserialize)]
struct SimctlList {
    devices: HashMap<String, Vec<SimctlDevice>>,
}

#[derive(Deserialize)]
struct SimctlDevice {
    udid: String,
    name: String,
    state: String,
}

/// `com.apple.CoreSimulator.SimRuntime.iOS-27-0` → `iOS 27.0`; other platforms → None.
fn ios_runtime(key: &str) -> Option<String> {
    let version = key.rsplit('.').next()?.strip_prefix("iOS-")?;
    Some(format!("iOS {}", version.replace('-', ".")))
}

fn parse_devices(json: &str) -> Result<Vec<SimulatorDevice>, String> {
    let list: SimctlList =
        serde_json::from_str(json).map_err(|e| format!("reading simctl's device list: {e}"))?;
    let mut devices: Vec<SimulatorDevice> = list
        .devices
        .into_iter()
        .filter_map(|(key, devices)| Some((ios_runtime(&key)?, devices)))
        .flat_map(|(runtime, devices)| {
            devices.into_iter().map(move |d| SimulatorDevice {
                id: d.udid,
                name: d.name,
                runtime: runtime.clone(),
                booted: d.state == "Booted",
            })
        })
        .collect();
    // Booted first, then newest runtime, then by name.
    devices.sort_by(|a, b| {
        b.booted
            .cmp(&a.booted)
            .then_with(|| version_key(&b.runtime).cmp(&version_key(&a.runtime)))
            .then_with(|| a.name.cmp(&b.name))
    });
    Ok(devices)
}

fn version_key(runtime: &str) -> Vec<u32> {
    runtime
        .trim_start_matches("iOS ")
        .split('.')
        .filter_map(|p| p.parse().ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn simctl_list_becomes_ios_devices_booted_first_newest_runtime_next() {
        let json = r#"{"devices":{
            "com.apple.CoreSimulator.SimRuntime.iOS-26-2":[
                {"udid":"11111111-1111-1111-1111-111111111111","name":"iPhone 16","state":"Shutdown","isAvailable":true}],
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
                {"udid":"22222222-2222-2222-2222-222222222222","name":"iPhone 17","state":"Shutdown","isAvailable":true},
                {"udid":"33333333-3333-3333-3333-333333333333","name":"iPhone 17 Pro","state":"Booted","isAvailable":true}],
            "com.apple.CoreSimulator.SimRuntime.watchOS-12-0":[
                {"udid":"44444444-4444-4444-4444-444444444444","name":"Watch","state":"Booted","isAvailable":true}]
        }}"#;
        let devices = parse_devices(json).unwrap();
        let names: Vec<_> = devices
            .iter()
            .map(|d| (d.name.as_str(), d.runtime.as_str(), d.booted))
            .collect();
        assert_eq!(
            names,
            vec![
                ("iPhone 17 Pro", "iOS 27.0", true),
                ("iPhone 17", "iOS 27.0", false),
                ("iPhone 16", "iOS 26.2", false),
            ]
        );
    }

    #[test]
    fn only_udids_reach_urls_and_commands() {
        assert!(check_id("6BBA9FD8-EFAD-45B7-B9FC-30715804D2A1").is_ok());
        for bad in [
            "",
            "booted",
            "../../etc",
            "6BBA9FD8-EFAD-45B7-B9FC-30715804D2A1/x",
            "6BBA9FD8xEFADx45B7xB9FCx30715804D2A1",
        ] {
            assert!(check_id(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn input_becomes_the_hubs_opcode_and_json() {
        let touch = hid_messages(&SimulatorInput::Touch {
            phase: TouchPhase::Begin,
            x: 1.4,
            y: 0.25,
        })
        .unwrap();
        assert_eq!(
            touch,
            vec![[&[OP_TOUCH][..], br#"{"type":"begin","x":1.0,"y":0.25}"#].concat()]
        );
        let home = hid_messages(&SimulatorInput::Button {
            button: SimulatorButton::Home,
        })
        .unwrap();
        assert_eq!(
            home,
            vec![[&[OP_BUTTON][..], br#"{"button":"home"}"#].concat()]
        );
        let text = hid_messages(&SimulatorInput::Text { text: "a".into() }).unwrap();
        assert_eq!(
            text,
            vec![
                [&[OP_KEY][..], br#"{"type":"down","usage":4}"#].concat(),
                [&[OP_KEY][..], br#"{"type":"up","usage":4}"#].concat(),
            ]
        );
        assert!(
            hid_messages(&SimulatorInput::Touch {
                phase: TouchPhase::End,
                x: f64::NAN,
                y: 0.0
            })
            .is_err()
        );
        assert!(hid_messages(&SimulatorInput::Key { key: "f13".into() }).is_err());
    }
}
