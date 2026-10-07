//! Only the public verification page and one-time user code may leave the host.
use harness_proto::{AgentLoginMode, AgentLoginStart};

pub(crate) fn start(login_id: &str, url: &str, code: &str) -> Option<AgentLoginStart> {
    let start = AgentLoginStart {
        login_id: login_id.into(),
        url: url.into(),
        mode: AgentLoginMode::DeviceCode,
        code: Some(code.into()),
    };
    start.is_safe_device_code().then_some(start)
}

pub(crate) fn strip_ansi(output: &str) -> String {
    let mut clean = String::new();
    let mut chars = output.chars();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            if chars.next() == Some('[') {
                for c in chars.by_ref() {
                    if ('@'..='~').contains(&c) {
                        break;
                    }
                }
            }
        } else {
            clean.push(c);
        }
    }
    clean
}

/// Codex's documented device-auth prompt, including its unconditional ANSI colours.
/// Never scan arbitrary output for an authorization URL or access token.
pub(crate) fn codex_prompt(login_id: &str, output: &str) -> Option<AgentLoginStart> {
    let clean = strip_ansi(output);
    let complete = &clean[..clean.rfind('\n')? + 1];
    let mut url_seen = false;
    let mut code_expected = false;
    for line in complete
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
    {
        if line == "https://auth.openai.com/codex/device" {
            url_seen = true;
        } else if url_seen && line.starts_with("2. Enter this one-time code") {
            code_expected = true;
        } else if code_expected {
            return start(login_id, "https://auth.openai.com/codex/device", line);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_code_prompt_requires_complete_safe_pair() {
        let prompt = "1. Open this link in your browser and sign in to your account\n  \x1b[94mhttps://auth.openai.com/codex/device\x1b[0m\n\n2. Enter this one-time code (expires in 15 minutes)\n  \x1b[94mABCD-EFGH\x1b[0m\n";
        let parsed = codex_prompt("fixture", prompt).unwrap();
        assert_eq!(parsed.code.as_deref(), Some("ABCD-EFGH"));
        assert!(parsed.is_safe_device_code());
        assert!(
            codex_prompt(
                "fixture",
                &prompt.replace("/codex/device", "/authorize?token=fixture")
            )
            .is_none()
        );
        assert!(
            codex_prompt(
                "fixture",
                &prompt.replace("ABCD-EFGH", "token_with_underscores")
            )
            .is_none()
        );
        assert!(codex_prompt("fixture", prompt.trim_end()).is_none());
        assert!(
            start(
                "fixture",
                "https://auth.openai.com/codex/device?token=fixture",
                "ABCD-EFGH"
            )
            .is_none()
        );
        assert!(start("", "https://auth.openai.com/codex/device", "ABCD-EFGH").is_none());
    }
}
