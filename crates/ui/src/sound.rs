//! Session notification sounds — the herdr approach (state-transition chimes
//! played through the platform's own audio CLI, zero Rust audio deps):
//!
//! - embedded completion, input-request, attention, Appshot and attach cues;
//! - macOS Appshot and attach cues use a preloaded native player; other cues write to a
//!   temp file and use the system player on a
//!   background thread: `afplay` (macOS), PowerShell `Media.SoundPlayer`
//!   (Windows), first of `paplay`/`pw-play`/`aplay`/`ffplay`/`mpv` (Linux —
//!   WAV, so even bare ALSA `aplay` decodes it);
//! - on macOS a session chime for a background banner is attached to that
//!   notification instead of played here, so Focus applies ([`plan_alert`]);
//! - `HARNESS_DISABLE_SOUND` env kill-switch + the `soundEnabled` ui-setting;
//! - failures are logged and swallowed — a missing player must never bother
//!   the session flow.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

const DISABLE_ENV: &str = "HARNESS_DISABLE_SOUND";
static TMP_COUNTER: AtomicU64 = AtomicU64::new(0);

#[cfg(any(target_os = "macos", target_os = "linux"))]
static SOUND_APPSHOT: &[u8] = include_bytes!("../assets/sounds/appshot.wav");

static SOUND_ATTACH: &[u8] = include_bytes!("../assets/sounds/attach.wav");
static SOUND_DONE: &[u8] = include_bytes!("../assets/sounds/done.wav");
static SOUND_REQUEST: &[u8] = include_bytes!("../assets/sounds/request.wav");
static SOUND_ATTENTION: &[u8] = include_bytes!("../assets/sounds/attention.wav");

/// Which notification chime to play.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sound {
    /// An agent turn completed successfully.
    Done,
    /// The agent is waiting on a question (→ AwaitingInput).
    Request,
    /// A run failed or the durable connection state degraded.
    Attention,
}

impl Sound {
    /// The chime's file name inside the macOS app bundle's `Resources`
    /// (copied there by `scripts/package-macos.sh`), the name a system
    /// notification plays it by.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    pub(crate) fn bundle_file_name(self) -> &'static str {
        match self {
            Sound::Done => "harness-done.wav",
            Sound::Request => "harness-request.wav",
            Sound::Attention => "harness-attention.wav",
        }
    }
}

/// Whether the `HARNESS_DISABLE_SOUND` kill-switch is set. Applies to chimes
/// attached to notifications as well as local playback.
pub(crate) fn disabled_by_env() -> bool {
    std::env::var_os(DISABLE_ENV).is_some()
}

/// Where one alert's chime is played.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Chime {
    Silent,
    /// Harness plays it itself ([`play`]). macOS Focus can't silence this.
    Local,
    /// Attached to the alert's system notification, so the system applies
    /// Focus / Do Not Disturb and the per-app notification settings to it.
    WithNotification,
}

/// How one session or connectivity alert is delivered.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct AlertDelivery {
    pub banner: bool,
    pub chime: Chime,
}

/// Route one alert. Each alert rings at most once: a chime that rides on the
/// notification is never also played locally.
///
/// - `sound`: the chime is wanted (session-sound settings, attention gate);
/// - `banner`: the banner is wanted (desktop setting, background-only check);
/// - `app_focused`: a Harness window is key;
/// - `notification_sound`: this platform's notification path can carry the
///   chime (native macOS center).
///
/// In the background, a chime travels with the banner when there is one, so
/// Focus and the app's notification settings decide whether it is heard.
/// While Harness is focused the chime stays in-app feedback and plays
/// locally; a banner shown then is silent. With banners off (sound-only
/// alerts) nothing exists for the system to filter, so the chime plays
/// locally as before rather than being dropped or forcing a banner the user
/// turned off.
pub(crate) fn plan_alert(
    sound: bool,
    banner: bool,
    app_focused: bool,
    notification_sound: bool,
) -> AlertDelivery {
    let chime = if !sound {
        Chime::Silent
    } else if banner && !app_focused && notification_sound {
        Chime::WithNotification
    } else {
        Chime::Local
    };
    AlertDelivery { banner, chime }
}

/// Play a chime on a background thread. Silently a no-op when disabled or no
/// player is available.
pub fn play(sound: Sound) {
    let data = match sound {
        Sound::Done => SOUND_DONE,
        Sound::Request => SOUND_REQUEST,
        Sound::Attention => SOUND_ATTENTION,
    };
    play_in_background(data);
}

/// Confirm captured pixels with a soft shutter and clear chime.
/// The caller honors the dedicated capture sound setting.
pub fn play_appshot() {
    if std::env::var_os(DISABLE_ENV).is_some() {
        return;
    }
    #[cfg(target_os = "macos")]
    if macos_cue::APPSHOT.play() {
        return;
    }
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    play_in_background(SOUND_APPSHOT);
}

/// Load the macOS capture cue before the first capture, without playing it.
pub fn prepare_appshot() {
    #[cfg(target_os = "macos")]
    if std::env::var_os(DISABLE_ENV).is_none() {
        macos_cue::APPSHOT.sender();
    }
}

