//! This computer's iOS Simulators, watched and driven from another device:
//! the phone's Simulators screen shows a booted simulator live and sends
//! taps, swipes, text, and hardware buttons back.
//!
//! Listing, booting, and shutting down use `xcrun simctl` directly. The live
//! screen and input come from the streaming helper ([`hub`]), which runs only
//! after the user sets it up, only on loopback, and only for a caller holding
//! its per-run token. Nothing reaches it except this module: frames are pulled
//! from its MJPEG route and re-emitted on `WatchSimulatorScreen` (one pump per
//! simulator, shared by every viewer, latest frame wins, each viewer capped to
//! its own frame rate), and input arrives typed (`SimulatorInput`) and is
//! translated into its HID socket messages. Its other routes are never served.
//!
//! Simulator ids must be the UDID of an iOS Simulator `simctl` lists right
//! now; no other string reaches a URL or a command line. All of this is macOS
//! only: elsewhere `ListSimulators` says unsupported and the rest refuse.

mod hub;
mod keys;
mod mjpeg;

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::Duration;

use tokio::time::Instant;

use base64::Engine as _;
use futures::stream::BoxStream;
use futures::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::sync::watch;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::http::header::AUTHORIZATION;

use hub::{Endpoint, Hub, Install};

const XCRUN: &str = "/usr/bin/xcrun";
const SIMCTL_TIMEOUT: Duration = Duration::from_secs(20);
const BOOT_TIMEOUT: Duration = Duration::from_secs(120);
/// A pump whose MJPEG connection drops retries this many times before it ends
/// the viewers' streams.
const PUMP_RETRIES: u32 = 5;
/// Gap between the key presses of typed text: sent back to back, the
/// simulator drops keys and lets Shift run on.
const KEY_GAP: Duration = Duration::from_millis(6);
/// The most characters one `SimulatorInput` may type (each is a key press).
const MAX_TEXT_CHARS: usize = 500;
/// With nobody watching for this long, the helper stops: while it runs, its
/// capture keeps a low floor frame rate going on this computer.
const IDLE_STOP: Duration = Duration::from_secs(60);
/// A viewer that names no frame rate gets this many frames a second.
pub const DEFAULT_VIEWER_FPS: u32 = 15;
const UNSUPPORTED: &str = "iOS Simulators need a Mac with Xcode.";
/// Test seam: a comma-separated list of UDIDs. When set, only those
/// simulators are listed or accepted, so an automated run can never boot,
/// shut down, or drive a simulator it didn't create.
pub const ALLOWLIST_ENV: &str = "HARNESS_SIMULATOR_ALLOWLIST";

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
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
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
pub type FrameReceiver = watch::Receiver<Option<Arc<ScreenFrame>>>;

type InputSink = futures::stream::SplitSink<
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    Message,
>;

/// An open HID socket, and the helper run it belongs to.
struct InputSocket {
    origin: String,
    sink: InputSink,
}

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
    inputs: tokio::sync::Mutex<HashMap<String, InputSocket>>,
    http: reqwest::Client,
    /// The last watch or input; with no pump running for `idle_stop` after
    /// it, the helper's watchdog stops it.
    last_used: Mutex<Instant>,
    idle_stop: Duration,
    allowlist: Option<HashSet<String>>,
    /// Tests: a fixed helper and device list instead of the real ones.
    fake: Option<Fake>,
}

struct Fake {
    endpoint: Endpoint,
    devices: Vec<SimulatorDevice>,
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
        .ok_or_else(|| format!("not a simulator id: {id:?}"))
}

fn allowlist_from(value: Option<String>) -> Option<HashSet<String>> {
    let value = value?;
    Some(
        value
            .split(',')
            .map(|id| id.trim().to_ascii_uppercase())
            .filter(|id| !id.is_empty())
            .collect(),
    )
}

