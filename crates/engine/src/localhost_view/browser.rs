//! Finding a Chromium-family browser on this computer and running it headless
//! with a DevTools connection only this engine holds.
//!
//! On macOS and Linux the DevTools protocol runs over a pair of pipes handed
//! to the browser as fds 3 and 4 (`--remote-debugging-pipe`): no port is
//! opened, so no other local user or process can drive it. Windows has no fd
//! inheritance of that kind, so there the browser listens on a port it picks
//! on 127.0.0.1 (`--remote-debugging-port=0`), read back from the private
//! profile's `DevToolsActivePort`.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
use tokio::sync::mpsc;

/// Points at a browser executable to use instead of the ones searched for.
pub const BROWSER_ENV: &str = "HARNESS_LOCALHOST_BROWSER";
/// How long a launched browser has to open its DevTools connection.
const LAUNCH_TIMEOUT: Duration = Duration::from_secs(20);

/// The browsers searched for, best first, as the user would know them.
pub const BROWSER_NAMES: &str = "Google Chrome, Microsoft Edge, Brave or Chromium";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Os {
    Mac,
    Linux,
    Windows,
}

impl Os {
    pub fn current() -> Self {
        if cfg!(target_os = "macos") {
            Os::Mac
        } else if cfg!(windows) {
            Os::Windows
        } else {
            Os::Linux
        }
    }
}

/// Where a browser might be, best first. `home` is the user's home folder,
/// `path` the `PATH` directories, `env` looks up Windows install roots.
pub fn candidates(
    os: Os,
    home: Option<&Path>,
    path: &[PathBuf],
    env: &dyn Fn(&str) -> Option<PathBuf>,
) -> Vec<PathBuf> {
    match os {
        Os::Mac => {
            const APPS: [(&str, &str); 4] = [
                ("Google Chrome.app", "Google Chrome"),
                ("Chromium.app", "Chromium"),
                ("Microsoft Edge.app", "Microsoft Edge"),
                ("Brave Browser.app", "Brave Browser"),
            ];
            let mut roots = vec![PathBuf::from("/Applications")];
            if let Some(home) = home {
                roots.push(home.join("Applications"));
            }
            APPS.iter()
                .flat_map(|(app, exe)| {
                    roots
                        .iter()
                        .map(move |root| root.join(app).join("Contents/MacOS").join(exe))
                })
                .collect()
        }
        Os::Linux => {
            const NAMES: [&str; 8] = [
                "google-chrome",
                "google-chrome-stable",
                "chromium",
                "chromium-browser",
                "microsoft-edge",
                "microsoft-edge-stable",
                "brave-browser",
                "brave",
            ];
            NAMES
                .iter()
                .flat_map(|name| path.iter().map(move |dir| dir.join(name)))
                .collect()
        }
        Os::Windows => {
            const EXES: [&str; 4] = [
                r"Google\Chrome\Application\chrome.exe",
                r"Microsoft\Edge\Application\msedge.exe",
                r"BraveSoftware\Brave-Browser\Application\brave.exe",
                r"Chromium\Application\chrome.exe",
            ];
            let roots: Vec<PathBuf> = ["ProgramFiles", "ProgramFiles(x86)", "LocalAppData"]
                .iter()
                .filter_map(|var| env(var))
                .collect();
            EXES.iter()
                .flat_map(|exe| roots.iter().map(move |root| root.join(exe)))
                .collect()
        }
    }
}

/// The first candidate that exists.
pub fn pick(candidates: &[PathBuf], exists: impl Fn(&Path) -> bool) -> Option<PathBuf> {
    candidates.iter().find(|p| exists(p)).cloned()
}

/// The browser to run: `HARNESS_LOCALHOST_BROWSER` if it names a file, else
/// the best one installed.
pub fn find() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os(BROWSER_ENV).map(PathBuf::from)
        && path.is_file()
    {
        return Some(path);
    }
    let home = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from);
    let path: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).collect())
        .unwrap_or_default();
    let env = |var: &str| std::env::var_os(var).map(PathBuf::from);
    pick(
        &candidates(Os::current(), home.as_deref(), &path, &env),
        Path::is_file,
    )
}

/// How the engine talks to the browser.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Transport {
    /// fds 3 and 4, NUL-terminated JSON messages.
    Pipe,
    /// A WebSocket on a 127.0.0.1 port the browser picks.
    Port,
}

