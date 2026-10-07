//! graff's own provider sign-ins (xAI, Kimi, Z.AI, ChatGPT) as the accounts
//! screen sees them: which are signed in, sign-out, and reading
//! `graff login <id>`'s output.
//!
//! graff keeps each of these as one file, `<home>/.<id>/credentials/graff-oauth.json`
//! (its `credential_store.oauthPath`), written atomically and only on success.
//! Signed-in is that file's presence, the same test graff's own route listing
//! uses: it never refreshes a token or touches the network. CodeGraff's account
//! and the Codex (ChatGPT) login live elsewhere, so they are not here.
//!
//! ChatGPT's plan sign-in (`chatgpt-new`) is one record,
//! `<home>/.graff/credentials/chatgpt-new.json`, that outlives a sign-out: graff
//! keeps the app registration and account so the next sign-in skips consent.
//! So it counts as signed in only while the record holds a token, and as ready
//! only when that token was granted plan usage ([`CHATGPT_PLAN_SCOPE`]).
//!
//! `graff login` exits 0 even when it refuses (`✗ …` and return), so nothing
//! here trusts the exit code: a sign-in counts only when the credential file
//! changed, or graff printed its `✓` line.

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use harness_proto::{GRAFF_LOGIN_PROVIDERS, GraffLoginProvider};

/// The scope a ChatGPT sign-in needs before requests can run on the plan.
pub const CHATGPT_PLAN_SCOPE: &str = "chatgpt.tokens.use.direct";

/// What graff's ChatGPT record says. Token values are never kept: only
/// whether one is there.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct ChatgptRecord {
    /// The account the registration belongs to.
    pub account: Option<String>,
    /// graff registered itself in that account (an issued client id), so a
    /// sign-in from here is a returning one that skips consent.
    pub registered: bool,
    /// A token is stored: signed in, as opposed to signed out (tokens cleared).
    pub signed_in: bool,
    /// The token was granted plan usage.
    pub plan_usage: bool,
}

/// Read graff's ChatGPT record under `home`; `None` when there is none or it
/// can't be read.
pub fn chatgpt_record(home: &Path) -> Option<ChatgptRecord> {
    let path = credential_path(home, "chatgpt-new")?;
    parse_chatgpt_record(&std::fs::read(path).ok()?)
}

fn parse_chatgpt_record(bytes: &[u8]) -> Option<ChatgptRecord> {
    #[derive(serde::Deserialize)]
    struct Raw {
        #[serde(default)]
        email: String,
        #[serde(default)]
        client_id: String,
        #[serde(default, rename = "access_token", deserialize_with = "present")]
        signed_in: bool,
        #[serde(default)]
        scopes: Vec<String>,
    }
    fn present<'de, D: serde::Deserializer<'de>>(de: D) -> Result<bool, D::Error> {
        let token: Option<String> = serde::Deserialize::deserialize(de)?;
        Ok(token.is_some_and(|token| !token.is_empty()))
    }
    let raw: Raw = serde_json::from_slice(bytes).ok()?;
    Some(ChatgptRecord {
        account: (!raw.email.is_empty()).then_some(raw.email),
        registered: !raw.client_id.is_empty(),
        signed_in: raw.signed_in,
        plan_usage: raw.signed_in && raw.scopes.iter().any(|s| s == CHATGPT_PLAN_SCOPE),
    })
}

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

