//! graff's own provider sign-ins (xAI, Kimi, Z.AI) as the accounts screen sees
//! them: which are signed in, sign-out, and reading `graff login <id>`'s output.
//!
//! graff keeps each of these as one file, `<home>/.<id>/credentials/graff-oauth.json`
//! (its `credential_store.oauthPath`), written atomically and only on success.
//! Signed-in is that file's presence, the same test graff's own route listing
//! uses: it never refreshes a token or touches the network. CodeGraff's account
//! and the Codex (ChatGPT) login live elsewhere, so they are not here.
//!
//! `graff login` exits 0 even when it refuses (`✗ …` and return), so nothing
//! here trusts the exit code: a sign-in counts only when the credential file
//! changed, or graff printed its `✓` line.

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use harness_proto::{GRAFF_LOGIN_PROVIDERS, GraffLoginProvider};

/// The credential file for `provider`, or `None` for an id graff does not sign
/// into itself (so an RPC param can never name an arbitrary path).
pub fn credential_path(home: &Path, provider: &str) -> Option<PathBuf> {
    GRAFF_LOGIN_PROVIDERS
        .iter()
        .any(|(id, _)| *id == provider)
        .then(|| {
            if provider == "chatgpt-new" {
                return home
                    .join(".graff")
                    .join("credentials")
                    .join("chatgpt-new.json");
            }
            home.join(format!(".{provider}"))
                .join("credentials")
                .join("graff-oauth.json")
        })
}

/// Every provider with whether a credential file exists for it, in the order
/// of [`GRAFF_LOGIN_PROVIDERS`].
pub fn list(home: &Path) -> Vec<GraffLoginProvider> {
    GRAFF_LOGIN_PROVIDERS
        .iter()
        .map(|(id, name)| GraffLoginProvider {
            id: (*id).to_string(),
            name: (*name).to_string(),
            signed_in: credential_path(home, id).is_some_and(|path| path.is_file()),
        })
        .collect()
}

/// The credential file's modified time: a sign-in landed when this differs
/// from what it was before the login started.
pub fn credential_stamp(home: &Path, provider: &str) -> Option<SystemTime> {
    std::fs::metadata(credential_path(home, provider)?)
        .and_then(|meta| meta.modified())
        .ok()
}

/// Remove the credential file. Already signed out is success.
pub fn sign_out(home: &Path, provider: &str) -> std::io::Result<()> {
    let Some(path) = credential_path(home, provider) else {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("graff has no sign-in for {provider}"),
        ));
    };
    match std::fs::remove_file(path) {
        Err(err) if err.kind() != std::io::ErrorKind::NotFound => Err(err),
        _ => Ok(()),
    }
}

/// A directory holding no-op `open` and `xdg-open`, for the front of a login
/// child's PATH: graff opens its sign-in page with those, and the app opens it
/// on the machine the user is at. Unix only — elsewhere graff has no opener to
/// mute. Idempotent.
#[cfg(unix)]
pub fn no_open_dir(root: &Path) -> Option<PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    const SCRIPT: &str = "#!/bin/sh\nexit 0\n";
    let dir = root.join(".noop-open");
    std::fs::create_dir_all(&dir).ok()?;
    for name in ["open", "xdg-open"] {
        let path = dir.join(name);
        if std::fs::read_to_string(&path).ok().as_deref() != Some(SCRIPT) {
            std::fs::write(&path, SCRIPT).ok()?;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).ok()?;
        }
    }
    Some(dir)
}

#[cfg(not(unix))]
pub fn no_open_dir(_root: &Path) -> Option<PathBuf> {
    None
}

