//! `zeron update` — check for and apply a newer release, natively (the same
//! flow `edge/src/install.sh` performs: download → verify → symlink swap →
//! service restart). macOS app bundles swap the bundle instead; source builds
//! are report-only.

use anyhow::bail;
use harness_update::{InstallKind, current_version, version_newer};

/// `--check` prints the verdict and exits (nonzero when an update is available,
/// so scripts can gate on it).
pub async fn update(edge_url: &str, check_only: bool) -> anyhow::Result<()> {
    let manifest = harness_update::fetch_latest(edge_url).await?;
    let current = current_version();
    if !version_newer(&manifest.version, current) {
        println!(
            "zeron {current} is up to date (latest: {}).",
            manifest.version
        );
        return Ok(());
    }
    println!("zeron {current} → {} available", manifest.version);
    if check_only {
        std::process::exit(1);
    }

    match harness_update::detect_install() {
        InstallKind::Managed { app_root } => {
            println!(
                "downloading {}…",
                harness_update::headless_artifact(&manifest.version)
            );
            harness_update::stage_headless(edge_url, &manifest, &app_root).await?;
            harness_update::apply_headless(&app_root, &manifest.version)?;
            println!(
                "installed {} (current → {})",
                app_root.join(&manifest.version).display(),
                manifest.version
            );
            match harness_update::restart_service() {
                Ok(()) => println!("engine service restarted."),
                Err(err) => println!(
                    "note: service restart failed ({err:#}) — restart the engine manually to finish."
                ),
            }
            Ok(())
        }
        InstallKind::MacApp { bundle } => {
            println!(
                "downloading {}…",
                harness_update::mac_app_artifact(&manifest.version)
            );
            let data_dir = super::paths::data_dir();
            let staged = harness_update::stage_mac_app(edge_url, &manifest, &data_dir).await?;
            harness_update::apply_mac_app(&staged, &bundle)?;
            println!("updated {} — relaunch Harness to finish.", bundle.display());
            Ok(())
        }
        #[cfg(windows)]
        InstallKind::WindowsPortable { directory } => {
            let staged = harness_update::windows::stage(edge_url, &manifest, &directory).await?;
            harness_update::windows::apply(&staged, &directory, false)?;
            println!(
                "updated to {} — relaunch Harness to finish.",
                manifest.version
            );
            Ok(())
        }
        InstallKind::Unmanaged => {
            bail!(
                "this binary is not update-managed (source build or hand-copied).\n\
                 Linux: curl -fsSL https://zeron.sh/install.sh | sh\n\
                 macOS: download the new Harness.app dmg, or rebuild from source.\n\
                 Windows: use an update-enabled portable package, or rebuild from source."
            )
        }
    }
}