static ATTACH_SOUND_ENABLED: AtomicBool = AtomicBool::new(false);

/// The Notifications page's "Attaching files" switch.
pub fn set_attach_sound_enabled(enabled: bool) {
    ATTACH_SOUND_ENABLED.store(enabled, Ordering::Relaxed);
    #[cfg(target_os = "macos")]
    if enabled && std::env::var_os(DISABLE_ENV).is_none() {
        macos_cue::ATTACH.sender();
    }
}

#[cfg(test)]
thread_local! {
    /// Attach cues requested on this thread, for tests.
    pub(crate) static ATTACH_CUES: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

/// A file or image landed in the composer: a soft thump and two rising notes.
pub fn play_attach() {
    if !ATTACH_SOUND_ENABLED.load(Ordering::Relaxed) || std::env::var_os(DISABLE_ENV).is_some() {
        return;
    }
    #[cfg(test)]
    {
        ATTACH_CUES.with(|n| n.set(n.get() + 1));
        return;
    }
    #[cfg(all(not(test), target_os = "macos"))]
    if macos_cue::ATTACH.play() {
        return;
    }
    #[allow(unreachable_code)]
    play_in_background(SOUND_ATTACH);
}

#[cfg(target_os = "macos")]
mod macos_cue {
    use objc::rc::{StrongPtr, autoreleasepool};
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};
    use std::sync::{OnceLock, mpsc};

    #[link(name = "AVFoundation", kind = "framework")]
    unsafe extern "C" {}

    /// One short cue kept decoded on its own worker, so it starts at once.
    pub(super) struct Cue {
        name: &'static str,
        bytes: &'static [u8],
        sender: OnceLock<Option<mpsc::SyncSender<()>>>,
    }

    pub(super) static APPSHOT: Cue = Cue::new("appshot", super::SOUND_APPSHOT);
    pub(super) static ATTACH: Cue = Cue::new("attach", super::SOUND_ATTACH);

    impl Cue {
        const fn new(name: &'static str, bytes: &'static [u8]) -> Self {
            Self {
                name,
                bytes,
                sender: OnceLock::new(),
            }
        }

        // Keep native objects on one worker. A bounded mailbox avoids a backlog
        // of stale cues when they arrive in a burst.
        pub(super) fn sender(&'static self) -> Option<&'static mpsc::SyncSender<()>> {
            self.sender
                .get_or_init(|| {
                    let (tx, rx) = mpsc::sync_channel(1);
                    std::thread::Builder::new()
                        .name(format!("{}-audio", self.name))
                        .spawn(move || {
                            let player = autoreleasepool(|| self.load());
                            while rx.recv().is_ok() {
                                if std::env::var_os(super::DISABLE_ENV).is_some() {
                                    continue;
                                }
                                let started = std::time::Instant::now();
                                let played = player.as_ref().is_some_and(|player| {
                                    autoreleasepool(|| unsafe {
                                        // Pause preserves prepared audio resources; stop would discard them.
                                        let _: () = msg_send![**player, pause];
                                        let _: () = msg_send![**player, setCurrentTime: 0.0_f64];
                                        let played: bool = msg_send![**player, play];
                                        played
                                    })
                                });
                                tracing::debug!(
                                    cue = self.name,
                                    elapsed_ms = started.elapsed().as_millis(),
                                    played,
                                    "native cue playback requested"
                                );
                                if !played {
                                    super::play_in_background(self.bytes);
                                }
                            }
                        })
                        .ok()
                        .map(|_| tx)
                })
                .as_ref()
        }

        fn load(&self) -> Option<StrongPtr> {
            let player = self.decode()?;
            let ready: bool = unsafe { msg_send![*player, prepareToPlay] };
            if !ready {
                tracing::warn!(
                    cue = self.name,
                    "Could not prepare native cue audio; using system player"
                );
                return None;
            }
            Some(player)
        }

        fn decode(&self) -> Option<StrongPtr> {
            unsafe {
                let data: *mut Object = msg_send![class!(NSData),
                    dataWithBytes: self.bytes.as_ptr()
                    length: self.bytes.len()];
                let allocated: *mut Object = msg_send![class!(AVAudioPlayer), alloc];
                let mut error: *mut Object = std::ptr::null_mut();
                let player: *mut Object =
                    msg_send![allocated, initWithData: data error: &mut error];
                if player.is_null() {
                    tracing::warn!(
                        cue = self.name,
                        "Could not decode native cue audio; using system player"
                    );
                    return None;
                }
                Some(StrongPtr::new(player))
            }
        }

        pub(super) fn play(&'static self) -> bool {
            match self.sender().map(|tx| tx.try_send(())) {
                Some(Ok(()) | Err(mpsc::TrySendError::Full(()))) => true,
                _ => false,
            }
        }
    }

    #[test]
    fn embedded_cues_decode_natively_without_playback() {
        for (cue, seconds) in [(&APPSHOT, 0.67), (&ATTACH, 0.42)] {
            autoreleasepool(|| {
                let player = cue
                    .decode()
                    .expect("embedded cue should decode in AVAudioPlayer");
                let duration: f64 = unsafe { msg_send![*player, duration] };
                let playing: bool = unsafe { msg_send![*player, isPlaying] };
                assert!(
                    (duration - seconds).abs() < 0.001,
                    "{}: {duration}",
                    cue.name
                );
                assert!(!playing);
            });
        }
    }
}

fn play_in_background(data: &'static [u8]) {
    if std::env::var_os(DISABLE_ENV).is_some() {
        return;
    }
    std::thread::spawn(move || {
        if let Err(err) = play_bytes(data) {
            tracing::debug!(error = %err, "sound playback failed");
        }
    });
}

fn play_bytes(data: &[u8]) -> Result<(), String> {
    // The system players want a file path. Exclusive creation prevents a
    // predictable-name collision (including a pre-planted symlink) from
    // redirecting the embedded bytes to another file.
    let (mut file, tmp) = create_temp_file().map_err(|e| e.to_string())?;
    file.write_all(data).map_err(|e| e.to_string())?;
    drop(file);
    let result = run_player(&tmp.path);
    drop(tmp);
    result
}

struct TempSoundFile {
    path: PathBuf,
}

impl Drop for TempSoundFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

fn create_temp_file() -> std::io::Result<(std::fs::File, TempSoundFile)> {
    for _ in 0..128 {
        let id = TMP_COUNTER.fetch_add(1, Ordering::Relaxed);
        let path =
            std::env::temp_dir().join(format!("harness-sound-{}-{id}.wav", std::process::id()));
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
        {
            Ok(file) => return Ok((file, TempSoundFile { path })),
            Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(err) => return Err(err),
        }
    }
    Err(std::io::Error::new(
        std::io::ErrorKind::AlreadyExists,
        "could not reserve a notification sound file",
    ))
}

#[cfg(target_os = "macos")]
fn run_player(path: &Path) -> Result<(), String> {
    run_checked("afplay", &[], path)
}

#[cfg(windows)]
fn run_player(path: &Path) -> Result<(), String> {
    use std::os::windows::process::CommandExt;
    // SoundPlayer handles WAV natively; PlaySync keeps the process alive for
    // the chime's duration. Pass the path through the child environment rather
    // than interpolating it into PowerShell source (paths may contain quotes).
    let script = "(New-Object Media.SoundPlayer $env:HARNESS_SOUND_PATH).PlaySync()";
    let output = std::process::Command::new("powershell.exe")
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            script,
        ])
        .env("HARNESS_SOUND_PATH", path)
        .creation_flags(0x08000000)
        .output()
        .map_err(|e| format!("powershell failed: {e}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(format!("powershell exited with {}", output.status))
    }
}

