use super::*;

/// Row id of the desktop's appearance choice in the `preferences` kind.
pub const APPEARANCE_STATE_ID: &str = "appearance";

/// The desktop's appearance choice as other devices see it: the mode plus the
/// light and dark variant ids (`harness-theme` registry ids). Phones follow it
/// unless the user overrides locally.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncedAppearance {
    pub mode: String,
    pub light: String,
    pub dark: String,
}

impl SyncedAppearance {
    pub fn validate(&self) -> Result<(), DocError> {
        if !matches!(self.mode.as_str(), "system" | "light" | "dark") {
            return Err(DocError::Schema(format!("Unknown appearance mode {:?}", self.mode)));
        }
        for id in [&self.light, &self.dark] {
            if id.is_empty()
                || id.len() > 128
                || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
            {
                return Err(DocError::Schema(format!("Invalid theme id {id:?}")));
            }
        }
        Ok(())
    }
}

impl RegistryDoc {
    pub fn appearance(&self) -> Option<SyncedAppearance> {
        let row = self.overlay_row(KIND_PREFERENCES, APPEARANCE_STATE_ID)?;
        let field = |name: &str| row.fields.get(name)?.as_str().map(str::to_owned);
        Some(SyncedAppearance {
            mode: field("mode")?,
            light: field("light")?,
            dark: field("dark")?,
        })
    }

    /// Publish `appearance`, writing only the fields that differ so each field
    /// clock moves only when that choice actually changed.
    pub fn set_appearance(&mut self, appearance: &SyncedAppearance) -> Result<(), DocError> {
        appearance.validate()?;
        let current = self.overlay_row(KIND_PREFERENCES, APPEARANCE_STATE_ID);
        let changed: BTreeMap<String, Value> = [
            ("mode", &appearance.mode),
            ("light", &appearance.light),
            ("dark", &appearance.dark),
        ]
        .into_iter()
        .filter(|(name, value)| {
            current
                .as_ref()
                .and_then(|row| row.fields.get(*name))
                .and_then(Value::as_str)
                != Some(value.as_str())
        })
        .map(|(name, value)| (name.to_owned(), json!(value)))
        .collect();
        if !changed.is_empty() {
            self.write(KIND_PREFERENCES, APPEARANCE_STATE_ID, OpKind::Upsert, changed);
        }
        Ok(())
    }
}
