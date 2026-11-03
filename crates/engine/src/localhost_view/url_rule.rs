//! Which pages a viewer may open: http(s) on this computer's loopback only.
//!
//! The headless browser runs on this computer, so a loopback URL means this
//! computer's own servers. Anything else would turn the phone's viewer into a
//! browser on this computer's network, which it isn't meant to be.

use reqwest::Url;

/// Longest URL a viewer may send.
const MAX_URL_LEN: usize = 4096;

/// The URL a viewer asked for, if it is an http(s) page on loopback, as the
/// browser should open it. `0.0.0.0` (what dev servers print when they bind
/// every interface) becomes `localhost`; a bare `localhost:3000` gets `http://`.
pub fn loopback_url(raw: &str) -> Result<Url, String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err("Enter a localhost address, like localhost:3000.".into());
    }
    if raw.len() > MAX_URL_LEN {
        return Err("That address is too long.".into());
    }
    let with_scheme = if raw.contains("://") {
        raw.to_string()
    } else {
        format!("http://{raw}")
    };
    let mut url = Url::parse(&with_scheme).map_err(|_| refused(raw))?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err(refused(raw));
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err("Addresses with a user name or password can't be opened here.".into());
    }
    let Some(host) = url.host_str().map(str::to_ascii_lowercase) else {
        return Err(refused(raw));
    };
    if host == "0.0.0.0" || host == "[::]" {
        url.set_host(Some("localhost")).map_err(|_| refused(raw))?;
        return Ok(url);
    }
    if !is_loopback_host(&host) {
        return Err(refused(raw));
    }
    Ok(url)
}

/// `localhost`, `*.localhost`, 127.0.0.0/8 and `[::1]`.
pub fn is_loopback_host(host: &str) -> bool {
    let host = host.to_ascii_lowercase();
    let host = host.trim_end_matches('.');
    if host == "localhost" || host.ends_with(".localhost") {
        return true;
    }
    let bare = host.trim_start_matches('[').trim_end_matches(']');
    match bare.parse::<std::net::IpAddr>() {
        Ok(std::net::IpAddr::V4(v4)) => v4.is_loopback(),
        Ok(std::net::IpAddr::V6(v6)) => {
            v6.is_loopback() || v6.to_ipv4_mapped().is_some_and(|v4| v4.is_loopback())
        }
        Err(_) => false,
    }
}

/// Whether a page the browser is about to load as a whole tab stays on
/// loopback. Chrome's own pages (`about:blank`, its error pages) and inline
/// documents pass; they never leave this computer.
pub fn allowed_navigation(url: &str) -> bool {
    let Ok(parsed) = Url::parse(url) else {
        return false;
    };
    match parsed.scheme() {
        "http" | "https" => parsed.host_str().is_some_and(is_loopback_host),
        "about" | "data" | "blob" | "chrome-error" => true,
        _ => false,
    }
}

fn refused(raw: &str) -> String {
    format!("Only pages on this computer open here (localhost or 127.0.0.1), not {raw}.")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loopback_http_pages_are_accepted_and_normalized() {
        for (raw, expected) in [
            ("http://localhost:3000", "http://localhost:3000/"),
            (
                "localhost:5173/app?x=1#top",
                "http://localhost:5173/app?x=1#top",
            ),
            ("https://localhost:8443/", "https://localhost:8443/"),
            ("http://LOCALHOST:3000", "http://localhost:3000/"),
            (
                "http://garden.localhost:3000/",
                "http://garden.localhost:3000/",
            ),
            ("http://127.0.0.1:8080/x", "http://127.0.0.1:8080/x"),
            ("http://127.1.2.3:8080/", "http://127.1.2.3:8080/"),
            ("http://[::1]:4000/", "http://[::1]:4000/"),
            ("http://0.0.0.0:3000/docs", "http://localhost:3000/docs"),
            ("  http://localhost  ", "http://localhost/"),
        ] {
            assert_eq!(
                loopback_url(raw).map(|u| u.to_string()),
                Ok(expected.to_string()),
                "{raw}"
            );
        }
    }

    #[test]
    fn everything_off_loopback_is_refused() {
        for raw in [
            "",
            "https://example.com",
            "http://192.168.1.20:3000",
            "http://10.0.0.1",
            "http://localhost.example.com:3000",
            "http://127.0.0.1.example.com/",
            "http://[::ffff:8.8.8.8]/",
            "http://[fe80::1]/",
            "file:///etc/hosts",
            "javascript:alert(1)",
            "chrome://settings",
            "ftp://localhost/",
            "ws://localhost:3000",
            "http://user:secret@localhost:3000/",
            "http://evil.com@localhost:3000/",
            "http://localhost:99999/",
        ] {
            assert!(loopback_url(raw).is_err(), "{raw:?} should be refused");
        }
        let long = format!("http://localhost/{}", "a".repeat(MAX_URL_LEN));
        assert!(loopback_url(&long).is_err());
    }

    /// The phone runs the same cases (`ParityTests.swift`).
    #[test]
    fn the_shared_vector_opens_the_same_addresses_as_the_phone() {
        let vector: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../apps/parity/vectors/localhost-pages.json"
        ))
        .unwrap();
        let cases = vector["cases"].as_array().unwrap();
        assert!(cases.len() > 10);
        for case in cases {
            let input = case["input"].as_str().unwrap();
            assert_eq!(
                loopback_url(input).ok().map(|u| u.to_string()).as_deref(),
                case["opens"].as_str(),
                "{input:?}"
            );
        }
    }

    #[test]
    fn page_navigations_stay_on_loopback() {
        for ok in [
            "http://localhost:3000/next",
            "http://127.0.0.1/",
            "http://[::1]:5000/",
            "about:blank",
            "chrome-error://chromewebdata/",
            "data:text/html,hi",
        ] {
            assert!(allowed_navigation(ok), "{ok}");
        }
        for refused in [
            "https://accounts.example.com/login",
            "http://192.168.0.2:3000/",
            "file:///Users/someone/",
            "chrome://version",
            "not a url",
        ] {
            assert!(!allowed_navigation(refused), "{refused}");
        }
    }
}