impl Simulators {
    /// `tools_dir` holds the streaming helper's install (`<data>/tools`).
    pub fn new(tools_dir: PathBuf) -> Self {
        let allowlist = allowlist_from(std::env::var(ALLOWLIST_ENV).ok());
        Self::build(tools_dir, allowlist, IDLE_STOP, None)
    }

    fn build(
        tools_dir: PathBuf,
        allowlist: Option<HashSet<String>>,
        idle_stop: Duration,
        fake: Option<Fake>,
    ) -> Self {
        Self {
            inner: Arc::new(Inner {
                install: Install::new(&tools_dir),
                tools_dir,
                hub: tokio::sync::Mutex::new(None),
                installing: tokio::sync::Mutex::new(()),
                screens: Mutex::new(HashMap::new()),
                inputs: tokio::sync::Mutex::new(HashMap::new()),
                // Loopback only: never through a proxy, which would see the token.
                http: reqwest::Client::builder()
                    .no_proxy()
                    .build()
                    .unwrap_or_default(),
                last_used: Mutex::new(Instant::now()),
                idle_stop,
                allowlist,
                fake,
            }),
        }
    }

    fn supported(&self) -> bool {
        self.inner.fake.is_some() || cfg!(target_os = "macos")
    }

    fn allowed(&self, id: &str) -> bool {
        self.inner
            .allowlist
            .as_ref()
            .is_none_or(|ids| ids.contains(&id.to_ascii_uppercase()))
    }

    /// A well-formed id this engine may act on, on a host that has simulators.
    fn check_usable(&self, id: &str) -> Result<(), String> {
        if !self.supported() {
            return Err(UNSUPPORTED.into());
        }
        check_id(id)?;
        if !self.allowed(id) {
            return Err(format!("no iOS Simulator {id} on this computer"));
        }
        Ok(())
    }

    async fn devices(&self) -> Result<Vec<SimulatorDevice>, String> {
        let devices = match &self.inner.fake {
            Some(fake) => fake.devices.clone(),
            None => list_devices().await?,
        };
        Ok(devices
            .into_iter()
            .filter(|d| self.allowed(&d.id))
            .collect())
    }

    /// The id names an iOS Simulator that `simctl` lists right now.
    async fn check_known(&self, id: &str) -> Result<SimulatorDevice, String> {
        self.check_usable(id)?;
        self.devices()
            .await?
            .into_iter()
            .find(|d| d.id.eq_ignore_ascii_case(id))
            .ok_or_else(|| format!("no iOS Simulator {id} on this computer"))
    }

