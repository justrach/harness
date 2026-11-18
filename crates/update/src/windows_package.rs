//! Extract only the executable and loader members of a verified portable archive.
//! Never unpack archive-supplied paths or replace the local update-feed config.
use std::io::{Read, Write};
use std::path::Path;

use anyhow::{Context, ensure};
use sha2::{Digest, Sha256};

pub(super) const FILES: &[(&str, &str)] = &[
    ("harness-nano.exe", "nano-sha256"),
    ("WebView2Loader.dll", "webview2-sha256"),
    ("harness.exe", "sha256"),
];

pub(super) const OPTIONAL_FILES: &[(&str, &str)] = &[("harness-engine.exe", "engine-sha256")];

fn write_member(
    reader: &mut dyn Read,
    size: u64,
    is_dir: bool,
    directory: &Path,
    name: &str,
    checksum: &str,
) -> anyhow::Result<()> {
    ensure!(
        !is_dir && size <= 256 * 1024 * 1024,
        "invalid portable executable size"
    );
    let mut bytes = Vec::new();
    reader.take(256 * 1024 * 1024 + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 == size,
        "invalid portable executable length"
    );
    std::fs::File::create(directory.join(name))?.write_all(&bytes)?;
    std::fs::write(
        directory.join(checksum),
        format!("{:x}", Sha256::digest(&bytes)),
    )?;
    Ok(())
}

pub(super) fn extract(archive: &Path, directory: &Path) -> anyhow::Result<()> {
    let mut zip = zip::ZipArchive::new(std::fs::File::open(archive)?)?;
    for &(name, checksum) in FILES {
        let mut member = zip
            .by_name(name)
            .with_context(|| format!("portable update is missing {name}"))?;
        let size = member.size();
        let is_dir = member.is_dir();
        write_member(&mut member, size, is_dir, directory, name, checksum)?;
    }
    for &(name, checksum) in OPTIONAL_FILES {
        match zip.by_name(name) {
            Ok(mut member) => {
                let size = member.size();
                let is_dir = member.is_dir();
                write_member(&mut member, size, is_dir, directory, name, checksum)?;
            }
            Err(zip::result::ZipError::FileNotFound) => {}
            Err(err) => return Err(err.into()),
        }
    }
    Ok(())
}

/// Migrate a portable install's `harness-update.json` from the legacy Harness
/// release feed to `justrach/nanoharness`, preserving custom overrides.
pub(super) fn migrate_config_file(directory: &Path, config_name: &str) -> anyhow::Result<()> {
    let path = directory.join(config_name);
    let Ok(raw) = std::fs::read(&path) else {
        return Ok(());
    };
    let Ok(mut value) = serde_json::from_slice::<serde_json::Value>(&raw) else {
        return Ok(());
    };
    let Some(obj) = value.as_object_mut() else {
        return Ok(());
    };
    let Some(current) = obj.get("releases_url").and_then(|v| v.as_str()) else {
        return Ok(());
    };
    let migrated = super::migrate_release_base(current);
    if migrated == current {
        return Ok(());
    }
    obj.insert(
        "releases_url".into(),
        serde_json::Value::String(migrated.into()),
    );
    std::fs::write(&path, serde_json::to_vec(&value)?)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn archive(path: &Path, nano: bool) {
        let mut zip = zip::ZipWriter::new(std::fs::File::create(path).unwrap());
        let options = zip::write::SimpleFileOptions::default();
        zip.start_file("harness.exe", options).unwrap();
        zip.write_all(b"new engine").unwrap();
        if nano {
            zip.start_file("harness-nano.exe", options).unwrap();
            zip.write_all(b"new frontend").unwrap();
        }
        zip.start_file("WebView2Loader.dll", options).unwrap();
        zip.write_all(b"new loader").unwrap();
        zip.start_file("../escape", options).unwrap();
        zip.write_all(b"never extract").unwrap();
        zip.finish().unwrap();
    }

    #[test]
    fn portable_updates_extract_both_executables_and_ignore_untrusted_paths() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("release.zip");
        archive(&path, true);
        let stage = dir.path().join("stage");
        std::fs::create_dir(&stage).unwrap();
        extract(&path, &stage).unwrap();
        assert_eq!(
            std::fs::read(stage.join("harness.exe")).unwrap(),
            b"new engine"
        );
        assert_eq!(
            std::fs::read(stage.join("harness-nano.exe")).unwrap(),
            b"new frontend"
        );
        assert_eq!(
            std::fs::read_to_string(stage.join("nano-sha256")).unwrap(),
            format!("{:x}", Sha256::digest(b"new frontend"))
        );
        assert_eq!(
            std::fs::read(stage.join("WebView2Loader.dll")).unwrap(),
            b"new loader"
        );
        assert!(!dir.path().join("escape").exists());
        assert!(!stage.join("harness-update.json").exists());
    }

    #[test]
    fn portable_updates_reject_an_archive_without_the_frontend() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("release.zip");
        archive(&path, false);
        assert!(
            extract(&path, dir.path())
                .unwrap_err()
                .to_string()
                .contains("harness-nano.exe")
        );
    }

    #[test]
    fn portable_updates_extract_optional_engine_and_migrate_feed_config() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("release.zip");
        let mut zip = zip::ZipWriter::new(std::fs::File::create(&path).unwrap());
        let options = zip::write::SimpleFileOptions::default();
        for (name, bytes) in [
            ("harness.exe", b"new cli".as_slice()),
            ("harness-nano.exe", b"new gui".as_slice()),
            ("harness-engine.exe", b"new eng".as_slice()),
            ("WebView2Loader.dll", b"new dll".as_slice()),
        ] {
            zip.start_file(name, options).unwrap();
            zip.write_all(bytes).unwrap();
        }
        zip.finish().unwrap();

        let stage = dir.path().join("stage");
        std::fs::create_dir(&stage).unwrap();
        extract(&path, &stage).unwrap();
        assert_eq!(
            std::fs::read(stage.join("harness-engine.exe")).unwrap(),
            b"new eng"
        );
        assert_eq!(
            std::fs::read_to_string(stage.join("engine-sha256")).unwrap(),
            format!("{:x}", Sha256::digest(b"new eng"))
        );

        let cfg = dir.path().join("harness-update.json");
        std::fs::write(
            &cfg,
            r#"{"releases_url":"https://github.com/justrach/harness/releases/latest/download"}"#,
        )
        .unwrap();
        migrate_config_file(dir.path(), "harness-update.json").unwrap();
        let parsed: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&cfg).unwrap()).unwrap();
        assert_eq!(parsed["releases_url"], crate::STABLE_RELEASE_BASE);
    }
}