#[cfg(not(any(windows, target_os = "macos")))]
fn run_player(path: &Path) -> Result<(), String> {
    // WAV everywhere, so even bare ALSA aplay decodes it (herdr must exclude
    // aplay because it ships mp3s).
    let players: &[(&str, &[&str])] = &[
        ("paplay", &[]),
        ("pw-play", &[]),
        ("aplay", &["-q"]),
        ("ffplay", &["-nodisp", "-autoexit", "-loglevel", "quiet"]),
        ("mpv", &["--no-video", "--really-quiet"]),
    ];
    let mut errors = Vec::new();
    for (program, args) in players {
        match run_checked(program, args, path) {
            Ok(()) => return Ok(()),
            Err(err) => errors.push(err),
        }
    }
    Err(format!("no audio player available: {}", errors.join("; ")))
}

fn run_checked(program: &str, args: &[&str], path: &Path) -> Result<(), String> {
    // Bounded wait: a wedged audio daemon must not accumulate zombie threads.
    let mut child = std::process::Command::new(program)
        .args(args)
        .arg(path)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("{program}: {e}"))?;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Ok(()),
            Ok(Some(status)) => return Err(format!("{program} exited with {status}")),
            Ok(None) => {
                if std::time::Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(format!("{program} timed out"));
                }
                std::thread::sleep(std::time::Duration::from_millis(25));
            }
            Err(err) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("{program}: {err}"));
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Notification decision (shared by sound and desktop banners)
// ---------------------------------------------------------------------------

use harness_proto::{
    Session,
    view::{Indicator, effective_indicator},
};

/// Whether a completed turn earns a completion sound and "Run finished"
/// banner. An archived chat is out of the person's working set, and a turn
/// that answered only peer mail is agent coordination, not a result anyone
/// asked to hear about (#499). Input requests and failures keep their own
/// alerts; only completion is withheld.
pub(crate) fn completion_alert_allowed(chat_archived: bool, peer_only_turn: bool) -> bool {
    !chat_archived && !peer_only_turn
}

/// Notification baseline is separate from the visual activity indicator:
/// going idle can mean cancellation, expiry, or an internal handoff.
#[derive(Debug, Clone)]
pub(crate) struct SessionNotificationState {
    indicator: Indicator,
    last_completed_turn: Option<String>,
    fresh: bool,
    completion_alert: bool,
}