    pub async fn list(&self) -> SimulatorList {
        let set_up = self.inner.install.is_installed();
        if !self.supported() {
            return SimulatorList {
                supported: false,
                reason: Some(UNSUPPORTED.into()),
                set_up,
                devices: Vec::new(),
            };
        }
        match self.devices().await {
            Ok(devices) => SimulatorList {
                supported: true,
                reason: None,
                set_up: set_up || self.inner.fake.is_some(),
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
        if !self.supported() {
            return Err(UNSUPPORTED.into());
        }
        {
            let _one = self.inner.installing.lock().await;
            let log = self.inner.tools_dir.join("simulator-setup.log");
            self.inner.install.install(&log).await?;
        }
        Ok(self.list().await)
    }

    pub async fn boot(&self, id: &str) -> Result<(), String> {
        let device = self.check_known(id).await?;
        let out = simctl(&["boot", &device.id], BOOT_TIMEOUT).await;
        // Booting a booted simulator is a no-op, not a failure.
        match out {
            Err(e) if !e.contains("current state: Booted") => Err(e),
            _ => Ok(()),
        }
    }

    pub async fn shutdown_device(&self, id: &str) -> Result<(), String> {
        let device = self.check_known(id).await?;
        match simctl(&["shutdown", &device.id], SIMCTL_TIMEOUT).await {
            Err(e) if !e.contains("current state: Shutdown") => Err(e),
            _ => Ok(()),
        }
    }

    /// The running helper, started if it isn't.
    async fn endpoint(&self) -> Result<Endpoint, String> {
        if let Some(fake) = &self.inner.fake {
            return Ok(fake.endpoint.clone());
        }
        let mut hub = self.inner.hub.lock().await;
        if let Some(running) = hub.as_mut()
            && running.is_alive()
        {
            return Ok(running.endpoint.clone());
        }
        std::fs::create_dir_all(&self.inner.tools_dir).map_err(|e| e.to_string())?;
        let developer_dir = developer_dir().await;
        let started = Hub::start(
            &self.inner.install,
            &self.inner.tools_dir,
            developer_dir.as_deref(),
        )
        .await?;
        let endpoint = started.endpoint.clone();
        *hub = Some(started);
        tokio::spawn(idle_watchdog(Arc::downgrade(&self.inner)));
        Ok(endpoint)
    }

    /// The simulator's screen: the latest frame now and every new one after.
    /// Viewers share one pump; it stops when the last one goes.
    pub async fn watch_screen(&self, id: &str) -> Result<FrameReceiver, String> {
        self.check_usable(id)?;
        let id = id.to_ascii_uppercase();
        self.inner.touch();
        if let Some(tx) = lock(&self.inner.screens).get(&id).and_then(Weak::upgrade) {
            return Ok(tx.subscribe());
        }
        self.check_known(&id).await?;
        let endpoint = self.endpoint().await?;
        let mut screens = lock(&self.inner.screens);
        if let Some(tx) = screens.get(&id).and_then(Weak::upgrade) {
            return Ok(tx.subscribe());
        }
        let (tx, rx) = watch::channel(None);
        let tx = Arc::new(tx);
        screens.insert(id.clone(), Arc::downgrade(&tx));
        let url = format!("{}/sim/helper/{id}/stream.mjpeg", endpoint.origin);
        tokio::spawn(pump(
            self.inner.http.clone(),
            url,
            endpoint.token,
            tx,
            Arc::downgrade(&self.inner),
            id,
        ));
        Ok(rx)
    }

    pub async fn input(&self, id: &str, input: SimulatorInput) -> Result<(), String> {
        self.check_usable(id)?;
        let id = id.to_ascii_uppercase();
        let messages = hid_messages(&input)?;
        self.inner.touch();
        if !self.inner.inputs.lock().await.contains_key(&id) {
            self.check_known(&id).await?;
        }
        let endpoint = self.endpoint().await?;
        let mut inputs = self.inner.inputs.lock().await;
        if inputs
            .get(&id)
            .is_some_and(|socket| socket.origin != endpoint.origin)
        {
            // Opened against a helper run that has since stopped.
            inputs.remove(&id);
        }
        for attempt in 0..2 {
            if !inputs.contains_key(&id) {
                let sink = connect_input(&endpoint, &id).await?;
                inputs.insert(
                    id.clone(),
                    InputSocket {
                        origin: endpoint.origin.clone(),
                        sink,
                    },
                );
            }
            let socket = inputs.get_mut(&id).expect("inserted above");
            let mut sent = Ok(());
            for (i, message) in messages.iter().enumerate() {
                if i > 0 {
                    tokio::time::sleep(KEY_GAP).await;
                }
                if let Err(e) = socket.sink.send(Message::Binary(message.clone())).await {
                    sent = Err(e);
                    break;
                }
            }
            match sent {
                Ok(()) => return Ok(()),
                Err(e) if attempt == 1 => return Err(format!("sending input: {e}")),
                Err(_) => {
                    inputs.remove(&id);
                }
            }
        }
        Ok(())
    }

    /// Stop the helper; simulators themselves keep running (they're the user's).
    pub async fn shutdown(&self) {
        self.inner.inputs.lock().await.clear();
        lock(&self.inner.screens).clear();
        let hub = self.inner.hub.lock().await.take();
        if let Some(hub) = hub {
            hub.stop().await;
        }
    }

    #[cfg(test)]
    fn pumps(&self) -> usize {
        lock(&self.inner.screens)
            .values()
            .filter(|w| w.strong_count() > 0)
            .count()
    }
}

impl Inner {
    fn touch(&self) {
        *lock(&self.last_used) = Instant::now();
    }

    /// No pump is running and nothing has watched or sent input for `idle_stop`.
    fn is_idle(&self) -> bool {
        lock(&self.screens).values().all(|w| w.strong_count() == 0)
            && lock(&self.last_used).elapsed() >= self.idle_stop
    }
}

/// Runs beside each helper: stops it once nobody has used it for a while (its
/// capture keeps a floor frame rate going while it runs), and ends with it.
async fn idle_watchdog(inner: Weak<Inner>) {
    loop {
        let Some(strong) = inner.upgrade() else {
            return;
        };
        let check =
            (strong.idle_stop / 4).clamp(Duration::from_millis(50), Duration::from_secs(15));
        drop(strong);
        tokio::time::sleep(check).await;
        let Some(inner) = inner.upgrade() else { return };
        let mut hub = inner.hub.lock().await;
        if hub.is_none() {
            return;
        }
        if !inner.is_idle() {
            continue;
        }
        inner.inputs.lock().await.clear();
        if let Some(hub) = hub.take() {
            tracing::debug!("simulators: nobody watching; stopping the streaming helper");
            hub.stop().await;
        }
        return;
    }
}

async fn connect_input(endpoint: &Endpoint, id: &str) -> Result<InputSink, String> {
    let url = format!(
        "{}/sim/helper/ws?device={id}",
        endpoint.origin.replacen("http://", "ws://", 1)
    );
    let mut request = url
        .into_client_request()
        .map_err(|e| format!("connecting to the simulator: {e}"))?;
    let bearer = HeaderValue::from_str(&format!("Bearer {}", endpoint.token))
        .map_err(|e| format!("connecting to the simulator: {e}"))?;
    request.headers_mut().insert(AUTHORIZATION, bearer);
    let (socket, _) = tokio_tungstenite::connect_async(request)
        .await
        .map_err(|e| format!("connecting to the simulator: {e}"))?;
    let (sink, mut stream) = socket.split();
    // The helper sends screen config frames; nothing here needs them.
    tokio::spawn(async move { while stream.next().await.is_some() {} });
    Ok(sink)
}

/// A viewer's frames: the newest one now, then at most `max_fps` a second,
/// always the newest (a slow viewer skips frames instead of queueing them).
pub fn viewer_frames(
    rx: FrameReceiver,
    max_fps: Option<u32>,
) -> BoxStream<'static, Arc<ScreenFrame>> {
    let fps = max_fps
        .unwrap_or(DEFAULT_VIEWER_FPS)
        .clamp(1, hub::SOURCE_FPS);
    let gap = Duration::from_secs(1) / fps;
    futures::stream::unfold((rx, None::<Instant>), move |(mut rx, last)| async move {
        match last {
            Some(last) => tokio::time::sleep_until(last + gap).await,
            None => {
                let current = rx.borrow_and_update().clone();
                if let Some(frame) = current {
                    return Some((frame, (rx, Some(Instant::now()))));
                }
            }
        }
        loop {
            rx.changed().await.ok()?;
            let frame = rx.borrow_and_update().clone();
            if let Some(frame) = frame {
                return Some((frame, (rx, Some(Instant::now()))));
            }
        }
    })
    .boxed()
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
        SimulatorInput::Text { text } => {
            if text.chars().count() > MAX_TEXT_CHARS {
                return Err(format!(
                    "send at most {MAX_TEXT_CHARS} characters at a time"
                ));
            }
            keys::type_text(text)
                .map_err(|c| format!("{c:?} can't be typed on a US keyboard"))?
                .iter()
                .map(|event| hid(OP_KEY, event))
                .collect()
        }
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
async fn pump(
    http: reqwest::Client,
    url: String,
    token: String,
    tx: Arc<FrameSender>,
    inner: Weak<Inner>,
    id: String,
) {
    run_pump(&http, &url, &token, &tx).await;
    drop(tx);
    if let Some(inner) = inner.upgrade() {
        {
            let mut screens = lock(&inner.screens);
            if screens.get(&id).is_some_and(|w| w.strong_count() == 0) {
                screens.remove(&id);
            }
        }
        inner.touch();
    }
}

async fn run_pump(http: &reqwest::Client, url: &str, token: &str, tx: &FrameSender) {
    let mut seq = 0u64;
    let mut failures = 0;
    while failures <= PUMP_RETRIES && !tx.is_closed() {
        let response = match http.get(url).bearer_auth(token).send().await {
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

/// Where Xcode is when `xcode-select` points somewhere without `simctl` (the
/// Command Line Tools): the standard Xcode install. None means the default
/// works, the user chose with `DEVELOPER_DIR`, or there is no Xcode at all.
async fn developer_dir() -> Option<PathBuf> {
    static DIR: tokio::sync::OnceCell<Option<PathBuf>> = tokio::sync::OnceCell::const_new();
    DIR.get_or_init(|| async {
        if std::env::var_os("DEVELOPER_DIR").is_some() {
            return None;
        }
        let found = tokio::process::Command::new(XCRUN)
            .args(["--find", "simctl"])
            .stdin(std::process::Stdio::null())
            .output()
            .await
            .is_ok_and(|o| o.status.success());
        if found {
            return None;
        }
        let xcode = Path::new("/Applications/Xcode.app/Contents/Developer");
        xcode
            .join("usr/bin/simctl")
            .is_file()
            .then(|| xcode.to_path_buf())
    })
    .await
    .clone()
}

/// `xcrun simctl <args>`. Every caller passes literals and checked UDIDs only.
async fn simctl(args: &[&str], timeout: Duration) -> Result<String, String> {
    let mut cmd = tokio::process::Command::new(XCRUN);
    cmd.arg("simctl")
        .args(args)
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);
    if let Some(dir) = developer_dir().await {
        cmd.env("DEVELOPER_DIR", dir);
    }
    let output = tokio::time::timeout(timeout, cmd.output())
        .await
        .map_err(|_| format!("simctl {} timed out", args[0]))?
        .map_err(|_| "Xcode wasn't found on this computer.".to_string())?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        if stderr.contains("unable to find utility") {
            return Err("Xcode wasn't found on this computer. Install Xcode, or select it with xcode-select.".into());
        }
        Err(stderr)
    }
}

async fn list_devices() -> Result<Vec<SimulatorDevice>, String> {
    if !cfg!(target_os = "macos") {
        return Err(UNSUPPORTED.into());
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
        // simctl's own output, but still nothing malformed gets offered as an id.
        .filter(|d| check_id(&d.id).is_ok())
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
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    const SIM: &str = "6BBA9FD8-EFAD-45B7-B9FC-30715804D2A1";
    const OTHER: &str = "11111111-2222-3333-4444-555555555555";

    #[test]
    fn simctl_list_becomes_ios_devices_booted_first_newest_runtime_next() {
        let json = r#"{"devices":{
            "com.apple.CoreSimulator.SimRuntime.iOS-26-2":[
                {"udid":"11111111-1111-1111-1111-111111111111","name":"iPhone 16","state":"Shutdown","isAvailable":true}],
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
                {"udid":"22222222-2222-2222-2222-222222222222","name":"iPhone 17","state":"Shutdown","isAvailable":true},
                {"udid":"33333333-3333-3333-3333-333333333333","name":"iPhone 17 Pro","state":"Booted","isAvailable":true},
                {"udid":"not-a-udid","name":"Odd","state":"Booted","isAvailable":true}],
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
        assert!(check_id(SIM).is_ok());
        for bad in [
            "",
            "booted",
            "all",
            "../../etc",
            "6BBA9FD8-EFAD-45B7-B9FC-30715804D2A1/x",
            "6BBA9FD8-EFAD-45B7-B9FC-30715804D2A1 --set",
            "6BBA9FD8xEFADx45B7xB9FCx30715804D2A1",
            "6BBA9FD8-EFAD-45B7-B9FC-30715804D2AZ",
            "-BBA9FD8-EFAD-45B7-B9FC-30715804D2A1",
        ] {
            assert!(check_id(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn the_allowlist_seam_parses_udids_case_insensitively() {
        assert_eq!(allowlist_from(None), None);
        let ids = allowlist_from(Some(format!(" {}, ,{OTHER}", SIM.to_lowercase()))).unwrap();
        assert!(ids.contains(SIM) && ids.contains(OTHER) && ids.len() == 2);
    }

    #[tokio::test]
    async fn only_simulators_simctl_lists_and_the_allowlist_admits_are_accepted() {
        let sims = fake_simulators(
            "http://127.0.0.1:9".into(),
            Some(HashSet::from([SIM.to_string()])),
        );
        let list = sims.list().await;
        assert_eq!(
            list.devices
                .iter()
                .map(|d| d.id.as_str())
                .collect::<Vec<_>>(),
            vec![SIM],
            "the allowlist hides the other simulator"
        );
        assert!(sims.check_known(SIM).await.is_ok());
        assert!(sims.check_known(&SIM.to_lowercase()).await.is_ok());
        let refused = sims.check_known(OTHER).await.unwrap_err();
        assert!(refused.contains("no iOS Simulator"), "{refused}");
        let unknown = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE";
        let open = fake_simulators("http://127.0.0.1:9".into(), None);
        assert!(open.check_known(OTHER).await.is_ok());
        assert!(open.check_known(unknown).await.is_err(), "not listed");
        assert!(open.watch_screen("booted").await.is_err());
        assert!(
            open.input(
                "all",
                SimulatorInput::Button {
                    button: SimulatorButton::Home
                }
            )
            .await
            .is_err()
        );
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
        let moved = hid_messages(&SimulatorInput::Touch {
            phase: TouchPhase::Move,
            x: -0.5,
            y: 0.5,
        })
        .unwrap();
        assert_eq!(
            moved,
            vec![[&[OP_TOUCH][..], br#"{"type":"move","x":0.0,"y":0.5}"#].concat()]
        );
        let home = hid_messages(&SimulatorInput::Button {
            button: SimulatorButton::Home,
        })
        .unwrap();
        assert_eq!(
            home,
            vec![[&[OP_BUTTON][..], br#"{"button":"home"}"#].concat()]
        );
        let lock = hid_messages(&SimulatorInput::Button {
            button: SimulatorButton::Lock,
        })
        .unwrap();
        assert_eq!(
            lock,
            vec![
                [
                    &[OP_BUTTON][..],
                    br#"{"button":"power","page":12,"usage":48}"#
                ]
                .concat()
            ]
        );
        let text = hid_messages(&SimulatorInput::Text { text: "a".into() }).unwrap();
        assert_eq!(
            text,
            vec![
                [&[OP_KEY][..], br#"{"type":"down","usage":4}"#].concat(),
                [&[OP_KEY][..], br#"{"type":"up","usage":4}"#].concat(),
            ]
        );
        let enter = hid_messages(&SimulatorInput::Key {
            key: "enter".into(),
        })
        .unwrap();
        assert_eq!(
            enter,
            vec![
                [&[OP_KEY][..], br#"{"type":"down","usage":40}"#].concat(),
                [&[OP_KEY][..], br#"{"type":"up","usage":40}"#].concat(),
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
        assert!(hid_messages(&SimulatorInput::Text { text: "é".into() }).is_err());
        let long = "a".repeat(MAX_TEXT_CHARS + 1);
        assert!(hid_messages(&SimulatorInput::Text { text: long }).is_err());
    }

    #[test]
    fn viewer_input_parses_from_the_wire_shape() {
        let touch: SimulatorInput =
            serde_json::from_str(r#"{"kind":"touch","phase":"move","x":0.5,"y":0.25}"#).unwrap();
        assert!(matches!(
            touch,
            SimulatorInput::Touch {
                phase: TouchPhase::Move,
                ..
            }
        ));
        let button: SimulatorInput =
            serde_json::from_str(r#"{"kind":"button","button":"volumeUp"}"#).unwrap();
        assert!(matches!(
            button,
            SimulatorInput::Button {
                button: SimulatorButton::VolumeUp
            }
        ));
        assert!(serde_json::from_str::<SimulatorInput>(r#"{"kind":"exec","cmd":"ls"}"#).is_err());
    }

    fn fake_simulators(origin: String, allowlist: Option<HashSet<String>>) -> Simulators {
        let device = |id: &str, name: &str| SimulatorDevice {
            id: id.into(),
            name: name.into(),
            runtime: "iOS 27.0".into(),
            booted: true,
        };
        Simulators::build(
            std::env::temp_dir(),
            allowlist,
            Duration::from_millis(200),
            Some(Fake {
                endpoint: Endpoint {
                    origin,
                    token: "t".repeat(64),
                },
                devices: vec![device(SIM, "Test A"), device(OTHER, "Test B")],
            }),
        )
    }

    fn part(body: &[u8]) -> Vec<u8> {
        let mut out = format!(
            "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: {}\r\n\r\n",
            body.len()
        )
        .into_bytes();
        out.extend_from_slice(body);
        out.extend_from_slice(b"\r\n");
        out
    }

    /// A stand-in for the helper's MJPEG route: counts connections, refuses a
    /// wrong token, and streams numbered frames until the client goes away.
    async fn fake_stream_server() -> (String, Arc<AtomicUsize>, Arc<AtomicUsize>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let connections = Arc::new(AtomicUsize::new(0));
        let open = Arc::new(AtomicUsize::new(0));
        let (c, o) = (connections.clone(), open.clone());
        tokio::spawn(async move {
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let (c, o) = (c.clone(), o.clone());
                tokio::spawn(async move {
                    let mut request = Vec::new();
                    let mut buf = [0u8; 1024];
                    while !request.windows(4).any(|w| w == b"\r\n\r\n") {
                        let n = socket.read(&mut buf).await.unwrap_or(0);
                        if n == 0 {
                            return;
                        }
                        request.extend_from_slice(&buf[..n]);
                    }
                    let request = String::from_utf8_lossy(&request).to_ascii_lowercase();
                    if !request.contains(&format!("authorization: bearer {}", "t".repeat(64))) {
                        let _ = socket
                            .write_all(b"HTTP/1.1 401 Unauthorized\r\ncontent-length: 0\r\n\r\n")
                            .await;
                        return;
                    }
                    c.fetch_add(1, Ordering::SeqCst);
                    o.fetch_add(1, Ordering::SeqCst);
                    let head = "HTTP/1.1 200 OK\r\ncontent-type: multipart/x-mixed-replace; boundary=frame\r\nconnection: close\r\n\r\n";
                    let mut ok = socket.write_all(head.as_bytes()).await.is_ok();
                    let mut n = 0u32;
                    while ok {
                        n += 1;
                        ok = socket
                            .write_all(&part(format!("frame{n}").as_bytes()))
                            .await
                            .is_ok()
                            && socket.flush().await.is_ok();
                        tokio::time::sleep(Duration::from_millis(5)).await;
                    }
                    o.fetch_sub(1, Ordering::SeqCst);
                });
            }
        });
        (origin, connections, open)
    }

    async fn eventually(what: &str, check: impl Fn() -> bool) {
        for _ in 0..200 {
            if check() {
                return;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        panic!("timed out waiting for {what}");
    }

    #[tokio::test]
    async fn viewers_share_one_pump_that_stops_with_the_last_viewer() {
        let (origin, connections, open) = fake_stream_server().await;
        let sims = fake_simulators(origin, None);

        let first = sims.watch_screen(SIM).await.unwrap();
        let second = sims.watch_screen(&SIM.to_lowercase()).await.unwrap();
        let mut a = viewer_frames(first, Some(20));
        let mut b = viewer_frames(second, Some(20));
        let fa = a.next().await.unwrap();
        let fb = b.next().await.unwrap();
        assert!(!fa.jpeg.is_empty() && !fb.jpeg.is_empty());
        assert_eq!(sims.pumps(), 1);
        assert_eq!(
            connections.load(Ordering::SeqCst),
            1,
            "one pull for both viewers"
        );

        drop(a);
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(open.load(Ordering::SeqCst), 1, "still one viewer");
        let _ = b.next().await.unwrap();

        drop(b);
        eventually("the pump to stop", || open.load(Ordering::SeqCst) == 0).await;
        eventually("the pump to deregister", || sims.pumps() == 0).await;

        // A new viewer starts a new pump.
        let again = sims.watch_screen(SIM).await.unwrap();
        let mut c = viewer_frames(again, None);
        assert!(c.next().await.is_some());
        assert_eq!(connections.load(Ordering::SeqCst), 2);
        // A different simulator gets its own pump.
        let other = sims.watch_screen(OTHER).await.unwrap();
        let mut d = viewer_frames(other, None);
        assert!(d.next().await.is_some());
        assert_eq!(sims.pumps(), 2);
    }

    #[tokio::test]
    async fn the_helper_counts_as_idle_only_with_no_pump_and_no_recent_use() {
        let (origin, _, _) = fake_stream_server().await;
        let sims = fake_simulators(origin, None);
        assert!(!sims.inner.is_idle(), "just used");
        *lock(&sims.inner.last_used) = Instant::now() - Duration::from_secs(5);
        assert!(sims.inner.is_idle());
        let rx = sims.watch_screen(SIM).await.unwrap();
        *lock(&sims.inner.last_used) = Instant::now() - Duration::from_secs(5);
        assert!(!sims.inner.is_idle(), "a pump is running");
        drop(rx);
        eventually("the pump to end", || sims.pumps() == 0).await;
        assert!(!sims.inner.is_idle(), "the pump's end counts as use");
        *lock(&sims.inner.last_used) = Instant::now() - Duration::from_secs(5);
        assert!(sims.inner.is_idle());
    }

    #[tokio::test]
    async fn a_pump_with_the_wrong_token_ends_its_viewers_streams() {
        let (origin, connections, _) = fake_stream_server().await;
        let sims = Simulators::build(
            std::env::temp_dir(),
            None,
            Duration::from_millis(200),
            Some(Fake {
                endpoint: Endpoint {
                    origin,
                    token: "wrong".into(),
                },
                devices: vec![SimulatorDevice {
                    id: SIM.into(),
                    name: "Test".into(),
                    runtime: "iOS 27.0".into(),
                    booted: true,
                }],
            }),
        );
        let rx = sims.watch_screen(SIM).await.unwrap();
        let mut frames = viewer_frames(rx, None);
        assert!(
            frames.next().await.is_none(),
            "refused, retried, then ended"
        );
        assert_eq!(connections.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn a_viewer_gets_the_newest_frame_at_its_own_rate() {
        let (tx, rx) = watch::channel(None);
        let frame = |seq| {
            Some(Arc::new(ScreenFrame {
                seq,
                jpeg: String::new(),
            }))
        };
        tx.send(frame(1)).unwrap();
        let mut frames = viewer_frames(rx, Some(4));
        let start = tokio::time::Instant::now();
        assert_eq!(
            frames.next().await.unwrap().seq,
            1,
            "the current frame at once"
        );
        // Ten frames land while the viewer waits out its 250 ms gap.
        for seq in 2..=11 {
            tx.send(frame(seq)).unwrap();
        }
        assert_eq!(frames.next().await.unwrap().seq, 11, "only the newest");
        assert!(start.elapsed() >= Duration::from_millis(250));
        drop(tx);
        assert!(frames.next().await.is_none(), "ends with the pump");
    }
}