impl Transport {
    pub fn preferred() -> Self {
        if cfg!(unix) {
            Transport::Pipe
        } else {
            Transport::Port
        }
    }
}

/// The command line: headless, a throwaway profile, nothing that phones home
/// or prompts, and a phone-sized window.
pub fn launch_args(profile: &Path, transport: Transport) -> Vec<String> {
    let mut args = vec![
        "--headless=new".to_string(),
        format!("--user-data-dir={}", profile.display()),
        "--no-first-run".into(),
        "--no-default-browser-check".into(),
        "--disable-extensions".into(),
        "--disable-sync".into(),
        "--disable-default-apps".into(),
        "--disable-background-networking".into(),
        "--disable-component-update".into(),
        "--disable-features=Translate,MediaRouter,OptimizationHints".into(),
        "--metrics-recording-only".into(),
        // No Keychain or keyring prompt for a profile nobody signs in to.
        "--password-store=basic".into(),
        "--use-mock-keychain".into(),
        "--mute-audio".into(),
        "--hide-scrollbars".into(),
        // Screencasts ignore the emulated scale; a real 2x keeps text sharp.
        "--force-device-scale-factor=2".into(),
        "--window-size=390,844".into(),
    ];
    args.push(match transport {
        Transport::Pipe => "--remote-debugging-pipe".into(),
        Transport::Port => "--remote-debugging-port=0".into(),
    });
    args.push("about:blank".into());
    args
}

/// A running headless browser: its process, its profile (removed when this
/// drops), and the two halves of its DevTools connection.
pub struct Launched {
    pub child: tokio::process::Child,
    pub profile: tempfile::TempDir,
    /// Outgoing DevTools messages.
    pub tx: mpsc::UnboundedSender<String>,
    /// Incoming DevTools messages; closes when the browser goes away.
    pub rx: mpsc::UnboundedReceiver<String>,
}

pub async fn launch(executable: &Path, transport: Transport) -> Result<Launched, String> {
    let profile = tempfile::Builder::new()
        .prefix("harness-localhost-")
        .tempdir()
        .map_err(|e| format!("making the browser's profile: {e}"))?;
    let mut cmd = tokio::process::Command::new(executable);
    cmd.args(launch_args(profile.path(), transport))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    match transport {
        Transport::Pipe => launch_pipe(cmd, profile).await,
        Transport::Port => launch_port(cmd, profile).await,
    }
}

#[cfg(unix)]
async fn launch_pipe(
    mut cmd: tokio::process::Command,
    profile: tempfile::TempDir,
) -> Result<Launched, String> {
    use std::os::fd::{AsRawFd, OwnedFd};
    // The browser reads commands from fd 3 and writes replies to fd 4.
    let (to_browser_r, to_browser_w) = std::io::pipe().map_err(|e| e.to_string())?;
    let (from_browser_r, from_browser_w) = std::io::pipe().map_err(|e| e.to_string())?;
    let child_in = to_browser_r.as_raw_fd();
    let child_out = from_browser_w.as_raw_fd();
    // SAFETY: only async-signal-safe calls (fcntl, dup2) between fork and exec.
    unsafe {
        cmd.pre_exec(move || {
            // Move both ends clear of 3 and 4 first, so neither dup2 clobbers
            // the other; dup2 then leaves 3 and 4 open across exec.
            let high_in = libc::fcntl(child_in, libc::F_DUPFD, 10);
            let high_out = libc::fcntl(child_out, libc::F_DUPFD, 10);
            if high_in < 0
                || high_out < 0
                || libc::dup2(high_in, 3) < 0
                || libc::dup2(high_out, 4) < 0
            {
                return Err(std::io::Error::last_os_error());
            }
            libc::close(high_in);
            libc::close(high_out);
            Ok(())
        });
    }
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("starting the browser: {e}"))?;
    // The child holds its own copies now.
    drop(to_browser_r);
    drop(from_browser_w);
    drain_stderr(&mut child);

    let writer = tokio::net::unix::pipe::Sender::from_owned_fd(OwnedFd::from(to_browser_w))
        .map_err(|e| format!("connecting to the browser: {e}"))?;
    let reader = tokio::net::unix::pipe::Receiver::from_owned_fd(OwnedFd::from(from_browser_r))
        .map_err(|e| format!("connecting to the browser: {e}"))?;
    let (tx, mut out) = mpsc::unbounded_channel::<String>();
    let (inbound, rx) = mpsc::unbounded_channel::<String>();
    tokio::spawn(async move {
        let mut writer = writer;
        while let Some(message) = out.recv().await {
            let mut bytes = message.into_bytes();
            bytes.push(0);
            if writer.write_all(&bytes).await.is_err() || writer.flush().await.is_err() {
                return;
            }
        }
    });
    tokio::spawn(async move {
        let mut reader = tokio::io::BufReader::with_capacity(1 << 20, reader);
        let mut buf = Vec::new();
        loop {
            buf.clear();
            match reader.read_until(0, &mut buf).await {
                Ok(0) | Err(_) => return,
                Ok(_) => {
                    if buf.last() == Some(&0) {
                        buf.pop();
                    }
                    let text = String::from_utf8_lossy(&buf).into_owned();
                    if inbound.send(text).is_err() {
                        return;
                    }
                }
            }
        }
    });
    Ok(Launched {
        child,
        profile,
        tx,
        rx,
    })
}

