//! Optional remote completions for search text in the browser address field.
//! The caller owns debouncing/cancellation and must discard stale responses.

use std::{collections::HashSet, sync::OnceLock, time::Duration};

use super::model;

pub(super) const MAX_SUGGESTIONS: usize = 5;
const MAX_QUERY_CHARS: usize = 256;
const MAX_RESPONSE_BYTES: usize = 32 * 1024;

/// Fetch plain search completions, independently of the page's cookies/profile.
/// Failure is deliberately quiet: the typed Search action remains available.
pub(super) async fn fetch(input: &str) -> Vec<String> {
    let Some(query) = model::search_query(input) else {
        return Vec::new();
    };
    if !(2..=MAX_QUERY_CHARS).contains(&query.chars().count()) {
        return Vec::new();
    }
    fetch_query(&query).await.unwrap_or_default()
}

async fn fetch_query(query: &str) -> Option<Vec<String>> {
    // The OpenSearch JSON variant used by Firefox's Google engine. No partner
    // identifiers, page URL, cookies, or browsing history accompany the query.
    // https://github.com/mozilla-firefox/firefox/blob/main/services/settings/dumps/main/search-config-v2.json
    static CLIENT: OnceLock<Option<reqwest::Client>> = OnceLock::new();
    let client = CLIENT
        .get_or_init(|| {
            reqwest::Client::builder()
                .timeout(Duration::from_secs(3))
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .ok()
        })
        .as_ref()?;
    let mut response = client
        .get("https://www.google.com/complete/search")
        .query(&[("client", "firefox"), ("q", query)])
        .send()
        .await
        .ok()?
        .error_for_status()
        .ok()?;
    if response
        .content_length()
        .is_some_and(|length| length > MAX_RESPONSE_BYTES as u64)
    {
        return None;
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.ok()? {
        if bytes.len() + chunk.len() > MAX_RESPONSE_BYTES {
            return None;
        }
        bytes.extend_from_slice(&chunk);
    }
    Some(parse_suggestions(&bytes, query))
}

fn parse_suggestions(bytes: &[u8], query: &str) -> Vec<String> {
    if bytes.len() > MAX_RESPONSE_BYTES {
        return Vec::new();
    }
    let Ok(payload) = serde_json::from_slice::<serde_json::Value>(bytes) else {
        return Vec::new();
    };
    let Some(values) = payload
        .as_array()
        .filter(|values| values.first().and_then(serde_json::Value::as_str) == Some(query))
    else {
        return Vec::new();
    };
    let Some(suggestions) = values.get(1).and_then(serde_json::Value::as_array) else {
        return Vec::new();
    };
    let mut seen = HashSet::from([query.to_lowercase()]);
    suggestions
        .iter()
        .filter_map(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|suggestion| {
            !suggestion.is_empty()
                && suggestion.chars().count() <= MAX_QUERY_CHARS
                && !suggestion.chars().any(char::is_control)
                && seen.insert(suggestion.to_lowercase())
        })
        .take(MAX_SUGGESTIONS)
        .map(str::to_owned)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_strings_are_trimmed_deduplicated_and_bounded() {
        let payload = serde_json::json!([
            "rust",
            [
                "rust",
                " RUST ",
                " rust async ",
                "RUST ASYNC",
                "",
                12,
                "rust\nsecret",
                "rust tokio",
                "rust futures",
                "rust channels",
                "rust streams",
                "rust tasks"
            ]
        ]);
        assert_eq!(
            parse_suggestions(&serde_json::to_vec(&payload).unwrap(), "rust"),
            [
                "rust async",
                "rust tokio",
                "rust futures",
                "rust channels",
                "rust streams"
            ]
        );
    }

    #[test]
    fn malformed_stale_or_oversized_provider_payloads_fail_closed() {
        for payload in [
            b"not json".as_slice(),
            br#"{"suggestions":["rust async"]}"#,
            br#"["another query",["rust async"]]"#,
            br#"["rust",{"text":"rust async"}]"#,
            br#"["rust"]"#,
        ] {
            assert!(parse_suggestions(payload, "rust").is_empty());
        }
        assert!(parse_suggestions(&vec![b' '; MAX_RESPONSE_BYTES + 1], "rust").is_empty());
        let payload = serde_json::json!(["rust", ["x".repeat(MAX_QUERY_CHARS + 1), "rust async"]]);
        assert_eq!(
            parse_suggestions(&serde_json::to_vec(&payload).unwrap(), "rust"),
            ["rust async"]
        );
    }

    #[test]
    fn suggestions_are_plain_text_and_unicode_is_preserved() {
        let payload = serde_json::json!(["café", ["café 日本語", "<b>café</b>"]]);
        assert_eq!(
            parse_suggestions(&serde_json::to_vec(&payload).unwrap(), "café"),
            ["café 日本語", "<b>café</b>"]
        );
    }
}
