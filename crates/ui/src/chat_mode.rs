//! Chat mode: a plain conversation instead of a coding session. No project,
//! graff on the hosted gateway's auto tiers only, offered as Auto (low),
//! Auto (high) and Auto (smart). Pure, so the picker rules are tested
//! without UI.

use gpui::{AnyElement, SharedString, div, prelude::*};
use harness_proto::{HarnessId, Model};

use crate::popover::Loadable;
use crate::theme::Theme;

/// Chat mode always runs on graff, which reaches the hosted gateway.
pub const HARNESS: HarnessId = HarnessId::Graff;

/// One model chat mode offers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Tier {
    /// The picker id graff lists (`<provider>/<model>`).
    pub id: &'static str,
    /// Older gateways list the same tier under this id (`auto-medium` before
    /// `auto-low` existed).
    pub fallback_id: Option<&'static str>,
    pub label: &'static str,
    /// Shown under the row in the model menu.
    pub note: Option<&'static str>,
    /// Shown in the composer footer while the tier is selected, away from
    /// the model chip, so it names the tier.
    pub footer_note: Option<&'static str>,
}

pub const TIERS: [Tier; 3] = [
    Tier {
        id: "codegraff/auto-low",
        fallback_id: Some("codegraff/auto-medium"),
        label: "Auto (low)",
        note: None,
        footer_note: None,
    },
    Tier {
        id: "codegraff/auto-high",
        fallback_id: None,
        label: "Auto (high)",
        note: None,
        footer_note: None,
    },
    Tier {
        id: "codegraff/auto-smart",
        fallback_id: None,
        label: "Auto (smart)",
        note: Some(SMART_COST_NOTE),
        footer_note: Some(SMART_FOOTER_NOTE),
    },
];

/// Auto (smart) is billed at API rates.
pub const SMART_COST_NOTE: &str = "May incur API costs.";
/// [`SMART_COST_NOTE`] where the tier's name isn't beside it.
pub const SMART_FOOTER_NOTE: &str = "Auto (smart) may incur API costs.";

/// Why the Chat option is off: the hosted gateway lists none of the tiers
/// (an older gateway, signed out, or offline).
pub const UNAVAILABLE_NOTE: &str =
    "Chat needs the hosted Auto models, which aren't available right now.";

/// The model chip in a chat-mode draft or chat while no tier is listed.
pub const UNAVAILABLE_CHIP: &str = "Auto unavailable";

/// Whether chat mode can be offered, from the state of graff's catalog.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Availability {
    /// The catalog hasn't loaded yet; switching to chat mode loads it.
    Pending,
    /// At least one tier is listed.
    Available,
    /// The catalog loaded (or failed) without any tier: the Chat option is
    /// disabled and says why.
    Unavailable,
}

/// [`Availability`] for graff's catalog slot.
pub fn availability(catalog: Option<&Loadable<Vec<Model>>>) -> Availability {
    match catalog {
        None | Some(Loadable::Idle | Loadable::Loading) => Availability::Pending,
        Some(Loadable::Ready(models)) if default_id(models).is_some() => Availability::Available,
        Some(Loadable::Ready(_) | Loadable::Error(_)) => Availability::Unavailable,
    }
}

/// The chat-mode rows graff's catalog offers, in tier order, under the tier
/// names. A tier the gateway doesn't list yet is left out.
pub fn models(catalog: &[Model]) -> Vec<Model> {
    TIERS
        .iter()
        .filter_map(|tier| {
            let row = catalog.iter().find(|m| m.id == tier.id).or_else(|| {
                tier.fallback_id
                    .and_then(|id| catalog.iter().find(|m| m.id == id))
            })?;
            Some(Model {
                label: tier.label.into(),
                description: tier.note.map(str::to_owned),
                ..row.clone()
            })
        })
        .collect()
}

/// The model a new chat starts on: the first tier on offer (Auto (low)).
pub fn default_model(catalog: &[Model]) -> Option<String> {
    default_id(catalog).map(str::to_owned)
}

/// [`default_model`], borrowed from the catalog row.
pub fn default_id(catalog: &[Model]) -> Option<&str> {
    TIERS.iter().find_map(|tier| {
        catalog
            .iter()
            .find(|m| m.id == tier.id)
            .or_else(|| {
                tier.fallback_id
                    .and_then(|id| catalog.iter().find(|m| m.id == id))
            })
            .map(|m| m.id.as_str())
    })
}

/// Whether `id` is one of the models chat mode offers.
pub fn offers(id: &str) -> bool {
    TIERS
        .iter()
        .any(|tier| tier.id == id || tier.fallback_id == Some(id))
}

/// The tier name for `id` (`Auto (low)` for `auto-medium` too), whatever
/// label the catalog gives the row.
pub fn label_for(id: &str) -> Option<&'static str> {
    TIERS
        .iter()
        .find(|tier| tier.id == id || tier.fallback_id == Some(id))
        .map(|tier| tier.label)
}