/// Every provider with whether it is signed in, in the order of
/// [`GRAFF_LOGIN_PROVIDERS`]: a credential file for most, a plan-granted
/// token in the record for ChatGPT.
pub fn list(home: &Path) -> Vec<GraffLoginProvider> {
    GRAFF_LOGIN_PROVIDERS
        .iter()
        .map(|(id, name)| {
            if *id == "chatgpt-new" {
                // Ready only with plan usage; a sign-in without it still
                // names its account so the screen can say plan usage is off.
                let record = chatgpt_record(home).filter(|record| record.signed_in);
                return GraffLoginProvider {
                    id: (*id).to_string(),
                    name: (*name).to_string(),
                    signed_in: record.as_ref().is_some_and(|record| record.plan_usage),
                    account: record.as_ref().and_then(|record| record.account.clone()),
                    plan_usage: record.map(|record| record.plan_usage),
                };
            }
            GraffLoginProvider {
                id: (*id).to_string(),
                name: (*name).to_string(),
                signed_in: credential_path(home, id).is_some_and(|path| path.is_file()),
                account: None,
                plan_usage: None,
            }
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

/// Remove the credential file. Already signed out is success. ChatGPT's
/// record is not removed here: `graff logout chatgpt-new` revokes its session
/// and keeps the registration (see `AgentAccounts::sign_out_graff_login`).
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

/// graff signed in to ChatGPT but plan usage was not allowed: its
/// `✓ signed in to ChatGPT as …, but plan usage was not allowed.` line.
pub fn chatgpt_plan_denied(output: &str) -> bool {
    output.lines().any(|line| {
        let line = strip_ansi(line);
        let line = line.trim();
        line.starts_with("✓ signed in to ChatGPT as ")
            && line.contains("but plan usage was not allowed")
    })
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
    fn chatgpt_plan_denial_is_recognised() {
        assert!(chatgpt_plan_denied(
            "✓ signed in to ChatGPT as a@b.c, but plan usage was not allowed. Run `graff login chatgpt` again and allow it, or use an API key.\n"
        ));
        assert!(!chatgpt_plan_denied(
            "✓ signed in to ChatGPT as a@b.c; plan usage is on.\n"
        ));
        assert!(!chatgpt_plan_denied("✗ ChatGPT sign-in failed: rejected\n"));
    }

    #[test]
    fn chatgpt_record_reports_account_registration_and_plan_without_tokens() {
        // graff's own shape (oauth_chatgpt.zig serializeRecord).
        let granted = br#"{"email":"a@b.c","issuer":"https://auth.openai.com","subject":"s","client_id":"oaiapp_1","ext_agent_host_id":"urn:uuid:x","id_token":"i","access_token":"t","refresh_token":"r","token_type":"Bearer","expires_at":1,"earliest_refresh_at":0,"scopes":["chatgpt.tokens.use.direct","email","openid"],"saved_at":"now"}"#;
        assert_eq!(
            parse_chatgpt_record(granted),
            Some(ChatgptRecord {
                account: Some("a@b.c".into()),
                registered: true,
                signed_in: true,
                plan_usage: true,
            })
        );
        let denied = br#"{"email":"a@b.c","client_id":"oaiapp_1","access_token":"t","scopes":["email","openid"]}"#;
        let denied = parse_chatgpt_record(denied).unwrap();
        assert!(denied.signed_in && !denied.plan_usage);
        // `graff logout chatgpt` clears the tokens and scopes, keeps the rest.
        let signed_out = br#"{"email":"a@b.c","client_id":"oaiapp_1","access_token":"","refresh_token":"","scopes":[]}"#;
        let signed_out = parse_chatgpt_record(signed_out).unwrap();
        assert!(signed_out.registered && !signed_out.signed_in && !signed_out.plan_usage);
        // A token with the plan scope but no access token isn't plan usage.
        let empty = br#"{"access_token":"","scopes":["chatgpt.tokens.use.direct"]}"#;
        assert!(!parse_chatgpt_record(empty).unwrap().plan_usage);
        assert_eq!(parse_chatgpt_record(b"not json"), None);
    }

    #[test]
    fn chatgpt_counts_as_signed_in_only_with_plan_usage() {
        let dir = tempfile::tempdir().unwrap();
        let path = credential_path(dir.path(), "chatgpt-new").unwrap();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let row = |home: &Path| list(home).pop().unwrap();
        assert_eq!(
            (row(dir.path()).signed_in, row(dir.path()).plan_usage),
            (false, None)
        );

        std::fs::write(
            &path,
            r#"{"email":"a@b.c","access_token":"t","scopes":["email"]}"#,
        )
        .unwrap();
        let off = row(dir.path());
        assert_eq!(
            (off.signed_in, off.plan_usage, off.account.as_deref()),
            (false, Some(false), Some("a@b.c"))
        );

        std::fs::write(
            &path,
            r#"{"email":"a@b.c","access_token":"t","scopes":["chatgpt.tokens.use.direct"]}"#,
        )
        .unwrap();
        let on = row(dir.path());
        assert_eq!(
            (on.signed_in, on.plan_usage, on.account.as_deref()),
            (true, Some(true), Some("a@b.c"))
        );

        std::fs::write(
            &path,
            r#"{"email":"a@b.c","client_id":"oaiapp_1","access_token":""}"#,
        )
        .unwrap();
        let out = row(dir.path());
        assert_eq!(
            (out.signed_in, out.plan_usage, out.account),
            (false, None, None)
        );
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
