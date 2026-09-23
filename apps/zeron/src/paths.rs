//! Application storage paths. Provider credentials keep their own locations.

use std::ffi::OsString;
use std::path::PathBuf;

/// `HARNESS_*` wins; `ZERON_*` still works for existing installs and scripts.
pub fn var(zeron_key: &str) -> Result<String, std::env::VarError> {
    let harness_key = zeron_key.replacen("ZERON_", "HARNESS_", 1);
    match std::env::var(&harness_key) {
        Ok(value) if !value.is_empty() => Ok(value),
        _ => std::env::var(zeron_key),
    }
}

pub fn data_dir() -> PathBuf {
    resolve_data_dir(|name| std::env::var_os(name))
}

fn resolve_data_dir(mut env: impl FnMut(&str) -> Option<OsString>) -> PathBuf {
    if let Some(dir) = env("HARNESS_DATA_DIR").filter(|value| !value.is_empty()) {
        return PathBuf::from(dir);
    }
    if let Some(dir) = env("ZERON_DATA_DIR").filter(|value| !value.is_empty()) {
        return PathBuf::from(dir);
    }
    #[cfg(windows)]
    {
        // Explorer does not set HOME. Do not let a shell-specific HOME select
        // a different workspace from a desktop launch, or migrate credentials
        // between Unix-style and native Windows directories implicitly.
        let local = env("LOCALAPPDATA")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .or_else(|| {
                env("USERPROFILE")
                    .filter(|value| !value.is_empty())
                    .map(|home| PathBuf::from(home).join("AppData").join("Local"))
            })
            .expect("LOCALAPPDATA and USERPROFILE not set; set HARNESS_DATA_DIR");
        local.join("Harnesser")
    }
    #[cfg(not(windows))]
    {
        // Harnesser keeps its own data dir so it never shares state with an
        // installed zeron.
        PathBuf::from(env("HOME").expect("HOME not set")).join(".harnesser")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn resolve(vars: &[(&str, &str)]) -> PathBuf {
        resolve_data_dir(|name| {
            vars.iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| value.into())
        })
    }

    #[test]
    fn explicit_data_dir_needs_no_home() {
        assert_eq!(
            resolve(&[("HARNESS_DATA_DIR", "custom data")]),
            PathBuf::from("custom data")
        );
    }

    #[test]
    fn zeron_data_dir_still_works() {
        assert_eq!(
            resolve(&[("ZERON_DATA_DIR", "legacy data")]),
            PathBuf::from("legacy data")
        );
    }

    #[cfg(windows)]
    #[test]
    fn explorer_launch_without_home_uses_local_app_data() {
        assert_eq!(
            resolve(&[("LOCALAPPDATA", r"C:\Users\Test User\AppData\Local")]),
            PathBuf::from(r"C:\Users\Test User\AppData\Local\Harnesser"),
        );
    }

    #[cfg(windows)]
    #[test]
    fn windows_profile_fallback_handles_unicode_and_apostrophes() {
        assert_eq!(
            resolve(&[("USERPROFILE", r"C:\Users\O'Brien 日本語")]),
            PathBuf::from(r"C:\Users\O'Brien 日本語\AppData\Local\Harnesser"),
        );
    }

    #[cfg(windows)]
    #[test]
    fn windows_default_does_not_depend_on_shell_home() {
        assert_eq!(
            resolve(&[("HOME", r"D:\msys-home"), ("LOCALAPPDATA", r"C:\Local")]),
            PathBuf::from(r"C:\Local\Harnesser"),
        );
    }
}
