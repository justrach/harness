//! Delegated-task diagnostics, not a billing ledger or parent context occupancy.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DelegationInfo {
    /// UTF-8 bytes supplied explicitly by the caller, not tokens.
    pub context_bytes: u64,
    pub used_bytes: u64,
    pub summarized: bool,
    pub usage_reported: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage_unavailable_reason: Option<String>,
}

impl DelegationInfo {
    pub fn caption(&self) -> String {
        let context = if self.context_bytes == 0 {
            "Delegated task: no reference context supplied.".to_owned()
        } else {
            format!(
                "Delegated context: {} bytes supplied → {} bytes used ({}).",
                self.context_bytes,
                self.used_bytes,
                if self.summarized {
                    "summarized"
                } else {
                    "not summarized"
                }
            )
        };
        let accounting = if self.usage_reported {
            "Usage reported by the task runner; no settled charge supplied in this metadata."
        } else {
            self.usage_unavailable_reason
                .as_deref()
                .unwrap_or("Per-task usage and settled charge are unavailable; check your provider's account usage.")
        };
        format!("{context}\n\nUsage/cost: {accounting}")
    }
}
