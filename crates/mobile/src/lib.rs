//! harness-mobile — the Android app's native core.
//!
//! The phone is a viewer device: agents run on desktop hosts, and the phone mirrors the workspace registry and the
//! chat2 session docs and appends commands for a host to drain. The protocol lives in `harness-doc` and
//! `harness-sync`; this crate exposes the viewer side of it to Kotlin with UniFFI, so the Android app does not carry
//! its own copy of the registry merge rules or the chat2 client.
//!
//! The iOS app keeps its Swift sync code (`apps/ios/Harness/Sync`), which is the behavioral reference. Rules both
//! phones must agree on are pinned in `apps/parity`.

uniffi::setup_scaffolding!();

/// The version of the native core, which is the workspace version it was built from.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// A registry hybrid logical clock, `{ms:013}-{counter:06}-{device}` (crates/doc `encode_hlc`).
#[uniffi::export]
pub fn encode_hlc(ms: i64, counter: u32, device: String) -> String {
    harness_doc::encode_hlc(ms, counter, &device)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hlc_is_fixed_width_so_it_sorts_as_text() {
        assert_eq!(
            encode_hlc(5, 7, "phone".into()),
            "0000000000005-000007-phone"
        );
        assert!(encode_hlc(10, 0, "a".into()) > encode_hlc(9, 999_999, "z".into()));
    }
}
