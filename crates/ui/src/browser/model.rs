//! Browser state shared by the chrome and platform host. No native handles.
use std::net::IpAddr;

#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Deserialize)]
pub struct PageState {
    pub url: Option<String>,
    pub title: String,
    pub loading: bool,
    pub can_back: bool,
    pub can_forward: bool,
    pub error: Option<String>,
}

impl PageState {
    pub fn label(&self) -> String {
        if !self.title.trim().is_empty() {
            self.title.clone()
        } else {
            self.url
                .as_deref()
                .and_then(|s| url::Url::parse(s).ok())
                .and_then(|u| u.host_str().map(str::to_owned))
                .unwrap_or_else(|| "Browser".into())
        }
    }
}

pub fn loopback(url: &url::Url) -> bool {
    match url.host() {
        Some(url::Host::Domain(host)) => host == "localhost" || host.ends_with(".localhost"),
        Some(url::Host::Ipv4(ip)) => IpAddr::V4(ip).is_loopback(),
        Some(url::Host::Ipv6(ip)) => IpAddr::V6(ip).is_loopback(),
        None => false,
    }
}

pub fn normalize_address(input: &str) -> Result<String, &'static str> {
    let text = input.trim();
    if text.is_empty() {
        return Err("Enter a website or localhost address.");
    }
    if text.chars().any(|c| c.is_control()) {
        return Err("This address contains invalid characters.");
    }
    // A bare host:port looks like a URI scheme to a URL parser. Only accept
    // that ambiguity when the suffix is an actual numeric port.
    let authority = text.split(['/', '?', '#']).next().unwrap_or(text);
    let host_port = authority
        .rsplit_once(':')
        .is_some_and(|(_, port)| !port.is_empty() && port.chars().all(|c| c.is_ascii_digit()));
    let explicit =
        text.contains("://") || (text.contains(':') && !host_port && !text.starts_with('['));
    let mut parsed = url::Url::parse(&if explicit {
        text.to_owned()
    } else {
        format!("https://{text}")
    })
    .map_err(|_| "Enter a valid website or localhost address.")?;
    if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none() {
        return Err("Only http and https addresses are supported.");
    }
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err("Use an address without an embedded username or password.");
    }
    if !explicit && loopback(&parsed) {
        let _ = parsed.set_scheme("http");
    }
    Ok(parsed.into())
}

/// Resolve text the user submitted in the address field. Links and native
/// navigation keep using the URL-only paths below; only this entry point may
/// turn ordinary words into a search.
pub fn address_or_search(input: &str) -> Result<String, &'static str> {
    match classify_search_text(input)? {
        Some(query) => Ok(search_url(query)),
        None => normalize_address(input),
    }
}

/// Search-only input, using the same classification as address submission.
/// Addresses (including malformed or credential-bearing ones) never reach a
/// remote suggestion provider. Empty/invalid input has no query either.
pub fn search_query(input: &str) -> Option<String> {
    classify_search_text(input)
        .ok()
        .flatten()
        .map(str::to_owned)
}

/// A selected search suggestion stays a search even if it resembles a domain.
pub fn search_url(query: &str) -> String {
    let mut search = url::Url::parse("https://www.google.com/search")
        .expect("the search endpoint is a valid URL");
    search.query_pairs_mut().append_pair("q", query);
    search.into()
}