impl SessionNotificationState {
    pub(crate) fn new(
        session: &Session,
        chat_archived: bool,
        now: chrono::DateTime<chrono::Utc>,
    ) -> Self {
        Self {
            indicator: effective_indicator(Some(session), now),
            last_completed_turn: session.last_completed_turn.clone(),
            fresh: now
                .signed_duration_since(session.updated_at)
                .num_milliseconds()
                <= harness_proto::view::SESSION_STALE_MS,
            completion_alert: completion_alert_allowed(
                chat_archived,
                session.last_completed_peer_only,
            ),
        }
    }

    /// Call after saving the new baseline, including when delivery is pending
    /// or outputs are disabled. Suppressed pings must never be replayed later:
    /// a withheld completion (archived chat, peer-only turn) still advances the
    /// baseline, so a restore or heartbeat cannot replay it.
    pub(crate) fn sound_since(&self, prev: &Self, send_pending: bool) -> Option<Sound> {
        if self.indicator == Indicator::Errored && prev.indicator != Indicator::Errored {
            return Some(Sound::Attention);
        }
        if self.indicator == Indicator::AwaitingInput && prev.indicator != Indicator::AwaitingInput
        {
            return Some(Sound::Request);
        }
        if !send_pending
            && self.completion_alert
            && self.fresh
            && self.last_completed_turn.is_some()
            && self.last_completed_turn != prev.last_completed_turn
        {
            return Some(Sound::Done);
        }
        None
    }
}

/// Advance one chat's notification baseline and return the alert it earns.
/// A row's first appearance seeds the baseline silently (boot/replay). A
/// session whose chat row hasn't arrived yet (`current` is `None`: a chat made
/// on another device, or rows still loading at startup) leaves its baseline
/// untouched, so its completion is judged once the row lands rather than
/// consumed while the app can't see the chat.
pub(crate) fn observe_session_baseline(
    baselines: &mut std::collections::HashMap<String, SessionNotificationState>,
    chat_id: &str,
    current: Option<SessionNotificationState>,
    send_pending: bool,
) -> Option<Sound> {
    let current = current?;
    let previous = baselines.insert(chat_id.to_owned(), current.clone())?;
    current.sound_since(&previous, send_pending)
}

/// The engine already holds raw transport degradation for four seconds before
/// exposing `Offline` or `Reconnecting`. Notify once when that durable state is
/// first crossed; booting into an outage is seeded silently by the shell.
pub(crate) fn connectivity_sound_since(
    current: harness_proto::ConnectivityState,
    previous: harness_proto::ConnectivityState,
) -> Option<Sound> {
    use harness_proto::ConnectivityState as State;
    let degraded = matches!(current, State::Offline | State::Reconnecting);
    let was_degraded = matches!(previous, State::Offline | State::Reconnecting);
    (degraded && !was_degraded).then_some(Sound::Attention)
}

/// A newly attached engine can report `Connected` while its four-second
/// degradation grace is still measuring an outage that predates the UI. Arm
/// alerts only after a longer healthy observation, or after recovery from a
/// boot-time outage. Runtime replacement resets the observation flag.
#[derive(Debug, Default)]
pub(crate) struct ConnectivityNotificationState {
    previous: Option<harness_proto::ConnectivityState>,
    first_observed_at: Option<Instant>,
    armed: bool,
}

impl ConnectivityNotificationState {
    const STARTUP_QUIET: Duration = Duration::from_secs(5);

    pub(crate) fn update(
        &mut self,
        current: harness_proto::ConnectivityState,
        observed: bool,
        now: Instant,
    ) -> Option<Sound> {
        if !observed {
            *self = Self::default();
            return None;
        }

        let first = *self.first_observed_at.get_or_insert(now);
        let previous = self.previous.replace(current);
        if !self.armed {
            if now.duration_since(first) >= Self::STARTUP_QUIET {
                self.armed = true;
                return previous.and_then(|previous| connectivity_sound_since(current, previous));
            }
            return None;
        }
        previous.and_then(|previous| connectivity_sound_since(current, previous))
    }
}

/// Coalesce attention requests delivered by independent state watches. The
/// persistent gate also collapses multiple failures in one session snapshot.
#[derive(Debug, Default)]
pub(crate) struct AttentionSoundGate {
    last_played: Option<Instant>,
}

impl AttentionSoundGate {
    const COALESCE: Duration = Duration::from_millis(250);

