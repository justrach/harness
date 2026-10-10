//! graff's ChatGPT plan route (`chatgpt-new`), where the composer and the
//! transcript show it, per OpenAI's UI guidelines for Sign in with ChatGPT:
//! "Using ChatGPT plan" with a Manage usage link while requests run on the
//! plan, and Manage usage as the primary action on a usage-limit error. The
//! sign-in itself lives in Settings → Accounts.

use gpui::{AnyElement, SharedString, div, prelude::*, px};
use harness_proto::{CHATGPT_MANAGE_USAGE_URL, HarnessId};

use crate::theme::Theme;

/// Whether a chat's picks send its requests to graff's ChatGPT plan route.
pub fn is_plan_model(harness: Option<HarnessId>, model: Option<&str>) -> bool {
    harness == Some(HarnessId::Graff) && model.is_some_and(|id| id.starts_with("chatgpt-new/"))
}

/// Whether an error is the plan's usage limit. graff reports it with OpenAI's
/// error code (`subscription_sharing_usage_limit_exceeded`, also spelled with
/// a `v2_`) or its own hint naming the plan's usage limit.
pub fn is_usage_limit_error(message: &str) -> bool {
    message.contains("subscription_sharing_usage_limit_exceeded")
        || message.contains("subscription_sharing_v2_usage_limit_exceeded")
        || message.contains("ChatGPT plan usage limit")
}

/// "Using ChatGPT plan · Manage usage", for the composer's footer.
pub fn using_plan_chip(theme: &Theme) -> AnyElement {
    div()
        .flex()
        .flex_row()
        .items_center()
        .gap(px(6.0))
        .text_size(crate::typography::ui_rems(11.5))
        .child(
            div()
                .text_color(theme.text_muted)
                .child(SharedString::from("Using ChatGPT plan")),
        )
        .child(
            div()
                .id("composer-chatgpt-manage-usage")
                .text_color(theme.text_muted)
                .cursor_pointer()
                .hover(|style| style.text_color(theme.text).underline())
                .on_click(|_, _, cx| cx.open_url(CHATGPT_MANAGE_USAGE_URL))
                .child(SharedString::from("Manage usage")),
        )
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_graffs_chatgpt_route_uses_the_plan() {
        assert!(is_plan_model(
            Some(HarnessId::Graff),
            Some("chatgpt-new/gpt-6.1-sol")
        ));
        for (harness, model) in [
            (Some(HarnessId::Graff), Some("codegraff/gpt-6.1-sol")),
            (Some(HarnessId::Graff), Some("chatgpt/gpt-6.1-sol")),
            (Some(HarnessId::Graff), None),
            (Some(HarnessId::Codex), Some("chatgpt-new/gpt-6.1-sol")),
            (None, Some("chatgpt-new/gpt-6.1-sol")),
        ] {
            assert!(!is_plan_model(harness, model), "{harness:?} {model:?}");
        }
    }

    #[test]
    fn usage_limit_errors_are_recognised_in_graffs_wording() {
        // agent_responses.zig failureDiagnostic, and agent_request.zig's 429 path.
        for message in [
            "chatgpt-new api error [subscription_sharing_usage_limit_exceeded]: Usage limit reached. — ChatGPT plan usage limit; manage usage at https://chatgpt.com/settings/usage",
            "chatgpt-new api error [subscription_sharing_v2_usage_limit_exceeded]: Usage limit reached.",
            "rate limited (429): quota/billing cap — ChatGPT plan usage limit; manage usage at https://chatgpt.com/settings/usage",
        ] {
            assert!(is_usage_limit_error(message), "{message}");
        }
        for message in [
            "chatgpt-new api error [subscription_sharing_usage_unavailable]: try later",
            "rate limited (429): quota/billing cap",
            "chatgpt-new api error [token_expired]: expired",
        ] {
            assert!(!is_usage_limit_error(message), "{message}");
        }
    }
}