fn classify_search_text(input: &str) -> Result<Option<&str>, &'static str> {
    let text = input.trim();
    if text.is_empty() {
        return Err("Enter a search or website address.");
    }
    if text.chars().any(char::is_control) {
        return Err("This address contains invalid characters.");
    }

    let authority = text.split(['/', '?', '#']).next().unwrap_or(text);
    let host_port = authority
        .rsplit_once(':')
        .is_some_and(|(_, port)| !port.is_empty() && port.chars().all(|c| c.is_ascii_digit()));
    let scheme = text.split_once(':').map(|(prefix, _)| prefix);
    let explicit_scheme = !host_port
        && !text.starts_with('[')
        && scheme.is_some_and(|prefix| {
            prefix
                .as_bytes()
                .first()
                .is_some_and(u8::is_ascii_alphabetic)
                && prefix
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'+' | b'-' | b'.'))
        });
    let looks_like_host = !authority.chars().any(char::is_whitespace)
        && (authority.eq_ignore_ascii_case("localhost")
            || authority.contains('.')
            || authority.starts_with('[')
            || authority.contains('@')
            || host_port
            || authority.parse::<IpAddr>().is_ok());

    // Never turn a malformed explicit URL, unsupported scheme, or credential
    // bearing address into a query sent to the search provider.
    if text.contains("://") || explicit_scheme || looks_like_host {
        return Ok(None);
    }
    Ok(Some(text))
}

/// Chat links require an explicit web authority; never infer a scheme or
/// silently strip controls, credentials, malformed escapes or backslashes.
pub fn transcript_address(input: &str) -> Result<String, &'static str> {
    let lower = input.to_ascii_lowercase();
    let authority = lower
        .strip_prefix("https://")
        .or_else(|| lower.strip_prefix("http://"))
        .ok_or("Only explicit http and https links are supported.")?;
    if input.chars().any(|c| c.is_control() || c.is_whitespace())
        || input.contains('\\')
        || authority.is_empty()
        || authority.starts_with(['/', '?', '#'])
    {
        return Err("This link contains an invalid address.");
    }
    for (i, byte) in input.bytes().enumerate() {
        if byte == b'%'
            && !input
                .as_bytes()
                .get(i + 1..i + 3)
                .is_some_and(|hex| hex.iter().all(u8::is_ascii_hexdigit))
        {
            return Err("This link contains an invalid escape.");
        }
    }
    normalize_address(input)
}

pub fn allowed_navigation(address: &str) -> bool {
    url::Url::parse(address).is_ok_and(|u| {
        matches!(u.scheme(), "http" | "https")
            && u.host_str().is_some()
            && u.username().is_empty()
            && u.password().is_none()
    })
}

