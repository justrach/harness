//! Writes the built-in theme registry as JSON for clients that can't link this
//! crate (the iOS app bundles the output as `Theme/themes.json`).
//!
//! ```bash
//! cargo run -p harness-theme --bin harness-theme-export -- \
//!   --output apps/ios/Harness/Theme/themes.json
//! ```

use std::fs;
use std::path::PathBuf;

use anyhow::{Context as _, Result};
use clap::Parser;

#[derive(Debug, Parser)]
struct Args {
    /// Where to write the catalog; stdout when omitted.
    #[arg(long)]
    output: Option<PathBuf>,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let json = harness_theme::builtin_catalog_json()?;
    match args.output {
        Some(path) => {
            fs::write(&path, json).with_context(|| format!("writing {}", path.display()))?
        }
        None => print!("{json}"),
    }
    Ok(())
}