/// Drop terminal colour escapes so a marker at the start of a line is found
/// whether or not graff coloured it.
fn strip_ansi(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            // `ESC [ … <letter>`
            for c in chars.by_ref() {
                if c.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// The sign-in page graff prints after "open this URL". Only a complete line
/// counts: a URL still being written is not returned.
pub fn scan_login_url(output: &str) -> Option<String> {
    let after = &output[output.find("open this URL")?..];
    let rest = &after[after.find("https://")?..];
    let end = rest.find(char::is_whitespace)?;
    Some(rest[..end].to_string())
}

/// The code to confirm on the page (`and confirm the code:  ABCD-EFGH`); xAI
/// and Kimi print one, Z.AI does not. Only a complete line counts.
pub fn scan_device_code(output: &str) -> Option<String> {
    const MARKER: &str = "confirm the code:";
    let rest = &output[output.find(MARKER)? + MARKER.len()..];
    let line = &rest[..rest.find('\n')?];
    let code = line.trim();
    (!code.is_empty()).then(|| code.to_string())
}

/// graff's own words for why a sign-in failed: its last `✗` line.
pub fn scan_failure(output: &str) -> Option<String> {
    output.lines().rev().find_map(|line| {
        let line = strip_ansi(line);
        let message = line.trim_start().strip_prefix('✗')?.trim();
        (!message.is_empty()).then(|| message.to_string())
    })
}

/// Did graff print its `✓ logged in…` line?
pub fn saw_success(output: &str) -> bool {
    output
        .lines()
        .any(|line| strip_ansi(line).trim_start().starts_with('✓'))
}

/// ChatGPT's zero exit and generic signed-in prefix also cover denied plan
/// access. Only its explicit plan-granted report qualifies for recovery.
pub fn chatgpt_plan_granted(output: &str) -> bool {
    output.lines().any(|line| {
        let line = strip_ansi(line);
        let line = line.trim();
        line.starts_with("✓ signed in to ChatGPT as ") && line.contains("; plan usage is on.")
    })
}

/// The ChatGPT sign-in graff is waiting on, for finishing it on another
/// device: OpenAI's authorize page, plus the loopback redirect and `state`
/// that a completed sign-in must come back with.
#[derive(Debug, Clone, PartialEq)]
pub struct ChatgptRelay {
    pub url: String,
    pub redirect: reqwest::Url,
    pub state: String,
}

/// The authorize page `graff login chatgpt-new` printed, once graff is
/// listening for its callback. Only OpenAI's own page with a `127.0.0.1`
/// redirect qualifies: that redirect is the only address the host will ever
/// deliver a relayed sign-in to.
pub fn scan_chatgpt_relay(output: &str) -> Option<ChatgptRelay> {
    if !output.contains("waiting for the sign-in on ") {
        return None;
    }
    let start = output.find("https://auth.openai.com/")?;
    let rest = &output[start..];
    let url = &rest[..rest.find(char::is_whitespace)?];
    let parsed = reqwest::Url::parse(url).ok()?;
    if parsed.scheme() != "https" || parsed.host_str() != Some("auth.openai.com") {
        return None;
    }
    let param = |name: &str| {
        parsed
            .query_pairs()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.into_owned())
    };
    let redirect = reqwest::Url::parse(&param("redirect_uri")?).ok()?;
    let state = param("state").filter(|state| !state.is_empty())?;
    let loopback = redirect.scheme() == "http"
        && redirect.host_str() == Some("127.0.0.1")
        && redirect.port().is_some()
        && redirect.query().is_none()
        && redirect.fragment().is_none();
    loopback.then(|| ChatgptRelay {
        url: url.to_string(),
        redirect,
        state,
    })
}

/// The callback to deliver for a sign-in finished elsewhere: the redirect the
/// browser landed on, accepted only when it is exactly `relay`'s redirect with
/// its `state` and an outcome (`code` or `error`). The returned URL is built
/// from the expected redirect, never from the caller's host, port or path.
pub fn relayed_callback(relay: &ChatgptRelay, landed: &str) -> Result<reqwest::Url, &'static str> {
    const NOT_IT: &str = "That isn't the address ChatGPT sent you to. Sign in again.";
    let landed = reqwest::Url::parse(landed.trim()).map_err(|_| NOT_IT)?;
    let same_place = landed.scheme() == relay.redirect.scheme()
        && landed.host_str() == relay.redirect.host_str()
        && landed.port_or_known_default() == relay.redirect.port_or_known_default()
        && landed.path() == relay.redirect.path();
    if !same_place {
        return Err(NOT_IT);
    }
    let pairs: Vec<(String, String)> = landed
        .query_pairs()
        .map(|(key, value)| (key.into_owned(), value.into_owned()))
        .collect();
    let has = |name: &str| pairs.iter().any(|(key, _)| key == name);
    let state_matches = pairs
        .iter()
        .filter(|(key, _)| key == "state")
        .map(|(_, value)| value)
        .eq([&relay.state]);
    if !state_matches {
        return Err("That sign-in belongs to an older attempt. Sign in again.");
    }
    if !has("code") && !has("error") {
        return Err(NOT_IT);
    }
    let mut target = relay.redirect.clone();
    target.query_pairs_mut().extend_pairs(&pairs);
    Ok(target)
}

