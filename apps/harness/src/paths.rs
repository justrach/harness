//! Application storage paths. Provider credentials keep their own locations.

use std::ffi::OsString;
use std::path::PathBuf;

/// Read the current Harness environment variable directly.
pub fn var(key: &str) -> Result<String, std::env::VarError> {
    std::env::var(key)
}

pub fn data_dir() -> PathBuf {
    resolve_data_dir(|name| std::env::var_os(name))
}

fn resolve_data_dir(mut env: impl FnMut(&str) -> Option<OsString>) -> PathBuf {
    if let Some(dir) = env("HARNESS_DATA_DIR").filter(|value| !value.is_empty()) {
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
        first_existing([local.join("Harness"), local.join("Harnesser")])
    }
    #[cfg(not(windows))]
    {
        // Keep the current data directory separate from other applications.
        let home = PathBuf::from(env("HOME").expect("HOME not set"));
        first_existing([home.join(".harness"), home.join(".harnesser")])
    }
}

fn first_existing(candidates: impl IntoIterator<Item = PathBuf>) -> PathBuf {
    let mut iter = candidates.into_iter();
    let first = iter.next().expect("data dir candidates");
    if first.exists() {
        return first;
    }
    for path in iter {
        if path.exists() {
            return path;
        }
    }
    first
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

    #[cfg(not(windows))]
    #[test]
    fn unix_default_is_dot_harness() {
        assert_eq!(
            resolve(&[("HOME", "/Users/ada")]),
            PathBuf::from("/Users/ada/.harness"),
        );
    }

    #[cfg(windows)]
    #[test]
    fn explorer_launch_without_home_uses_local_app_data() {
        assert_eq!(
            resolve(&[("LOCALAPPDATA", r"C:\Users\Test User\AppData\Local")]),
            PathBuf::from(r"C:\Users\Test User\AppData\Local\Harness"),
        );
    }

    #[cfg(windows)]
    #[test]
    fn windows_profile_fallback_handles_unicode_and_apostrophes() {
        assert_eq!(
            resolve(&[("USERPROFILE", r"C:\Users\O'Brien 日本語")]),
            PathBuf::from(r"C:\Users\O'Brien 日本語\AppData\Local\Harness"),
        );
    }

    #[cfg(windows)]
    #[test]
    fn windows_default_does_not_depend_on_shell_home() {
        assert_eq!(
            resolve(&[("HOME", r"D:\msys-home"), ("LOCALAPPDATA", r"C:\Local")]),
            PathBuf::from(r"C:\Local\Harness"),
        );
    }
}