    pub(crate) fn should_play(&mut self, now: Instant) -> bool {
        if self
            .last_played
            .is_some_and(|last| now.duration_since(last) < Self::COALESCE)
        {
            return false;
        }
        self.last_played = Some(now);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn baseline(indicator: Indicator, turn: Option<&str>) -> SessionNotificationState {
        SessionNotificationState {
            indicator,
            last_completed_turn: turn.map(str::to_owned),
            fresh: true,
            completion_alert: true,
        }
    }

    fn session(
        status: harness_proto::SessionStatus,
        turn: Option<&str>,
        peer_only: bool,
    ) -> Session {
        Session {
            last_completed_turn: turn.map(str::to_owned),
            last_completed_peer_only: peer_only,
            chat_id: "chat".into(),
            device_id: "device".into(),
            status,
            started_at: None,
            updated_at: chrono::Utc::now(),
        }
    }

    #[test]
    fn archived_chats_never_alert_completion_and_never_replay_it() {
        use harness_proto::SessionStatus::{Idle, Working};
        let now = chrono::Utc::now();
        let working =
            SessionNotificationState::new(&session(Working, Some("t1"), false), false, now);
        // Archived after the run started: the late completion is consumed.
        let late = SessionNotificationState::new(&session(Idle, Some("t2"), false), true, now);
        assert_eq!(late.sound_since(&working, false), None);
        // Restoring the chat (or a heartbeat) re-reads the same marker: silent.
        let restored = SessionNotificationState::new(&session(Idle, Some("t2"), false), false, now);
        assert_eq!(restored.sound_since(&late, false), None);
        let heartbeat =
            SessionNotificationState::new(&session(Working, Some("t2"), false), false, now);
        assert_eq!(heartbeat.sound_since(&restored, false), None);
        // A failure or a question in an archived chat still alerts.
        let failed = SessionNotificationState::new(
            &session(harness_proto::SessionStatus::Errored, Some("t2"), false),
            true,
            now,
        );
        assert_eq!(failed.sound_since(&late, false), Some(Sound::Attention));
        let asking = SessionNotificationState::new(
            &session(
                harness_proto::SessionStatus::AwaitingInput,
                Some("t2"),
                false,
            ),
            true,
            now,
        );
        assert_eq!(asking.sound_since(&late, false), Some(Sound::Request));
    }

    #[test]
    fn peer_only_turns_complete_silently_and_human_turns_still_chime() {
        use harness_proto::SessionStatus::{Idle, Working};
        let now = chrono::Utc::now();
        let before =
            SessionNotificationState::new(&session(Working, Some("t1"), false), false, now);
        let peer = SessionNotificationState::new(&session(Idle, Some("t2"), true), false, now);
        assert_eq!(peer.sound_since(&before, false), None);
        assert_eq!(peer.sound_since(&peer, false), None);
        // A person's next request (which may consult peers) chimes as usual.
        let human = SessionNotificationState::new(&session(Idle, Some("t3"), false), false, now);
        assert_eq!(human.sound_since(&peer, false), Some(Sound::Done));
        assert!(completion_alert_allowed(false, false));
        assert!(!completion_alert_allowed(true, false));
        assert!(!completion_alert_allowed(false, true));
        assert!(!completion_alert_allowed(true, true));
    }

    #[test]
    fn interrupted_and_expired_activity_never_chime() {
        let working = baseline(Indicator::Working, Some("old"));
        let idle = baseline(Indicator::None, Some("old"));
        assert_eq!(idle.sound_since(&working, false), None);
        // An older host without explicit completion metadata is silent too.
        assert_eq!(
            baseline(Indicator::None, None).sound_since(&baseline(Indicator::Working, None), false),
            None
        );
    }

    #[test]
    fn a_run_error_chimes_once_and_never_masquerades_as_completion() {
        let working = baseline(Indicator::Working, Some("old"));
        let errored = baseline(Indicator::Errored, Some("failed"));
        assert_eq!(errored.sound_since(&working, false), Some(Sound::Attention));
        assert_eq!(errored.sound_since(&errored, false), None);
    }

    #[test]
    fn durable_connectivity_degradation_chimes_once_per_outage() {
        use harness_proto::ConnectivityState as State;

        assert_eq!(
            connectivity_sound_since(State::Connected, State::Disabled),
            None
        );
        assert_eq!(
            connectivity_sound_since(State::Reconnecting, State::Connected),
            Some(Sound::Attention)
        );
        assert_eq!(
            connectivity_sound_since(State::Offline, State::Reconnecting),
            None
        );
        assert_eq!(
            connectivity_sound_since(State::Connected, State::Offline),
            None
        );
        assert_eq!(
            connectivity_sound_since(State::Offline, State::Connected),
            Some(Sound::Attention)
        );
    }

    #[test]
    fn ordinary_queue_completions_survive_coalesced_working_states() {
        let first = baseline(Indicator::Working, None);
        let second = baseline(Indicator::Working, Some("first"));
        assert_eq!(second.sound_since(&first, false), Some(Sound::Done));
        assert_eq!(second.sound_since(&second, false), None);
        let last = baseline(Indicator::None, Some("second"));
        assert_eq!(last.sound_since(&second, false), Some(Sound::Done));
        assert_eq!(last.sound_since(&last, false), None);
    }

    #[test]
    fn pending_send_consumes_completion_but_preserves_input_requests() {
        let before = baseline(Indicator::Working, None);
        let settled = baseline(Indicator::None, Some("first"));
        assert_eq!(settled.sound_since(&before, true), None);
        assert_eq!(settled.sound_since(&settled, false), None);
        let question = baseline(Indicator::AwaitingInput, Some("first"));
        assert_eq!(question.sound_since(&settled, true), Some(Sound::Request));
        assert_eq!(question.sound_since(&question, false), None);
    }

    #[test]
    fn stale_completion_is_consumed_without_replaying_on_a_heartbeat() {
        let before = baseline(Indicator::Working, None);
        let mut stale = baseline(Indicator::None, Some("old"));
        stale.fresh = false;
        assert_eq!(stale.sound_since(&before, false), None);
        let refreshed = baseline(Indicator::Working, Some("old"));
        assert_eq!(refreshed.sound_since(&stale, false), None);
    }

    // Mirror the caller's baseline-before-output contract, including updates
    // whose decisions are suppressed or discarded by output settings.
    fn observe_session(
        previous: &mut SessionNotificationState,
        session: &Session,
        now: chrono::DateTime<chrono::Utc>,
        archived: bool,
        send_pending: bool,
    ) -> Option<Sound> {
        let current = SessionNotificationState::new(session, archived, now);
        let previous = std::mem::replace(previous, current.clone());
        current.sound_since(&previous, send_pending)
    }

    #[test]
    fn a_completion_without_its_chat_row_waits_for_the_row() {
        use harness_proto::SessionStatus::{Idle, Working};
        let now = chrono::Utc::now();
        let known = |s: &Session, archived| Some(SessionNotificationState::new(s, archived, now));
        let mut baselines = std::collections::HashMap::new();

        // Seen working while its row was known; the completion then lands
        // before the row does (rows still loading, or re-sent by a peer).
        let working = session(Working, Some("t1"), false);
        assert_eq!(
            observe_session_baseline(&mut baselines, "chat", known(&working, false), false),
            None
        );
        let finished = session(Idle, Some("t2"), false);
        for _ in 0..3 {
            assert_eq!(
                observe_session_baseline(&mut baselines, "chat", None, false),
                None,
                "no alert for a chat the app can't show yet"
            );
        }
        // The row lands: the held completion still notifies, exactly once.
        assert_eq!(
            observe_session_baseline(&mut baselines, "chat", known(&finished, false), false),
            Some(Sound::Done)
        );
        assert_eq!(
            observe_session_baseline(&mut baselines, "chat", known(&finished, false), false),
            None
        );

        // A chat made on another device: its session arrives first, the row
        // follows while the turn runs, and the finish notifies.
        let mut baselines = std::collections::HashMap::new();
        assert_eq!(
            observe_session_baseline(&mut baselines, "remote", None, false),
            None
        );
        let running = session(Working, None, false);
        assert_eq!(
            observe_session_baseline(&mut baselines, "remote", known(&running, false), false),
            None,
            "the row's first appearance seeds silently"
        );
        let done = session(Idle, Some("remote-turn"), false);
        assert_eq!(
            observe_session_baseline(&mut baselines, "remote", known(&done, false), false),
            Some(Sound::Done)
        );

        // The same hold never makes an archived chat or a peer-only turn
        // audible: the row decides, and it consumes the marker silently.
        for (archived, peer_only) in [(true, false), (false, true)] {
            let mut baselines = std::collections::HashMap::new();
            observe_session_baseline(&mut baselines, "quiet", known(&working, archived), false);
            assert_eq!(
                observe_session_baseline(&mut baselines, "quiet", None, false),
                None
            );
            let quiet = session(Idle, Some("t2"), peer_only);
            assert_eq!(
                observe_session_baseline(&mut baselines, "quiet", known(&quiet, archived), false),
                None,
                "archived={archived}, peer_only={peer_only}"
            );
            // Restoring the chat afterwards cannot replay the consumed marker.
            assert_eq!(
                observe_session_baseline(&mut baselines, "quiet", known(&quiet, false), false),
                None
            );
        }
    }

    #[test]
    fn consecutive_suppressed_markers_never_replay_but_next_human_completion_chimes() {
        use harness_proto::SessionStatus::Idle;
        let now = chrono::Utc::now();
        let mut previous = baseline(Indicator::Working, None);
        let mut session = session(Idle, None, false);
        session.updated_at = now;
        for (turn, peer_only, archived, pending) in [
            ("archived-human", false, true, false),
            ("archived-peer", true, true, false),
            ("restored-peer", true, false, false),
            ("pending-human", false, false, true),
        ] {
            session.last_completed_turn = Some(turn.into());
            session.last_completed_peer_only = peer_only;
            assert_eq!(
                observe_session(&mut previous, &session, now, archived, pending),
                None,
                "suppressed marker {turn}"
            );
            // Clearing suppression without a new marker must stay silent.
            assert_eq!(
                observe_session(&mut previous, &session, now, false, false),
                None,
                "replayed marker {turn}"
            );
        }
        session.last_completed_turn = Some("next-human".into());
        session.last_completed_peer_only = false;
        assert_eq!(
            observe_session(&mut previous, &session, now, false, false),
            Some(Sound::Done)
        );
    }

    #[test]
    fn freshness_boundary_and_pending_send_consume_markers_without_delayed_completion() {
        use harness_proto::SessionStatus::{Idle, Working};
        let now = chrono::Utc::now();
        let stale_ms = harness_proto::view::SESSION_STALE_MS;
        for age_ms in [stale_ms - 1, stale_ms, stale_ms + 1] {
            for pending in [false, true] {
                let mut previous = baseline(Indicator::Working, None);
                let mut session = session(Idle, Some("completion"), false);
                session.updated_at = now - chrono::Duration::milliseconds(age_ms);
                assert_eq!(
                    observe_session(&mut previous, &session, now, false, pending),
                    (age_ms <= stale_ms && !pending).then_some(Sound::Done),
                    "age={age_ms}, pending={pending}"
                );
                // A fresh heartbeat and clearing send-pending cannot revive
                // a completion that was stale, pending, or already heard.
                session.status = Working;
                session.updated_at = now;
                assert_eq!(
                    observe_session(&mut previous, &session, now, false, false),
                    None
                );
                session.last_completed_turn = Some("next-completion".into());
                assert_eq!(
                    observe_session(&mut previous, &session, now, false, false),
                    Some(Sound::Done)
                );
            }
        }
    }

    #[test]
    fn coalesced_working_and_heartbeat_use_the_completed_turns_peer_only_flag() {
        use harness_proto::SessionStatus::{Idle, Working};
        let now = chrono::Utc::now();
        let mut previous = baseline(Indicator::Working, None);
        // A queued turn is already Working, but the marker still belongs to
        // a human completion and must produce its chime.
        let mut session = session(Working, Some("human"), false);
        session.updated_at = now;
        assert_eq!(
            observe_session(&mut previous, &session, now, false, false),
            Some(Sound::Done)
        );
        session.updated_at = now + chrono::Duration::seconds(1);
        let later = session.updated_at;
        assert_eq!(
            observe_session(&mut previous, &session, later, false, false),
            None
        );

        session.last_completed_turn = Some("peer".into());
        session.last_completed_peer_only = true;
        assert_eq!(
            observe_session(&mut previous, &session, later, false, false),
            None
        );
        // Starting a human turn and its heartbeat retain the completed turn's
        // peer-only flag rather than making the old marker eligible again.
        session.started_at = Some(later);
        assert_eq!(
            observe_session(&mut previous, &session, later, false, false),
            None
        );
        session.status = Idle;
        session.last_completed_turn = Some("next-human".into());
        session.last_completed_peer_only = false;
        assert_eq!(
            observe_session(&mut previous, &session, later, false, false),
            Some(Sound::Done)
        );
    }

    #[test]
    fn archived_peer_questions_and_errors_remain_actionable_once() {
        use harness_proto::SessionStatus::{AwaitingInput, Errored, Working};
        let now = chrono::Utc::now();
        for archived in [false, true] {
            for pending in [false, true] {
                for peer_only in [false, true] {
                    for (status, expected) in
                        [(AwaitingInput, Sound::Request), (Errored, Sound::Attention)]
                    {
                        let mut previous = baseline(Indicator::Working, Some("old"));
                        // A coalesced marker change cannot take priority over
                        // the actionable question or failure.
                        let mut session = session(status, Some("new"), peer_only);
                        session.updated_at = now;
                        assert_eq!(
                            observe_session(&mut previous, &session, now, archived, pending),
                            Some(expected),
                            "status={status:?}, peer_only={peer_only}, archived={archived}, pending={pending}"
                        );
                        assert_eq!(
                            observe_session(&mut previous, &session, now, archived, false),
                            None
                        );
                        // Resolving the actionable state must not replay its
                        // coalesced completion, including after restoring.
                        session.status = Working;
                        assert_eq!(
                            observe_session(&mut previous, &session, now, false, false),
                            None
                        );
                        session.status = status;
                        assert_eq!(
                            observe_session(&mut previous, &session, now, archived, pending),
                            Some(expected)
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn discarded_output_decisions_are_consumed_before_outputs_are_reenabled() {
        use harness_proto::SessionStatus::{AwaitingInput, Errored, Idle};
        let now = chrono::Utc::now();
        for (status, expected) in [
            (Idle, Sound::Done),
            (AwaitingInput, Sound::Request),
            (Errored, Sound::Attention),
        ] {
            let mut previous = baseline(Indicator::Working, None);
            let mut session = session(status, Some("finished"), false);
            session.updated_at = now;
            // Outputs may discard this decision, but not the baseline update.
            let discarded = observe_session(&mut previous, &session, now, false, false);
            assert_eq!(discarded, Some(expected));
            assert_eq!(
                observe_session(&mut previous, &session, now, false, false),
                None
            );
        }
    }

    #[test]
    fn background_chimes_ride_on_the_notification_so_focus_applies() {
        // Background with a banner: the system notification carries the
        // chime, so Focus / Do Not Disturb can silence it. Never also local.
        assert_eq!(
            plan_alert(true, true, false, true),
            AlertDelivery {
                banner: true,
                chime: Chime::WithNotification
            }
        );
        // Sound off: the banner is silent and nothing plays locally.
        assert_eq!(
            plan_alert(false, true, false, true),
            AlertDelivery {
                banner: true,
                chime: Chime::Silent
            }
        );
        assert_eq!(
            plan_alert(false, false, false, true),
            AlertDelivery {
                banner: false,
                chime: Chime::Silent
            }
        );
    }

    #[test]
    fn foreground_and_sound_only_chimes_are_kept_and_never_doubled() {
        // Focused, banner skipped by background-only: in-app chime.
        assert_eq!(
            plan_alert(true, false, true, true),
            AlertDelivery {
                banner: false,
                chime: Chime::Local
            }
        );
        // Focused with a banner anyway: one local chime, silent banner.
        assert_eq!(
            plan_alert(true, true, true, true),
            AlertDelivery {
                banner: true,
                chime: Chime::Local
            }
        );
        // Sound-only alerts in the background still ring, without a banner.
        assert_eq!(
            plan_alert(true, false, false, true),
            AlertDelivery {
                banner: false,
                chime: Chime::Local
            }
        );
        // No notification sound on this platform: the chime plays locally
        // and the banner stays as configured.
        assert_eq!(
            plan_alert(true, true, false, false),
            AlertDelivery {
                banner: true,
                chime: Chime::Local
            }
        );
        // Exhaustively: a wanted chime is never dropped, and an unwanted one
        // never plays.
        for sound in [false, true] {
            for banner in [false, true] {
                for focused in [false, true] {
                    for carried in [false, true] {
                        let plan = plan_alert(sound, banner, focused, carried);
                        assert_eq!(plan.banner, banner);
                        assert_eq!(plan.chime != Chime::Silent, sound);
                        if plan.chime == Chime::WithNotification {
                            assert!(banner && !focused && carried);
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn bundled_chime_names_are_distinct_wavs() {
        let names = [Sound::Done, Sound::Request, Sound::Attention].map(Sound::bundle_file_name);
        for name in names {
            assert!(name.starts_with("harness-") && name.ends_with(".wav"));
        }
        assert_ne!(names[0], names[1]);
        assert_ne!(names[1], names[2]);
        assert_ne!(names[0], names[2]);
    }

    #[test]
    fn temp_files_are_exclusive_and_cleaned_up() {
        let (first_file, first) = create_temp_file().expect("reserve first temp file");
        let (second_file, second) = create_temp_file().expect("reserve second temp file");
        assert_ne!(first.path, second.path);
        assert!(first.path.exists());
        assert!(second.path.exists());
        drop(first_file);
        drop(second_file);
        let first_path = first.path.clone();
        let second_path = second.path.clone();
        drop(first);
        drop(second);
        assert!(!first_path.exists());
        assert!(!second_path.exists());
    }

    #[test]
    fn embedded_chimes_are_wav() {
        for data in [
            SOUND_DONE,
            SOUND_REQUEST,
            SOUND_ATTENTION,
            #[cfg(any(target_os = "macos", target_os = "linux"))]
            SOUND_APPSHOT,
        ] {
            assert!(data.len() > 1000);
            assert_eq!(&data[..4], b"RIFF");
            assert_eq!(&data[8..12], b"WAVE");
        }
    }

    #[test]
    fn connectivity_boot_outages_seed_silently_then_later_outages_alert() {
        use harness_proto::ConnectivityState as State;
        let t0 = Instant::now();

        // Warm daemon: the first authoritative snapshot is already degraded.
        let mut warm = ConnectivityNotificationState::default();
        assert_eq!(warm.update(State::Disabled, false, t0), None);
        assert_eq!(warm.update(State::Offline, true, t0), None);
        assert_eq!(
            warm.update(State::Connected, true, t0 + Duration::from_secs(6)),
            None
        );
        assert_eq!(
            warm.update(State::Offline, true, t0 + Duration::from_secs(7)),
            Some(Sound::Attention)
        );

        // Cold daemon: the engine's grace initially masks the existing outage.
        let mut cold = ConnectivityNotificationState::default();
        assert_eq!(cold.update(State::Connected, true, t0), None);
        assert_eq!(
            cold.update(State::Offline, true, t0 + Duration::from_secs(4)),
            None
        );
        assert_eq!(
            cold.update(State::Connected, true, t0 + Duration::from_secs(5)),
            None
        );
        assert_eq!(
            cold.update(State::Reconnecting, true, t0 + Duration::from_secs(6)),
            Some(Sound::Attention)
        );

        // A quiet healthy boot may not publish another frame until the first
        // genuine outage; elapsed time arms that transition itself.
        let mut healthy = ConnectivityNotificationState::default();
        assert_eq!(healthy.update(State::Connected, true, t0), None);
        assert_eq!(
            healthy.update(State::Offline, true, t0 + Duration::from_secs(6)),
            Some(Sound::Attention)
        );

        // Replacing the runtime returns to bootstrap semantics even if the
        // prior runtime had already armed alerts.
        assert_eq!(
            healthy.update(State::Disabled, false, t0 + Duration::from_secs(7)),
            None
        );
        assert_eq!(
            healthy.update(State::Offline, true, t0 + Duration::from_secs(7)),
            None
        );
    }

    #[test]
    fn attention_gate_coalesces_session_and_connectivity_watch_callbacks() {
        let t0 = Instant::now();
        let mut gate = AttentionSoundGate::default();
        assert!(gate.should_play(t0));
        assert!(!gate.should_play(t0));
        assert!(!gate.should_play(t0 + Duration::from_millis(200)));
        assert!(gate.should_play(t0 + Duration::from_millis(250)));
    }
}
