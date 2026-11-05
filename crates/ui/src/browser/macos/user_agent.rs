//! Safari compatibility for ordinary web pages. Keep WebKit's platform and
//! engine tokens; its default embedded UA omits the browser/version suffix.
use objc2::ClassType;
use objc2_app_kit::NSWorkspace;
use objc2_foundation::{NSBundle, NSString};
use objc2_web_kit::{WKWebView, WKWebViewConfiguration};
use std::sync::OnceLock;

pub(super) fn configure(configuration: &WKWebViewConfiguration) {
    static SUFFIX: OnceLock<Option<String>> = OnceLock::new();
    if let Some(suffix) = SUFFIX.get_or_init(installed_safari_suffix) {
        unsafe {
            configuration.setApplicationNameForUserAgent(Some(&NSString::from_str(suffix)));
        }
    }
}

fn bundle_string(bundle: &NSBundle, key: &str) -> Option<String> {
    bundle
        .objectForInfoDictionaryKey(&NSString::from_str(key))?
        .downcast::<NSString>()
        .ok()
        .map(|value| value.to_string())
}

fn installed_safari_suffix() -> Option<String> {
    let webkit = unsafe { NSBundle::bundleForClass(WKWebView::class()) };
    let engine_build = bundle_string(&webkit, "CFBundleVersion");
    // Launch Services handles the OS's application location (including Cryptex
    // relocation). The canonical path also works when lookup is unavailable.
    let registered = NSWorkspace::sharedWorkspace()
        .URLForApplicationWithBundleIdentifier(&NSString::from_str("com.apple.Safari"))
        .and_then(|url| NSBundle::bundleWithURL(&url));
    let canonical = NSBundle::bundleWithPath(&NSString::from_str("/Applications/Safari.app"));
    for bundle in registered.into_iter().chain(canonical) {
        if bundle
            .bundleIdentifier()
            .as_deref()
            .map(NSString::to_string)
            .as_deref()
            != Some("com.apple.Safari")
        {
            continue;
        }
        if let Some(suffix) = safari_suffix(
            bundle_string(&bundle, "CFBundleShortVersionString").as_deref(),
            bundle_string(&bundle, "CFBundleVersion").as_deref(),
            engine_build.as_deref(),
        ) {
            return Some(suffix);
        }
    }
    // A missing/mismatched install must not advertise a fabricated capability
    // version. Normal browsing still works with the system's embedded identity.
    tracing::warn!("Safari version matching WebKit unavailable; using native browser user agent");
    None
}

fn safari_suffix(
    version: Option<&str>,
    safari_build: Option<&str>,
    engine_build: Option<&str>,
) -> Option<String> {
    let version = version?;
    let build = safari_build?;
    if build.is_empty() || Some(build) != engine_build {
        return None;
    }
    let parts: Vec<_> = version.split('.').collect();
    if !(2..=3).contains(&parts.len())
        || parts
            .iter()
            .any(|part| part.is_empty() || !part.bytes().all(|c| c.is_ascii_digit()))
        || !parts[0].parse::<u8>().is_ok_and(|major| major > 0)
    {
        return None;
    }
    // Like AppleWebKit/605.1.15 in the system UA, Safari's engine token is
    // deliberately frozen. CFBundleVersion is a build, not this UA token.
    Some(format!("Version/{version} Safari/605.1.15"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safari_user_agent_uses_matching_marketing_version() {
        for version in ["17.6", "18.6.1", "26.0", "27.2"] {
            assert_eq!(
                safari_suffix(
                    Some(version),
                    Some("22625.2.8.11.9"),
                    Some("22625.2.8.11.9")
                ),
                Some(format!("Version/{version} Safari/605.1.15"))
            );
        }
    }

    #[test]
    fn safari_user_agent_does_not_advertise_missing_or_mismatched_versions() {
        for version in [
            None,
            Some(""),
            Some("22625"),
            Some("0.1"),
            Some("27..2"),
            Some("27.2 beta"),
            Some("27.2\r\nOther: value"),
        ] {
            assert_eq!(safari_suffix(version, Some("build"), Some("build")), None);
        }
        for (safari, engine) in [
            (None, Some("build")),
            (Some("build"), None),
            (Some("old"), Some("new")),
            (Some(""), Some("")),
        ] {
            assert_eq!(safari_suffix(Some("27.2"), safari, engine), None);
        }
    }
}
