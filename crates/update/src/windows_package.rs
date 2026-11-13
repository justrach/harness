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

pub(super) fn extract(archive: &Path, directory: &Path) -> anyhow::Result<()> {
    let mut zip = zip::ZipArchive::new(std::fs::File::open(archive)?)?;
    for &(name, checksum) in FILES {
        let mut member = zip
            .by_name(name)
            .with_context(|| format!("portable update is missing {name}"))?;
        ensure!(
            !member.is_dir() && member.size() <= 256 * 1024 * 1024,
            "invalid portable executable size"
        );
        let mut bytes = Vec::new();
        (&mut member)
            .take(256 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)?;
        ensure!(
            bytes.len() as u64 == member.size(),
            "invalid portable executable length"
        );
        std::fs::File::create(directory.join(name))?.write_all(&bytes)?;
        std::fs::write(
            directory.join(checksum),
            format!("{:x}", Sha256::digest(&bytes)),
        )?;
    }
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
}
