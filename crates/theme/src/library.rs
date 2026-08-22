use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use anyhow::{Context as _, Result, anyhow, bail};
use serde::{Deserialize, Serialize};

use crate::vscode::{
    CompileOptions, DetectedThemeSource, ImportReport, SourceCompilation, compile_source,
};
use crate::{ThemeFamily, ThemeRegistry, replace_custom_families};

const LIBRARY_FILE: &str = "theme-library.json";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallMode {
    Snapshot,
    Link,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum CustomThemeSource {
    ImportedSnapshot {
        imported_from: Option<PathBuf>,
    },
    LinkedFile {
        path: PathBuf,
    },
    LinkedPackage {
        path: PathBuf,
    },
    /// A native resolved-family file created by Zeron for direct editing.
    EditableFile {
        path: PathBuf,
    },
}

impl CustomThemeSource {
    pub fn path(&self) -> Option<&Path> {
        match self {
            Self::ImportedSnapshot { imported_from } => imported_from.as_deref(),
            Self::LinkedFile { path }
            | Self::LinkedPackage { path }
            | Self::EditableFile { path } => Some(path),
        }
    }

    pub fn is_linked(&self) -> bool {
        matches!(
            self,
            Self::LinkedFile { .. } | Self::LinkedPackage { .. } | Self::EditableFile { .. }
        )
    }

    pub fn label(&self) -> &'static str {
        match self {
            Self::ImportedSnapshot { .. } => "Imported",
            Self::LinkedFile { .. } => "Linked file",
            Self::LinkedPackage { .. } => "Linked package",
            Self::EditableFile { .. } => "Editable file",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum CustomThemeStatus {
    Ready,
    Warning { message: String },
}

impl Default for CustomThemeStatus {
    fn default() -> Self {
        Self::Ready
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CustomThemeEntry {
    pub id: String,
    pub name: String,
    pub source: CustomThemeSource,
    pub family: ThemeFamily,
    pub reports: BTreeMap<String, ImportReport>,
    pub selected_variant_ids: Vec<String>,
    #[serde(default)]
    pub status: CustomThemeStatus,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CustomThemeLibrary {
    #[serde(default)]
    pub entries: Vec<CustomThemeEntry>,
}

impl CustomThemeLibrary {
    pub fn path(data_dir: &Path) -> PathBuf {
        data_dir.join(LIBRARY_FILE)
    }

    pub fn load(data_dir: &Path) -> Result<Self> {
        let path = Self::path(data_dir);
        let source = match fs::read_to_string(&path) {
            Ok(source) => source,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Self::default()),
            Err(error) => {
                return Err(error).with_context(|| format!("could not read {}", path.display()));
            }
        };
        serde_json::from_str(&source).with_context(|| format!("could not parse {}", path.display()))
    }

    pub fn save(&self, data_dir: &Path) -> Result<()> {
        fs::create_dir_all(data_dir)
            .with_context(|| format!("could not create {}", data_dir.display()))?;
        let path = Self::path(data_dir);
        let temporary = path.with_extension("json.tmp");
        fs::write(&temporary, serde_json::to_vec_pretty(self)?)
            .with_context(|| format!("could not write {}", temporary.display()))?;
        fs::rename(&temporary, &path)
            .with_context(|| format!("could not replace {}", path.display()))?;
        Ok(())
    }

    pub fn install_runtime(&self) {
        replace_custom_families(
            self.entries
                .iter()
                .map(|entry| entry.family.clone())
                .collect(),
        );
    }

    pub fn entry(&self, id: &str) -> Option<&CustomThemeEntry> {
        self.entries.iter().find(|entry| entry.id == id)
    }

    pub fn compile(path: &Path, family_id: &str, family_name: &str) -> Result<SourceCompilation> {
        compile_source(
            path,
            CompileOptions {
                family_id: family_id.into(),
                family_name: family_name.into(),
                source_url: path.display().to_string(),
                revision: "local".into(),
                license: "User supplied".into(),
            },
        )
    }

    pub fn install(
        &mut self,
        compilation: SourceCompilation,
        selected_variant_ids: &[String],
        mode: InstallMode,
    ) -> Result<String> {
        let selected: HashSet<_> = selected_variant_ids.iter().collect();
        let mut family = compilation.family;
        family
            .variants
            .retain(|variant| selected.is_empty() || selected.contains(&variant.id));
        if family.variants.is_empty() {
            bail!("select at least one successfully compiled variant");
        }
        let entry_id = unique_id(
            &family.id,
            self.entries.iter().map(|entry| entry.id.as_str()),
        );
        let old_variant_ids = family
            .variants
            .iter()
            .map(|variant| variant.id.clone())
            .collect::<Vec<_>>();
        if entry_id != family.id {
            rekey_family(&mut family, &entry_id);
        }
        let errors = validation_errors(&family);
        if !errors.is_empty() {
            bail!("theme validation failed: {}", errors.join("; "));
        }
        let selected_variant_ids = family
            .variants
            .iter()
            .map(|variant| variant.id.clone())
            .collect::<Vec<_>>();
        let mut reports = BTreeMap::new();
        for (old_id, variant) in old_variant_ids.iter().zip(&family.variants) {
            if let Some(report) = compilation.reports.get(old_id) {
                reports.insert(variant.id.clone(), report.clone());
            }
        }
        let path = compilation.path;
        let source = match (mode, compilation.source_kind) {
            (InstallMode::Snapshot, _) => CustomThemeSource::ImportedSnapshot {
                imported_from: Some(path),
            },
            (InstallMode::Link, DetectedThemeSource::File) => {
                CustomThemeSource::LinkedFile { path }
            }
            (InstallMode::Link, DetectedThemeSource::Package) => {
                CustomThemeSource::LinkedPackage { path }
            }
        };
        self.entries.push(CustomThemeEntry {
            id: entry_id.clone(),
            name: family.name.clone(),
            source,
            family,
            reports,
            selected_variant_ids,
            status: CustomThemeStatus::Ready,
        });
        Ok(entry_id)
    }

    /// Reload a linked source. The existing compiled family is only replaced
    /// after a complete successful compile, preserving the last known good
    /// version on any source error.
    pub fn reload(&mut self, id: &str) -> Result<()> {
        let entry = self
            .entries
            .iter_mut()
            .find(|entry| entry.id == id)
            .ok_or_else(|| anyhow!("unknown custom theme `{id}`"))?;
        let path = match &entry.source {
            CustomThemeSource::LinkedFile { path } | CustomThemeSource::LinkedPackage { path } => {
                path.clone()
            }
            CustomThemeSource::EditableFile { path } => {
                let path = path.clone();
                let family = match load_editable_family(&path, &entry.id) {
                    Ok(family) => family,
                    Err(error) => {
                        entry.status = CustomThemeStatus::Warning {
                            message: error.to_string(),
                        };
                        return Err(error);
                    }
                };
                entry.selected_variant_ids = family
                    .variants
                    .iter()
                    .map(|variant| variant.id.clone())
                    .collect();
                entry.name = family.name.clone();
                entry.family = family;
                entry.reports.clear();
                entry.status = CustomThemeStatus::Ready;
                return Ok(());
            }
            CustomThemeSource::ImportedSnapshot { .. } => bail!("imported snapshots cannot reload"),
        };
        let compilation = match Self::compile(&path, &entry.id, &entry.name) {
            Ok(compilation) if compilation.failures.is_empty() => compilation,
            Ok(compilation) => {
                let message = compilation
                    .failures
                    .iter()
                    .map(|failure| format!("{}: {}", failure.name, failure.message))
                    .collect::<Vec<_>>()
                    .join("; ");
                entry.status = CustomThemeStatus::Warning {
                    message: message.clone(),
                };
                return Err(anyhow!(message));
            }
            Err(error) => {
                entry.status = CustomThemeStatus::Warning {
                    message: error.to_string(),
                };
                return Err(error);
            }
        };
        let wanted: HashSet<_> = entry.selected_variant_ids.iter().cloned().collect();
        let mut family = compilation.family;
        family
            .variants
            .retain(|variant| wanted.contains(&variant.id));
        if family.variants.is_empty() {
            let message = "the linked source no longer contains any selected variants".to_string();
            entry.status = CustomThemeStatus::Warning {
                message: message.clone(),
            };
            bail!(message);
        }
        let errors = validation_errors(&family);
        if !errors.is_empty() {
            let message = format!("theme validation failed: {}", errors.join("; "));
            entry.status = CustomThemeStatus::Warning {
                message: message.clone(),
            };
            bail!(message);
        }
        entry.family = family;
        entry.reports = compilation
            .reports
            .into_iter()
            .filter(|(variant_id, _)| wanted.contains(variant_id))
            .collect();
        entry.status = CustomThemeStatus::Ready;
        Ok(())
    }

    pub fn unlink(&mut self, id: &str) -> Result<()> {
        let entry = self
            .entries
            .iter_mut()
            .find(|entry| entry.id == id)
            .ok_or_else(|| anyhow!("unknown custom theme `{id}`"))?;
        let imported_from = entry.source.path().map(Path::to_path_buf);
        entry.source = CustomThemeSource::ImportedSnapshot { imported_from };
        entry.status = CustomThemeStatus::Ready;
        Ok(())
    }

    pub fn duplicate_as_snapshot(&mut self, id: &str) -> Result<String> {
        let original = self
            .entries
            .iter()
            .find(|entry| entry.id == id)
            .cloned()
            .ok_or_else(|| anyhow!("unknown custom theme `{id}`"))?;
        let new_id = unique_id(
            &format!("{}-copy", original.id),
            self.entries.iter().map(|entry| entry.id.as_str()),
        );
        let mut duplicate = original;
        duplicate.id = new_id.clone();
        duplicate.name = format!("{} Copy", duplicate.name);
        let old_variant_ids = duplicate
            .family
            .variants
            .iter()
            .map(|variant| variant.id.clone())
            .collect::<Vec<_>>();
        rekey_family(&mut duplicate.family, &new_id);
        duplicate.reports = old_variant_ids
            .iter()
            .zip(&duplicate.family.variants)
            .filter_map(|(old_id, variant)| {
                duplicate
                    .reports
                    .get(old_id)
                    .cloned()
                    .map(|report| (variant.id.clone(), report))
            })
            .collect();
        duplicate.selected_variant_ids = duplicate
            .family
            .variants
            .iter()
            .map(|variant| variant.id.clone())
            .collect();
        duplicate.source = CustomThemeSource::ImportedSnapshot {
            imported_from: duplicate.source.path().map(Path::to_path_buf),
        };
        duplicate.status = CustomThemeStatus::Ready;
        self.entries.push(duplicate);
        Ok(new_id)
    }

    /// Duplicate a compiled family into a native, user-editable file. Reveal
    /// opens that file in the system file manager; Reload validates it and
    /// preserves the last known good family if an edit is invalid.
    pub fn duplicate_as_editable(&mut self, id: &str, data_dir: &Path) -> Result<String> {
        let original = self
            .entries
            .iter()
            .find(|entry| entry.id == id)
            .cloned()
            .ok_or_else(|| anyhow!("unknown custom theme `{id}`"))?;
        let new_id = unique_id(
            &format!("{}-copy", original.id),
            self.entries.iter().map(|entry| entry.id.as_str()),
        );
        let mut family = original.family;
        family.name = format!("{} Copy", family.name);
        rekey_family(&mut family, &new_id);

        let editable_dir = data_dir.join("custom-themes");
        fs::create_dir_all(&editable_dir)
            .with_context(|| format!("could not create {}", editable_dir.display()))?;
        let path = editable_dir.join(format!("{new_id}.zeron-theme.json"));
        let temporary = path.with_extension("json.tmp");
        fs::write(&temporary, serde_json::to_vec_pretty(&family)?)
            .with_context(|| format!("could not write {}", temporary.display()))?;
        fs::rename(&temporary, &path)
            .with_context(|| format!("could not replace {}", path.display()))?;

        let selected_variant_ids = family
            .variants
            .iter()
            .map(|variant| variant.id.clone())
            .collect();
        self.entries.push(CustomThemeEntry {
            id: new_id.clone(),
            name: family.name.clone(),
            source: CustomThemeSource::EditableFile { path },
            family,
            reports: BTreeMap::new(),
            selected_variant_ids,
            status: CustomThemeStatus::Ready,
        });
        Ok(new_id)
    }

    pub fn remove(&mut self, id: &str) -> bool {
        let before = self.entries.len();
        self.entries.retain(|entry| entry.id != id);
        self.entries.len() != before
    }
}

fn load_editable_family(path: &Path, expected_id: &str) -> Result<ThemeFamily> {
    let source = fs::read_to_string(path)
        .with_context(|| format!("could not read editable theme {}", path.display()))?;
    let family: ThemeFamily = serde_json::from_str(&source)
        .with_context(|| format!("could not parse editable theme {}", path.display()))?;
    if family.id != expected_id {
        bail!(
            "editable theme family id must remain `{expected_id}` (found `{}`)",
            family.id
        );
    }
    let errors = validation_errors(&family);
    if !errors.is_empty() {
        bail!("editable theme validation failed: {}", errors.join("; "));
    }
    Ok(family)
}

fn validation_errors(family: &ThemeFamily) -> Vec<String> {
    ThemeRegistry {
        families: vec![family.clone()],
    }
    .validate()
    .into_iter()
    .filter(|issue| issue.is_blocking())
    .map(|issue| format!("{}: {}", issue.variant_id, issue.message))
    .collect()
}

fn unique_id<'a>(base: &str, existing: impl Iterator<Item = &'a str>) -> String {
    let existing = existing.collect::<HashSet<_>>();
    if !existing.contains(base) {
        return base.into();
    }
    (2..)
        .map(|suffix| format!("{base}-{suffix}"))
        .find(|candidate| !existing.contains(candidate.as_str()))
        .expect("an unused numeric suffix always exists")
}

fn rekey_family(family: &mut ThemeFamily, new_id: &str) {
    let old_id = family.id.clone();
    family.id = new_id.into();
    for variant in &mut family.variants {
        variant.family_id = new_id.into();
        variant.id = variant
            .id
            .strip_prefix(&old_id)
            .map(|suffix| format!("{new_id}{suffix}"))
            .unwrap_or_else(|| format!("{new_id}-{}", variant.id));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn package(dir: &Path) {
        fs::create_dir_all(dir.join("themes")).unwrap();
        fs::write(
            dir.join("package.json"),
            r#"{
              "displayName": "Test Family",
              "contributes": { "themes": [
                { "label": "Test Light", "uiTheme": "vs", "path": "./themes/light.json" },
                { "label": "Test Dark", "uiTheme": "vs-dark", "path": "./themes/dark.json" }
              ] }
            }"#,
        )
        .unwrap();
        fs::write(
            dir.join("themes/light.json"),
            r##"{"colors":{"editor.background":"#ffffff","foreground":"#222222","focusBorder":"#0066cc"}}"##,
        )
        .unwrap();
        fs::write(
            dir.join("themes/dark.json"),
            r##"{"colors":{"editor.background":"#111111","foreground":"#eeeeee","focusBorder":"#66aaff"}}"##,
        )
        .unwrap();
    }

    #[test]
    fn linked_reload_keeps_last_known_good_on_failure() {
        let dir = tempfile::tempdir().unwrap();
        package(dir.path());
        let compiled =
            CustomThemeLibrary::compile(dir.path(), "test-family", "Test Family").unwrap();
        let mut library = CustomThemeLibrary::default();
        let id = library.install(compiled, &[], InstallMode::Link).unwrap();
        let previous = library.entry(&id).unwrap().family.clone();
        fs::write(dir.path().join("themes/dark.json"), "not json").unwrap();

        assert!(library.reload(&id).is_err());
        let entry = library.entry(&id).unwrap();
        assert_eq!(entry.family, previous);
        assert!(matches!(entry.status, CustomThemeStatus::Warning { .. }));
    }

    #[test]
    fn linked_reload_hardens_low_contrast_palette() {
        let dir = tempfile::tempdir().unwrap();
        package(dir.path());
        let compiled =
            CustomThemeLibrary::compile(dir.path(), "test-family", "Test Family").unwrap();
        let mut library = CustomThemeLibrary::default();
        let id = library.install(compiled, &[], InstallMode::Link).unwrap();
        fs::write(
            dir.path().join("themes/dark.json"),
            r##"{"colors":{"editor.background":"#111111","foreground":"#111111","focusBorder":"#66aaff"}}"##,
        )
        .unwrap();

        library.reload(&id).unwrap();
        let entry = library.entry(&id).unwrap();
        let variant = &entry.family.variants[0];
        assert!(variant.colors.text.contrast(variant.colors.background) >= 4.5);
        assert!(
            entry
                .reports
                .values()
                .any(|report| !report.adjustments.is_empty())
        );
        assert_eq!(entry.status, CustomThemeStatus::Ready);
    }

    #[test]
    fn snapshot_round_trips_and_duplicate_gets_independent_ids() {
        let source = tempfile::tempdir().unwrap();
        package(source.path());
        let compiled =
            CustomThemeLibrary::compile(source.path(), "test-family", "Test Family").unwrap();
        let mut library = CustomThemeLibrary::default();
        let id = library
            .install(compiled, &[], InstallMode::Snapshot)
            .unwrap();
        let copy = library.duplicate_as_snapshot(&id).unwrap();
        assert_ne!(id, copy);
        assert!(
            library
                .entry(&copy)
                .unwrap()
                .family
                .variants
                .iter()
                .all(|variant| variant.family_id == copy)
        );

        let data = tempfile::tempdir().unwrap();
        library.save(data.path()).unwrap();
        assert_eq!(CustomThemeLibrary::load(data.path()).unwrap(), library);
    }

    #[test]
    fn contrast_findings_do_not_block_install() {
        let source = tempfile::tempdir().unwrap();
        package(source.path());
        let mut compiled =
            CustomThemeLibrary::compile(source.path(), "test-family", "Test Family").unwrap();
        let variant = &mut compiled.family.variants[0];
        variant.colors.text = variant.colors.background;

        CustomThemeLibrary::default()
            .install(compiled, &[], InstallMode::Snapshot)
            .unwrap();
    }

    #[test]
    fn install_rejects_structurally_invalid_palettes() {
        let source = tempfile::tempdir().unwrap();
        package(source.path());
        let mut compiled =
            CustomThemeLibrary::compile(source.path(), "test-family", "Test Family").unwrap();
        compiled.family.variants[0].source.asset_hash.clear();

        let error = CustomThemeLibrary::default()
            .install(compiled, &[], InstallMode::Snapshot)
            .unwrap_err();
        assert!(error.to_string().contains("theme validation failed"));
    }

    #[test]
    fn editable_duplicate_reloads_and_keeps_last_known_good_on_failure() {
        let source = tempfile::tempdir().unwrap();
        package(source.path());
        let compiled =
            CustomThemeLibrary::compile(source.path(), "test-family", "Test Family").unwrap();
        let mut library = CustomThemeLibrary::default();
        let id = library
            .install(compiled, &[], InstallMode::Snapshot)
            .unwrap();
        let data = tempfile::tempdir().unwrap();
        let copy = library.duplicate_as_editable(&id, data.path()).unwrap();
        let path = match &library.entry(&copy).unwrap().source {
            CustomThemeSource::EditableFile { path } => path.clone(),
            source => panic!("expected editable source, found {source:?}"),
        };

        let mut edited = library.entry(&copy).unwrap().family.clone();
        edited.name = "Edited Copy".into();
        fs::write(&path, serde_json::to_vec_pretty(&edited).unwrap()).unwrap();
        library.reload(&copy).unwrap();
        assert_eq!(library.entry(&copy).unwrap().name, "Edited Copy");

        let last_known_good = library.entry(&copy).unwrap().family.clone();
        fs::write(&path, "not json").unwrap();
        assert!(library.reload(&copy).is_err());
        let entry = library.entry(&copy).unwrap();
        assert_eq!(entry.family, last_known_good);
        assert!(matches!(entry.status, CustomThemeStatus::Warning { .. }));
    }
}
