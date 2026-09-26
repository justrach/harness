//! Where Harness keeps its browse pairing key. On macOS it is a login
//! Keychain item, whose access list trusts the app that created it, so
//! another program running as the user can't read it without the user
//! agreeing in a Keychain prompt. Elsewhere (and in tests) it is a 0600 file
//! in the data directory; browse itself is macOS-only.

use std::path::{Path, PathBuf};

use p256::ecdsa::SigningKey;

const SERVICE: &str = "Harness browse pairing";

pub enum KeyStore {
    #[cfg(target_os = "macos")]
    Keychain { account: String },
    /// Non-macOS builds, and tests everywhere.
    #[cfg_attr(target_os = "macos", allow(dead_code))]
    File(PathBuf),
}

impl KeyStore {
    /// The platform store for `data_dir`. Each data directory (the release
    /// app, a dev build) gets its own key and pairing.
    pub fn for_data_dir(data_dir: &Path) -> Self {
        #[cfg(target_os = "macos")]
        {
            use sha2::Digest as _;
            let digest = sha2::Sha256::digest(data_dir.to_string_lossy().as_bytes());
            Self::Keychain {
                account: format!("client-key:{}", super::wire::hex(&digest[..8])),
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            Self::File(data_dir.join("browse-link.key"))
        }
    }

    pub fn load(&self) -> Option<SigningKey> {
        let bytes = match self {
            #[cfg(target_os = "macos")]
            Self::Keychain { account } => {
                security_framework::passwords::get_generic_password(SERVICE, account).ok()?
            }
            Self::File(path) => std::fs::read(path).ok()?,
        };
        SigningKey::from_slice(&bytes).ok()
    }

    pub fn load_or_create(&self) -> Result<SigningKey, String> {
        if let Some(key) = self.load() {
            return Ok(key);
        }
        let key = super::wire::new_key();
        let bytes = key.to_bytes();
        match self {
            #[cfg(target_os = "macos")]
            Self::Keychain { account } => {
                security_framework::passwords::set_generic_password(SERVICE, account, &bytes)
                    .map_err(|e| format!("couldn't save the pairing key in the Keychain: {e}"))?;
            }
            Self::File(path) => write_private(path, &bytes)
                .map_err(|e| format!("couldn't save the pairing key: {e}"))?,
        }
        Ok(key)
    }

    /// Forget the key (Disconnect). A new pairing makes a new one.
    pub fn delete(&self) {
        match self {
            #[cfg(target_os = "macos")]
            Self::Keychain { account } => {
                let _ = security_framework::passwords::delete_generic_password(SERVICE, account);
            }
            Self::File(path) => {
                let _ = std::fs::remove_file(path);
            }
        }
    }
}

pub(super) fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let staged = path.with_extension(format!("tmp-{}", uuid::Uuid::new_v4()));
    {
        use std::io::Write as _;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt as _;
            options.mode(0o600);
        }
        let mut file = options.open(&staged)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    std::fs::rename(&staged, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_store_keeps_one_private_key_until_deleted() {
        let dir = tempfile::tempdir().unwrap();
        let store = KeyStore::File(dir.path().join("k"));
        assert!(store.load().is_none());
        let key = store.load_or_create().unwrap();
        assert_eq!(store.load_or_create().unwrap(), key, "created once");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode = std::fs::metadata(dir.path().join("k"))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        store.delete();
        assert!(store.load().is_none());
        assert_ne!(store.load_or_create().unwrap(), key);
    }
}
