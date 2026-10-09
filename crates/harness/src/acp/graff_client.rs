//! What graff tells the Codegraff gateway about where it runs: the Harness
//! version that launched it and the name this computer has in Harness. graff
//! sends them as `X-Codegraff-App` / `X-Codegraff-Device`, so each request in
//! the usage dashboard shows the build and the machine. Without a name graff
//! falls back to the hostname; a user's own environment setting wins.

use std::sync::RwLock;

static DEVICE_NAME: RwLock<Option<String>> = RwLock::new(None);

/// The name this computer shows in Harness (boot, and after a local rename).
pub fn set_device_name(name: &str) {
    let name = name.trim();
    if let Ok(mut slot) = DEVICE_NAME.write() {
        *slot = (!name.is_empty()).then(|| name.to_string());
    }
}

/// The variables to set on a graff launch, minus any the user already set.
pub(crate) fn env() -> Vec<(&'static str, String)> {
    let mut vars = vec![(
        "GRAFF_HOST_APP",
        concat!("harness/", env!("CARGO_PKG_VERSION")).to_string(),
    )];
    if let Some(name) = DEVICE_NAME.read().ok().and_then(|slot| slot.clone()) {
        vars.push(("GRAFF_DEVICE_NAME", name));
    }
    vars.retain(|(key, _)| std::env::var_os(key).is_none());
    vars
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn graff_gets_the_harness_version_and_device_name() {
        set_device_name("  Work laptop ");
        let vars = env();
        if std::env::var_os("GRAFF_HOST_APP").is_none() {
            let app = vars.iter().find(|(k, _)| *k == "GRAFF_HOST_APP").unwrap();
            assert_eq!(app.1, concat!("harness/", env!("CARGO_PKG_VERSION")));
        }
        if std::env::var_os("GRAFF_DEVICE_NAME").is_none() {
            let device = vars
                .iter()
                .find(|(k, _)| *k == "GRAFF_DEVICE_NAME")
                .unwrap();
            assert_eq!(device.1, "Work laptop");
        }
        set_device_name("");
        assert!(env().iter().all(|(k, _)| *k != "GRAFF_DEVICE_NAME"));
    }
}
