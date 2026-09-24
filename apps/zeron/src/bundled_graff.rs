//! Install the Graff binary carried by a packaged Harness app for its ACP
//! sessions and for terminal launches. Source builds leave the user's CLI alone.

use std::io::{Read as _, Write as _};
use std::path::{Path, PathBuf};

pub fn prepare() {
    if let Err(error) = prepare_inner() {
        tracing::warn!(%error, "could not install bundled graff");
    }
}

fn prepare_inner() -> std::io::Result<()> {
    let exe = std::env::current_exe()?.canonicalize()?;
    let Some(contents) = exe.parent().and_then(Path::parent) else {
        return Ok(());
    };
    if contents.file_name().is_none_or(|name| name != "Contents") {
        return Ok(());
    }
    let bundled = contents.join("Resources/bin/graff");
    if !bundled.is_file() {
        return Ok(());
    }
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return Ok(());
    };
    let managed = home.join(".harness/bin/graff");
    let should_copy = match (version(&bundled), version(&managed)) {
        (_, None) => true,
        (Some(bundled_version), Some(managed_version)) if managed_version > bundled_version => {
            false
        }
        _ => !same_contents(&bundled, &managed)?,
    };
    if should_copy {
        install_atomic(&bundled, &managed)?;
    }

    let local_bin = home.join(".local/bin");
    std::fs::create_dir_all(&local_bin)?;
    link_if_ours(&local_bin.join("graff"), &managed)?;
    let app_exe = contents.join("MacOS/harness");
    link_if_ours(&local_bin.join("harness"), &app_exe)?;
    for profile in [".zprofile", ".zshrc", ".bash_profile", ".bashrc"] {
        ensure_local_bin_on_path(&home.join(profile))?;
    }
    // The ACP adapter resolves this before PATH. An explicit user override wins.
    if std::env::var_os("GRAFF_EXECUTABLE").is_none() {
        // This runs before the headed UI creates any threads.
        unsafe { std::env::set_var("GRAFF_EXECUTABLE", &managed) };
    }
    Ok(())
}

fn version(path: &Path) -> Option<Vec<u64>> {
    let output = std::process::Command::new(path)
        .arg("--version")
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .find_map(|word| {
            let parts: Option<Vec<u64>> = word
                .trim_start_matches('v')
                .split('.')
                .map(str::parse)
                .collect::<Result<_, _>>()
                .ok();
            parts.filter(|parts| parts.len() >= 3)
        })
}

fn same_contents(a: &Path, b: &Path) -> std::io::Result<bool> {
    let mut left = std::fs::File::open(a)?;
    let Ok(mut right) = std::fs::File::open(b) else {
        return Ok(false);
    };
    if left.metadata()?.len() != right.metadata()?.len() {
        return Ok(false);
    }
    let mut left_buf = [0_u8; 64 * 1024];
    let mut right_buf = [0_u8; 64 * 1024];
    loop {
        let read = left.read(&mut left_buf)?;
        if read == 0 {
            return Ok(true);
        }
        right.read_exact(&mut right_buf[..read])?;
        if left_buf[..read] != right_buf[..read] {
            return Ok(false);
        }
    }
}

fn install_atomic(source: &Path, target: &Path) -> std::io::Result<()> {
    let parent = target.parent().expect("graff target has parent");
    std::fs::create_dir_all(parent)?;
    let staged = parent.join(format!(".graff-{}.tmp", std::process::id()));
    std::fs::copy(source, &staged)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o755))?;
    }
    std::fs::rename(staged, target)
}

fn link_if_ours(link: &Path, target: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        match std::fs::read_link(link) {
            Ok(current) if current == target => return Ok(()),
            Ok(current)
                if current.to_string_lossy().contains("/.harness/bin/")
                    || current
                        .to_string_lossy()
                        .contains("Harness.app/Contents/MacOS/") =>
            {
                std::fs::remove_file(link)?;
            }
            Ok(_) => return Ok(()),
            Err(_) if link.symlink_metadata().is_ok() => return Ok(()),
            Err(_) => {}
        }
        std::os::unix::fs::symlink(target, link)?;
    }
    Ok(())
}

fn ensure_local_bin_on_path(profile: &Path) -> std::io::Result<()> {
    const MARKER: &str = "# Harness CLI PATH";
    const STANZA: &str = "\n# Harness CLI PATH\ncase :\"$PATH\": in *:\"$HOME/.local/bin\":*) ;; *) export PATH=\"$HOME/.local/bin:$PATH\" ;; esac\n";
    let existing = match std::fs::read_to_string(profile) {
        Ok(value) => value,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(err) => return Err(err),
    };
    if existing.contains(MARKER) {
        return Ok(());
    }
    std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(profile)?
        .write_all(STANZA.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_path_stanza_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let profile = dir.path().join(".zshrc");
        ensure_local_bin_on_path(&profile).unwrap();
        ensure_local_bin_on_path(&profile).unwrap();
        assert_eq!(
            std::fs::read_to_string(profile)
                .unwrap()
                .matches("# Harness CLI PATH")
                .count(),
            1
        );
    }

    #[test]
    fn preserves_unowned_cli() {
        let dir = tempfile::tempdir().unwrap();
        let graff = dir.path().join("graff");
        std::fs::write(&graff, "custom").unwrap();
        link_if_ours(&graff, Path::new("/tmp/Harness.app/Contents/MacOS/harness")).unwrap();
        assert_eq!(std::fs::read_to_string(graff).unwrap(), "custom");
    }
}