/// The new-session canvas heading in chat mode: there's no project to name
/// or pick, so it says what the session is.
pub const HEADING_EYEBROW: &str = "New chat on the Auto models";
pub const HEADING_TITLE: &str = "What's on your mind?";

/// The footer note to show while `id` is selected (the API-cost warning for
/// Auto (smart)).
pub fn note_for(id: Option<&str>) -> Option<&'static str> {
    let id = id?;
    TIERS
        .iter()
        .find(|tier| tier.id == id || tier.fallback_id == Some(id))
        .and_then(|tier| tier.footer_note)
}

/// The composer's note while a model with one is selected.
pub fn note_chip(note: &'static str, theme: &Theme) -> AnyElement {
    div()
        .min_w_0()
        .truncate()
        .text_size(crate::typography::ui_rems(11.5))
        .text_color(theme.text_muted)
        .debug_selector(|| "chat-mode-note".into())
        .child(SharedString::from(note))
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn model(id: &str, label: &str) -> Model {
        Model {
            id: id.into(),
            label: label.into(),
            description: None,
            reasoning_levels: vec![],
            options: vec![],
            maker: None,
            billing: None,
        }
    }

    #[test]
    fn only_the_auto_tiers_are_offered_in_order_under_their_names() {
        let catalog = [
            model("codegraff/auto-smart", "auto-smart"),
            model("codegraff/claude-opus-5-5", "Claude Opus 5.5"),
            model("codegraff/auto-high", "Auto (high)"),
            model("chatgpt-new/gpt-6.1-sol", "GPT-6.1 Sol"),
            model("codegraff/auto-low", "Auto (low)"),
        ];
        let offered = models(&catalog);
        assert_eq!(
            offered
                .iter()
                .map(|m| (m.id.as_str(), m.label.as_str()))
                .collect::<Vec<_>>(),
            [
                ("codegraff/auto-low", "Auto (low)"),
                ("codegraff/auto-high", "Auto (high)"),
                ("codegraff/auto-smart", "Auto (smart)"),
            ]
        );
        assert_eq!(offered[2].description.as_deref(), Some(SMART_COST_NOTE));
        assert_eq!(
            default_model(&catalog).as_deref(),
            Some("codegraff/auto-low")
        );
    }

    #[test]
    fn an_older_gateway_offers_auto_medium_as_auto_low_and_omits_what_it_lacks() {
        let catalog = [
            model("codegraff/auto-medium", "Auto (medium)"),
            model("codegraff/auto-high", "Auto (high)"),
        ];
        let offered = models(&catalog);
        assert_eq!(
            offered
                .iter()
                .map(|m| (m.id.as_str(), m.label.as_str()))
                .collect::<Vec<_>>(),
            [
                ("codegraff/auto-medium", "Auto (low)"),
                ("codegraff/auto-high", "Auto (high)"),
            ]
        );
        assert!(models(&[]).is_empty());
        assert_eq!(default_model(&[]), None);
    }

    #[test]
    fn chat_mode_is_unavailable_when_the_gateway_lists_no_tier() {
        assert_eq!(availability(None), Availability::Pending);
        assert_eq!(
            availability(Some(&Loadable::Loading)),
            Availability::Pending
        );
        assert_eq!(
            availability(Some(&Loadable::Ready(vec![model(
                "codegraff/auto-medium",
                "Auto (medium)"
            )]))),
            Availability::Available,
            "the older auto-medium id still offers Auto (low)"
        );
        assert_eq!(
            availability(Some(&Loadable::Ready(vec![model(
                "codegraff/claude-opus-5-5",
                "Claude Opus 5.5"
            )]))),
            Availability::Unavailable
        );
        assert_eq!(
            availability(Some(&Loadable::Ready(vec![]))),
            Availability::Unavailable
        );
        assert_eq!(
            availability(Some(&Loadable::Error("signed out".into()))),
            Availability::Unavailable
        );
    }

    #[test]
    fn the_cost_note_belongs_to_auto_smart_only() {
        assert_eq!(
            note_for(Some("codegraff/auto-smart")),
            Some("Auto (smart) may incur API costs.")
        );
        assert_eq!(SMART_COST_NOTE, "May incur API costs.");
        assert_eq!(note_for(Some("codegraff/auto-high")), None);
        assert_eq!(note_for(Some("codegraff/auto-medium")), None);
        assert_eq!(note_for(None), None);
        assert!(offers("codegraff/auto-medium"));
        assert_eq!(label_for("codegraff/auto-medium"), Some("Auto (low)"));
        assert_eq!(label_for("codegraff/auto-smart"), Some("Auto (smart)"));
        assert_eq!(label_for("codegraff/claude-opus-5-5"), None);
        assert!(!offers("codegraff/claude-opus-5-5"));
    }
}