#[cfg(not(unix))]
async fn launch_pipe(
    cmd: tokio::process::Command,
    profile: tempfile::TempDir,
) -> Result<Launched, String> {
    launch_port(cmd, profile).await
}

async fn launch_port(
    mut cmd: tokio::process::Command,
    profile: tempfile::TempDir,
) -> Result<Launched, String> {
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("starting the browser: {e}"))?;
    drain_stderr(&mut child);
    let active = profile.path().join("DevToolsActivePort");
    let deadline = tokio::time::Instant::now() + LAUNCH_TIMEOUT;
    let (port, path) = loop {
        if let Ok(text) = tokio::fs::read_to_string(&active).await
            && let Some(found) = parse_active_port(&text)
        {
            break found;
        }
        if tokio::time::Instant::now() >= deadline {
            return Err("the browser didn't open its DevTools port".into());
        }
        if let Ok(Some(status)) = child.try_wait() {
            return Err(format!("the browser exited at start ({status})"));
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    };
    let url = format!("ws://127.0.0.1:{port}{path}");
    let (socket, _) = tokio_tungstenite::connect_async(url.as_str())
        .await
        .map_err(|e| format!("connecting to the browser: {e}"))?;
    let (mut sink, mut stream) = socket.split();
    let (tx, mut out) = mpsc::unbounded_channel::<String>();
    let (inbound, rx) = mpsc::unbounded_channel::<String>();
    tokio::spawn(async move {
        use tokio_tungstenite::tungstenite::Message;
        while let Some(message) = out.recv().await {
            if sink.send(Message::Text(message)).await.is_err() {
                return;
            }
        }
    });
    tokio::spawn(async move {
        use tokio_tungstenite::tungstenite::Message;
        while let Some(Ok(message)) = stream.next().await {
            let text = match message {
                Message::Text(text) => text.to_string(),
                Message::Binary(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
                Message::Close(_) => return,
                _ => continue,
            };
            if inbound.send(text).is_err() {
                return;
            }
        }
    });
    Ok(Launched {
        child,
        profile,
        tx,
        rx,
    })
}

/// `DevToolsActivePort`: the port on the first line, the browser's
/// WebSocket path on the second.
pub fn parse_active_port(text: &str) -> Option<(u16, String)> {
    let mut lines = text.lines();
    let port = lines
        .next()?
        .trim()
        .parse::<u16>()
        .ok()
        .filter(|p| *p != 0)?;
    let path = lines.next()?.trim();
    path.starts_with("/devtools/browser/")
        .then(|| (port, path.to_string()))
}

/// Keep the browser's stderr from filling its pipe; log a few lines of it.
fn drain_stderr(child: &mut tokio::process::Child) {
    let Some(stderr) = child.stderr.take() else {
        return;
    };
    tokio::spawn(async move {
        let mut lines = tokio::io::BufReader::new(stderr).lines();
        let mut logged = 0;
        while let Ok(Some(line)) = lines.next_line().await {
            if logged < 20 && !line.trim().is_empty() {
                logged += 1;
                tracing::debug!(target: "localhost_view", "browser: {line}");
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exists_in(paths: &[&str]) -> impl Fn(&Path) -> bool {
        let set: Vec<PathBuf> = paths.iter().map(PathBuf::from).collect();
        move |p| set.iter().any(|s| s == p)
    }

    #[test]
    fn macos_prefers_chrome_then_chromium_edge_brave_and_checks_home_applications() {
        let home = PathBuf::from("/Users/test");
        let list = candidates(Os::Mac, Some(&home), &[], &|_| None);
        let edge = "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge";
        let brave = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser";
        let chrome_home = "/Users/test/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
        let chromium = "/Applications/Chromium.app/Contents/MacOS/Chromium";
        assert_eq!(
            pick(&list, exists_in(&[brave, edge])),
            Some(PathBuf::from(edge))
        );
        assert_eq!(
            pick(&list, exists_in(&[brave, chromium, chrome_home])),
            Some(PathBuf::from(chrome_home)),
            "Chrome in ~/Applications beats every other browser"
        );
        assert_eq!(pick(&list, exists_in(&[])), None);
        assert_eq!(
            list[0],
            PathBuf::from("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        );
    }

    #[test]
    fn linux_searches_path_by_browser_then_directory() {
        let path = [PathBuf::from("/usr/local/bin"), PathBuf::from("/usr/bin")];
        let list = candidates(Os::Linux, None, &path, &|_| None);
        assert_eq!(
            pick(
                &list,
                exists_in(&["/usr/local/bin/chromium", "/usr/bin/google-chrome-stable"])
            ),
            Some(PathBuf::from("/usr/bin/google-chrome-stable"))
        );
        assert_eq!(
            pick(
                &list,
                exists_in(&["/usr/bin/brave-browser", "/usr/bin/microsoft-edge"])
            ),
            Some(PathBuf::from("/usr/bin/microsoft-edge"))
        );
    }

    #[test]
    fn windows_looks_under_program_files_and_local_app_data() {
        let env = |var: &str| match var {
            "ProgramFiles" => Some(PathBuf::from(r"C:\Program Files")),
            "LocalAppData" => Some(PathBuf::from(r"C:\Users\test\AppData\Local")),
            _ => None,
        };
        let list = candidates(Os::Windows, None, &[], &env);
        let edge =
            PathBuf::from(r"C:\Program Files").join(r"Microsoft\Edge\Application\msedge.exe");
        let chrome_user = PathBuf::from(r"C:\Users\test\AppData\Local")
            .join(r"Google\Chrome\Application\chrome.exe");
        assert_eq!(
            pick(&list, |p| p == edge || p == chrome_user),
            Some(chrome_user.clone()),
            "Chrome anywhere beats Edge"
        );
        assert_eq!(pick(&list, |p| p == edge), Some(edge));
        assert_eq!(list.len(), 8, "two roots × four browsers");
    }

    #[test]
    fn the_browser_runs_headless_with_a_private_profile_and_no_open_port_on_unix() {
        let args = launch_args(Path::new("/tmp/profile"), Transport::Pipe);
        for expected in [
            "--headless=new",
            "--user-data-dir=/tmp/profile",
            "--no-first-run",
            "--no-default-browser-check",
            "--remote-debugging-pipe",
            "--use-mock-keychain",
        ] {
            assert!(args.iter().any(|a| a == expected), "{expected}");
        }
        assert!(
            !args
                .iter()
                .any(|a| a.starts_with("--remote-debugging-port"))
        );
        assert_eq!(args.last().map(String::as_str), Some("about:blank"));
        let port = launch_args(Path::new("/tmp/profile"), Transport::Port);
        assert!(port.iter().any(|a| a == "--remote-debugging-port=0"));
        if cfg!(unix) {
            assert_eq!(Transport::preferred(), Transport::Pipe);
        }
    }

    #[test]
    fn devtools_active_port_is_read_strictly() {
        assert_eq!(
            parse_active_port("52341\n/devtools/browser/0b1c-22\n"),
            Some((52341, "/devtools/browser/0b1c-22".into()))
        );
        assert_eq!(parse_active_port("0\n/devtools/browser/x"), None);
        assert_eq!(parse_active_port("52341\n/json"), None);
        assert_eq!(parse_active_port("52341"), None);
        assert_eq!(parse_active_port(""), None);
    }
}