/// What to tell the user when a sign-in ended without one: graff's `✗` line,
/// else its last line of output, else a plain sentence.
pub fn failure_message(output: &str) -> String {
    scan_failure(output)
        .or_else(|| {
            output
                .lines()
                .rev()
                .map(|line| strip_ansi(line).trim().to_string())
                .find(|line| !line.is_empty())
        })
        .unwrap_or_else(|| "The sign-in did not finish.".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Verbatim from `graff login xai` / `kimi` / `zai` (oauth.zig, oauth_zai.zig).
    const XAI: &str = "\nTo log in to Grok (xAI), open this URL (browser should open automatically):\n\n  https://accounts.x.ai/device?user_code=ABCD-1234\n\nand confirm the code:  ABCD-1234\n\nwaiting for authorization…\n";
    const KIMI: &str = "\nTo log in to Kimi, open this URL (browser should open automatically):\n\n  https://www.kimi.com/code/authorize_device?user_code=WXYZ\n\nand confirm the code:  WXYZ\n\nwaiting for authorization…\n";
    const ZAI: &str = "\nTo log in to Z.AI Coding Plan, open this URL (browser should open automatically):\n\n  https://chat.z.ai/cli/authorize?flow=f1\n\nwaiting for authorization…\n";

    // Shape of `graff login chatgpt-new` with its browser open muted (0.0.302.18).
    const CHATGPT: &str = "\nSign in with ChatGPT (your browser should open it):\n\nhttps://auth.openai.com/api/accounts/authorize?client_id=dynamic_agent_client&response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback&scope=openid%20profile&state=st4te&nonce=n&code_challenge=c&code_challenge_method=S256\n\nwaiting for the sign-in on http://127.0.0.1:1455/auth/callback …\n";

    #[test]
    fn chatgpt_relay_reads_the_authorize_page_once_graff_listens() {
        let relay = scan_chatgpt_relay(CHATGPT).expect("relay");
        assert!(
            relay
                .url
                .starts_with("https://auth.openai.com/api/accounts/authorize?")
        );
        assert_eq!(
            relay.redirect.as_str(),
            "http://127.0.0.1:1455/auth/callback"
        );
        assert_eq!(relay.state, "st4te");
        // Not listening yet: nothing to hand out.
        let (printed, _) = CHATGPT.split_once("waiting").unwrap();
        assert_eq!(scan_chatgpt_relay(printed), None);
        // Anything but OpenAI's page with a loopback redirect is refused.
        for bad in [
            CHATGPT.replace("auth.openai.com/api", "auth.openai.com.evil.test/api"),
            CHATGPT.replace("https://auth.openai.com", "http://auth.openai.com"),
            CHATGPT.replace("127.0.0.1%3A1455", "evil.test%3A1455"),
            CHATGPT.replace("127.0.0.1%3A1455", "127.0.0.1"),
            CHATGPT.replace("state=st4te&", ""),
        ] {
            assert_eq!(scan_chatgpt_relay(&bad), None, "{bad}");
        }
    }

    #[test]
    fn relayed_callback_only_reaches_the_expected_loopback() {
        let relay = scan_chatgpt_relay(CHATGPT).unwrap();
        let ok = relayed_callback(
            &relay,
            " http://127.0.0.1:1455/auth/callback?code=abc&state=st4te&client_id=issued \n",
        )
        .unwrap();
        assert_eq!(
            ok.as_str(),
            "http://127.0.0.1:1455/auth/callback?code=abc&state=st4te&client_id=issued"
        );
        // A provider error still goes to graff, so it ends the sign-in itself.
        assert!(
            relayed_callback(
                &relay,
                "http://127.0.0.1:1455/auth/callback?error=access_denied&state=st4te"
            )
            .is_ok()
        );
        for bad in [
            "http://127.0.0.1:1455/auth/callback?code=abc&state=other",
            "http://127.0.0.1:1455/auth/callback?code=abc",
            "http://127.0.0.1:1455/auth/callback?code=abc&state=st4te&state=x",
            "http://127.0.0.1:1455/auth/callback?state=st4te",
            "http://127.0.0.1:1456/auth/callback?code=abc&state=st4te",
            "http://127.0.0.1:1455/admin?code=abc&state=st4te",
            "http://localhost:1455/auth/callback?code=abc&state=st4te",
            "https://127.0.0.1:1455/auth/callback?code=abc&state=st4te",
            "http://evil.test:1455/auth/callback?code=abc&state=st4te",
            "not a url",
        ] {
            assert!(relayed_callback(&relay, bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn reauth_chatgpt_requires_explicit_plan_grant() {
        assert!(chatgpt_plan_granted(
            "✓ signed in to ChatGPT as fixture; plan usage is on.\n"
        ));
        assert!(chatgpt_plan_granted(
            "✓ signed in to ChatGPT as fixture; plan usage is on. Use it with /model chatgpt-new or `graff --model chatgpt-new/gpt-6.1-sol`. Manage usage: https://chatgpt.com/settings/usage\n"
        ));
        for output in [
            "✓ signed in to ChatGPT as fixture, but plan usage was not allowed.\n",
            "✗ ChatGPT sign-in was cancelled. Nothing changed.\n",
            "✗ ChatGPT sign-in failed: rejected\n",
            "✓ signed in to ChatGPT as fixture\n",
        ] {
            assert!(!chatgpt_plan_granted(output));
        }
    }

    #[test]
    fn credential_paths_follow_graffs_credential_store() {
        let home = Path::new("/h");
        assert_eq!(
            credential_path(home, "xai"),
            Some(PathBuf::from("/h/.xai/credentials/graff-oauth.json"))
        );
        assert_eq!(
            credential_path(home, "kimi"),
            Some(PathBuf::from("/h/.kimi/credentials/graff-oauth.json"))
        );
        assert_eq!(
            credential_path(home, "zai"),
            Some(PathBuf::from("/h/.zai/credentials/graff-oauth.json"))
        );
        assert_eq!(
            credential_path(home, "chatgpt-new"),
            Some(PathBuf::from("/h/.graff/credentials/chatgpt-new.json"))
        );
    }

    #[test]
    fn only_graffs_own_providers_have_a_credential_path() {
        let home = Path::new("/h");
        for other in [
            "",
            "codex",
            "codegraff",
            "openai",
            "../xai",
            "xai/../../etc",
        ] {
            assert_eq!(credential_path(home, other), None, "{other:?}");
        }
    }

    #[test]
    fn list_reports_presence_in_provider_order() {
        let dir = tempfile::tempdir().unwrap();
        let rows = list(dir.path());
        assert_eq!(
            rows.iter()
                .map(|r| (r.id.as_str(), r.signed_in))
                .collect::<Vec<_>>(),
            [
                ("xai", false),
                ("kimi", false),
                ("zai", false),
                ("chatgpt-new", false)
            ]
        );
        let path = credential_path(dir.path(), "kimi").unwrap();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "{}").unwrap();
        let rows = list(dir.path());
        assert_eq!(
            rows.iter()
                .map(|r| (r.name.as_str(), r.signed_in))
                .collect::<Vec<_>>(),
            [
                ("xAI", false),
                ("Kimi", true),
                ("Z.AI", false),
                ("ChatGPT", false)
            ]
        );
    }

    #[test]
    fn sign_out_removes_only_that_providers_credential() {
        let dir = tempfile::tempdir().unwrap();
        for id in ["xai", "kimi"] {
            let path = credential_path(dir.path(), id).unwrap();
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, "{}").unwrap();
        }
        sign_out(dir.path(), "xai").unwrap();
        assert!(!credential_path(dir.path(), "xai").unwrap().exists());
        assert!(credential_path(dir.path(), "kimi").unwrap().exists());
        // Already signed out is fine; an unknown provider is refused.
        sign_out(dir.path(), "xai").unwrap();
        assert!(sign_out(dir.path(), "codex").is_err());
    }

    #[test]
    fn stamp_changes_when_a_login_rewrites_the_credential() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(credential_stamp(dir.path(), "zai"), None);
        let path = credential_path(dir.path(), "zai").unwrap();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "one").unwrap();
        let first = credential_stamp(dir.path(), "zai");
        assert!(first.is_some());
        let later = first.unwrap() + std::time::Duration::from_secs(5);
        let file = std::fs::File::options().write(true).open(&path).unwrap();
        file.set_modified(later).unwrap();
        assert_ne!(credential_stamp(dir.path(), "zai"), first);
    }

    #[test]
    fn reads_the_link_and_code_from_each_providers_output() {
        assert_eq!(
            scan_login_url(XAI).as_deref(),
            Some("https://accounts.x.ai/device?user_code=ABCD-1234")
        );
        assert_eq!(scan_device_code(XAI).as_deref(), Some("ABCD-1234"));
        assert_eq!(
            scan_login_url(KIMI).as_deref(),
            Some("https://www.kimi.com/code/authorize_device?user_code=WXYZ")
        );
        assert_eq!(scan_device_code(KIMI).as_deref(), Some("WXYZ"));
        assert_eq!(
            scan_login_url(ZAI).as_deref(),
            Some("https://chat.z.ai/cli/authorize?flow=f1")
        );
        assert_eq!(scan_device_code(ZAI), None);
    }

    #[test]
    fn an_unfinished_line_is_not_a_link_or_a_code() {
        // Mid-write: the URL has no line end yet, and neither has the code.
        assert_eq!(
            scan_login_url("\nTo log in, open this URL (…):\n\n  https://accounts.x.a"),
            None
        );
        assert_eq!(scan_device_code("\nand confirm the code:  ABC"), None);
        assert_eq!(scan_login_url(""), None);
        // A URL before the marker is not the sign-in page.
        assert_eq!(
            scan_login_url("see https://example.com/docs\nnothing else\n"),
            None
        );
    }

    #[test]
    fn failure_is_the_last_marked_line_with_or_without_colour() {
        let out = "\nTo log in to Kimi, open this URL (…):\n\n  https://k/x\n\nand confirm the code:  Q\n\nwaiting for authorization…\n✗ the code expired — run `graff login kimi` again\n";
        assert_eq!(
            scan_failure(out).as_deref(),
            Some("the code expired — run `graff login kimi` again")
        );
        assert_eq!(
            scan_failure("\u{1b}[31m✗\u{1b}[0m nope\n").as_deref(),
            Some("nope")
        );
        assert_eq!(scan_failure(XAI), None);
    }

    #[test]
    fn success_marker_survives_colour() {
        assert!(saw_success("✓ logged into Grok (xAI) — wrote /h/.xai/…\n"));
        assert!(saw_success(
            "\u{1b}[32m✓\u{1b}[0m logged into Z.AI Coding Plan — wrote /h/.zai/…\n"
        ));
        assert!(!saw_success("✗ timed out waiting for authorization\n"));
        assert!(!saw_success(XAI));
    }

    #[test]
    fn failure_message_falls_back_to_the_last_line_then_a_sentence() {
        assert_eq!(failure_message("✗ nope\n"), "nope");
        assert_eq!(failure_message("boom\nlast words\n\n"), "last words");
        assert_eq!(failure_message(""), "The sign-in did not finish.");
    }

    #[cfg(unix)]
    #[test]
    fn no_open_dir_holds_executable_stand_ins_and_is_idempotent() {
        use std::os::unix::fs::PermissionsExt;
        let root = tempfile::tempdir().unwrap();
        let dir = no_open_dir(root.path()).unwrap();
        assert_eq!(no_open_dir(root.path()), Some(dir.clone()));
        for name in ["open", "xdg-open"] {
            let meta = std::fs::metadata(dir.join(name)).unwrap();
            assert_eq!(meta.permissions().mode() & 0o777, 0o755, "{name}");
        }
    }
}