/// In-memory previews may load only the wrapper and its opaque srcdoc frame.
/// The inherited CSP separately denies subresources, network and workers.
pub fn allowed_document_navigation(address: &str) -> bool {
    matches!(address, "about:blank" | "about:srcdoc")
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Presentation {
    #[default]
    Hidden,
    Live,
    /// Keep rendering while GPUI owns drag input.
    Passthrough,
}

pub fn presentation(active: bool, dragging: bool) -> Presentation {
    if !active {
        Presentation::Hidden
    } else if dragging {
        Presentation::Passthrough
    } else {
        Presentation::Live
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn normalizes_web_addresses_and_loopback_ports() {
        for (input, expected) in [
            ("localhost:3000", "http://localhost:3000/"),
            ("127.0.0.1:5173/a?x=1", "http://127.0.0.1:5173/a?x=1"),
            ("[::1]:8080", "http://[::1]:8080/"),
            ("[::1]", "http://[::1]/"),
            (" app.localhost:3000 ", "http://app.localhost:3000/"),
            ("example.com/path", "https://example.com/path"),
            ("https://localhost:3000", "https://localhost:3000/"),
            ("http://example.com", "http://example.com/"),
        ] {
            assert_eq!(normalize_address(input), Ok(expected.into()), "{input}");
        }
    }
    #[test]
    fn rejects_non_web_schemes_credentials_and_bad_input() {
        for input in [
            "",
            "javascript:alert(1)",
            "file:///tmp/a",
            "data:text/html,hi",
            "harness://open/chat/a",
            "https://user:pass@example.com",
            "https://",
            "two words",
            "https://example.com/\nsecret",
        ] {
            assert!(normalize_address(input).is_err(), "{input}");
        }
        assert!(!allowed_navigation("javascript:alert(1)"));
        assert!(!allowed_navigation("https://user@example.com/"));
    }
    #[test]
    fn typed_addresses_keep_web_and_development_destinations() {
        for (input, expected) in [
            ("example.com/path", "https://example.com/path"),
            ("https://example.com/?q=rust", "https://example.com/?q=rust"),
            ("http://example.com", "http://example.com/"),
            ("localhost", "http://localhost/"),
            ("localhost:3000", "http://localhost:3000/"),
            ("app.localhost:5173/path", "http://app.localhost:5173/path"),
            ("127.0.0.1:8080", "http://127.0.0.1:8080/"),
            ("192.168.1.8:3000", "https://192.168.1.8:3000/"),
            ("[::1]:8080", "http://[::1]:8080/"),
            ("devbox:3000", "https://devbox:3000/"),
        ] {
            assert_eq!(address_or_search(input), Ok(expected.into()), "{input}");
        }
    }
    #[test]
    fn typed_words_and_phrases_become_one_encoded_search_query() {
        for input in [
            "rust",
            "rust async await",
            "C++ & Rust # examples?",
            "100% café 日本語",
            "what changed in example.com/docs",
        ] {
            let resolved = address_or_search(&format!("  {input}  ")).unwrap();
            let url = url::Url::parse(&resolved).unwrap();
            assert_eq!(url.scheme(), "https");
            assert_eq!(url.host_str(), Some("www.google.com"));
            assert_eq!(url.path(), "/search");
            assert_eq!(url.fragment(), None);
            assert_eq!(
                url.query_pairs().into_owned().collect::<Vec<_>>(),
                vec![("q".to_owned(), input.to_owned())]
            );
        }
    }
    #[test]
    fn typed_invalid_addresses_are_never_sent_to_search() {
        for input in [
            "",
            "https://",
            "https://bad host.example",
            "https://example.com:bad/path",
            "https://user:secret@example.com",
            "user@example.com",
            "javascript:alert(1)",
            "file:///tmp/private.txt",
            "data:text/html,private",
            "harness://open/chat/a",
            "custom:private",
            "two\nwords",
        ] {
            assert!(address_or_search(input).is_err(), "{input}");
        }
        assert!(normalize_address("two words").is_err());
        assert!(transcript_address("rust").is_err());
        assert!(!allowed_navigation("rust"));
    }
    #[test]
    fn autocomplete_classifies_queries_without_sending_addresses() {
        for input in [
            "rust",
            "rust async await",
            "C++ & Rust # examples?",
            "100% café 日本語",
            "what changed in example.com/docs",
        ] {
            let query = search_query(&format!("  {input}  ")).unwrap();
            assert_eq!(query, input);
            assert_eq!(address_or_search(input).unwrap(), search_url(&query));
        }
        for input in [
            "",
            "example.com",
            "localhost",
            "localhost:3000/path",
            "devbox:5173",
            "127.0.0.1:8080",
            "[::1]",
            "https://",
            "https://bad host.example",
            "https://example.com:bad/path",
            "https://user:secret@example.com",
            "user@example.com",
            "javascript:alert(1)",
            "file:///tmp/private.txt",
            "data:text/html,private",
            "harness://open/chat/a",
            "custom:private",
            "two\nwords",
        ] {
            assert_eq!(search_query(input), None, "{input}");
        }
    }
    #[test]
    fn selected_domain_suggestion_still_searches() {
        assert_eq!(
            search_url("example.com"),
            "https://www.google.com/search?q=example.com"
        );
    }
    #[test]
    fn native_visibility_never_outlives_its_surface() {
        assert_eq!(presentation(false, false), Presentation::Hidden);
        assert_eq!(presentation(false, true), Presentation::Hidden);
        assert_eq!(presentation(true, true), Presentation::Passthrough);
        assert_eq!(presentation(true, false), Presentation::Live);
    }
    #[test]
    fn tab_labels_fall_back_to_host_then_browser() {
        let mut page = PageState::default();
        assert_eq!(page.label(), "Browser");
        page.url = Some("http://localhost:3000/path".into());
        assert_eq!(page.label(), "localhost");
        page.title = "Local preview".into();
        assert_eq!(page.label(), "Local preview");
    }
}
