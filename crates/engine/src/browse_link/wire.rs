//! browse's Connected apps protocol `v1-p256-sig` (justrach/browse
//! `docs/connected-apps.md`): encodings, the pairing code, request signing and
//! answer verification. Pure, so the whole wire format is tested here.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use p256::ecdsa::signature::{Signer as _, Verifier as _};
use p256::ecdsa::{DerSignature, Signature, SigningKey, VerifyingKey};
use rand_core::{OsRng, RngCore as _};
use sha2::{Digest as _, Sha256};

pub const PROTOCOL: &str = "v1-p256-sig";

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(text: &str) -> Option<Vec<u8>> {
    if text.len() % 2 != 0 {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok())
        .collect()
}

/// 16 random bytes as 32 lowercase hex characters.
pub fn nonce() -> String {
    let mut bytes = [0u8; 16];
    OsRng.fill_bytes(&mut bytes);
    hex(&bytes)
}

pub fn new_key() -> SigningKey {
    SigningKey::random(&mut OsRng)
}

/// Base64 (standard, padded) of the X9.63 uncompressed point, 65 bytes.
pub fn public_key_b64(key: &SigningKey) -> String {
    B64.encode(key.verifying_key().to_encoded_point(false).as_bytes())
}

pub fn parse_public_key(b64: &str) -> Option<VerifyingKey> {
    let raw = B64.decode(b64).ok()?;
    (raw.len() == 65).then_some(())?;
    VerifyingKey::from_sec1_bytes(&raw).ok()
}

/// The six digits both apps show: the first 4 bytes of
/// SHA-256(browse_key ‖ client_key ‖ nonce), raw bytes, as a big-endian u32,
/// mod 1,000,000.
pub fn pairing_code(browse_key_b64: &str, client_key_b64: &str, nonce_hex: &str) -> Option<String> {
    let browse = B64.decode(browse_key_b64).ok()?;
    let client = B64.decode(client_key_b64).ok()?;
    let nonce = unhex(nonce_hex)?;
    let digest = Sha256::new()
        .chain_update(&browse)
        .chain_update(&client)
        .chain_update(&nonce)
        .finalize();
    let n = u32::from_be_bytes([digest[0], digest[1], digest[2], digest[3]]) % 1_000_000;
    Some(format!("{n:06}"))
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

/// `METHOD|path|sha256hex(body)|timestamp|nonce|client_id`.
pub fn canonical(
    method: &str,
    path: &str,
    body: &[u8],
    timestamp_ms: i64,
    nonce: &str,
    client_id: &str,
) -> String {
    format!(
        "{method}|{path}|{}|{timestamp_ms}|{nonce}|{client_id}",
        sha256_hex(body)
    )
}

/// Base64 of the ASN.1 DER ECDSA-SHA256 signature over `text`.
pub fn sign(key: &SigningKey, text: &str) -> String {
    let signature: Signature = key.sign(text.as_bytes());
    B64.encode(signature.to_der().as_bytes())
}

/// The headers of one signed request.
#[derive(Debug, Clone, PartialEq)]
pub struct SignedHeaders {
    pub client_id: String,
    pub timestamp_ms: i64,
    pub nonce: String,
    pub signature: String,
}

pub fn sign_request(
    key: &SigningKey,
    client_id: &str,
    path: &str,
    body: &[u8],
    timestamp_ms: i64,
) -> SignedHeaders {
    let nonce = nonce();
    let text = canonical("POST", path, body, timestamp_ms, &nonce, client_id);
    SignedHeaders {
        client_id: client_id.to_owned(),
        timestamp_ms,
        nonce,
        signature: sign(key, &text),
    }
}

/// browse signs every answer to a signed request over
/// `sha256hex(answer body)|request nonce`.
pub fn answer_is_signed(
    browse_key: &VerifyingKey,
    body: &[u8],
    request_nonce: &str,
    signature_b64: Option<&str>,
) -> bool {
    let Some(der) = signature_b64.and_then(|s| B64.decode(s.trim()).ok()) else {
        return false;
    };
    let Ok(signature) = DerSignature::try_from(der.as_slice()) else {
        return false;
    };
    let text = format!("{}|{request_nonce}", sha256_hex(body));
    browse_key.verify(text.as_bytes(), &signature).is_ok()
}

/// A per-run session id browse accepts: up to 64 of `[A-Za-z0-9._:-]`.
pub fn session_id(run_id: &str) -> String {
    let cleaned: String = run_id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | ':' | '-'))
        .take(58)
        .collect();
    format!("run:{cleaned}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_round_trip_as_65_byte_x963_points() {
        let key = new_key();
        let b64 = public_key_b64(&key);
        assert_eq!(B64.decode(&b64).unwrap().len(), 65);
        assert_eq!(B64.decode(&b64).unwrap()[0], 0x04);
        assert_eq!(parse_public_key(&b64).unwrap(), *key.verifying_key());
        assert!(parse_public_key("AAAA").is_none());
    }

    #[test]
    fn the_pairing_code_follows_the_spec() {
        let browse = B64.encode([0x04; 65]);
        let client = B64.encode([0x05; 65]);
        let nonce = "00112233445566778899aabbccddeeff";
        let mut data = vec![0x04; 65];
        data.extend([0x05; 65]);
        data.extend(unhex(nonce).unwrap());
        let d = Sha256::digest(&data);
        let expected = u32::from_be_bytes([d[0], d[1], d[2], d[3]]) % 1_000_000;
        let code = pairing_code(&browse, &client, nonce).unwrap();
        assert_eq!(code.len(), 6);
        assert_eq!(code, format!("{expected:06}"));
        assert!(pairing_code(&browse, &client, "zz").is_none());
    }

    #[test]
    fn requests_sign_the_canonical_string_and_answers_verify() {
        let client = new_key();
        let body = br#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#;
        let headers = sign_request(&client, "c1", "/mcp", body, 1_790_000_000_000);
        assert_eq!(headers.nonce.len(), 32);
        let text = canonical(
            "POST",
            "/mcp",
            body,
            headers.timestamp_ms,
            &headers.nonce,
            "c1",
        );
        assert!(text.starts_with("POST|/mcp|"));
        assert!(text.ends_with(&format!("|1790000000000|{}|c1", headers.nonce)));
        // What browse checks: the DER signature over the canonical string.
        let der = B64.decode(&headers.signature).unwrap();
        let signature = DerSignature::try_from(der.as_slice()).unwrap();
        assert!(
            client
                .verifying_key()
                .verify(text.as_bytes(), &signature)
                .is_ok()
        );

        // browse's answer signature, and what a forged or tampered one does.
        let browse = new_key();
        let answer = br#"{"jsonrpc":"2.0","id":1,"result":{}}"#;
        let answered = format!("{}|{}", sha256_hex(answer), headers.nonce);
        let good = sign(&browse, &answered);
        let pinned = *browse.verifying_key();
        assert!(answer_is_signed(
            &pinned,
            answer,
            &headers.nonce,
            Some(&good)
        ));
        assert!(
            !answer_is_signed(&pinned, b"{}", &headers.nonce, Some(&good)),
            "tampered body"
        );
        assert!(
            !answer_is_signed(&pinned, answer, &nonce(), Some(&good)),
            "another request"
        );
        let squatter = sign(&new_key(), &answered);
        assert!(
            !answer_is_signed(&pinned, answer, &headers.nonce, Some(&squatter)),
            "not the paired browse"
        );
        assert!(!answer_is_signed(&pinned, answer, &headers.nonce, None));
    }

    #[test]
    fn session_ids_fit_browse_s_charset_and_length() {
        let id = session_id("0190a1b2-c3d4/../ weird*chars");
        assert!(id.len() <= 64);
        assert!(
            id.chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | ':' | '-'))
        );
        assert_eq!(session_id(&"a".repeat(200)).len(), 62);
    }
}
