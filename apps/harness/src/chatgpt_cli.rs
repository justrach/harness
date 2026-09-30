//! `harness chatgpt login | status | logout` — sign in to ChatGPT from Harness so
//! OpenAI Codex runs on the person's plan (beta). Harness does the sign-in
//! itself: the browser opens on this computer, and the result stays here.

use anyhow::bail;
use harness_adapters::codex::{
    SignInError, SignInOutcome, SignInProgress, chatgpt_status, plan_usage_enabled, sign_in,
    sign_out,
};
use tokio_util::sync::CancellationToken;

/// What to tell the person after a sign-in. `plan_on` is whether this build
/// runs Codex on the plan (beta builds do, stable ones need the switch).
fn describe(outcome: &SignInOutcome, plan_on: bool) -> String {
    match outcome {
        SignInOutcome::Connected { email } => {
            let who = email.as_deref().unwrap_or("your account");
            if plan_on {
                format!(
                    "Signed in to ChatGPT as {who}. OpenAI Codex now runs on your ChatGPT plan."
                )
            } else {
                format!(
                    "Signed in to ChatGPT as {who}. Plan usage is off in this build; \
                     set HARNESS_CHATGPT_PLAN=1 to run OpenAI Codex on your plan."
                )
            }
        }
        SignInOutcome::PlanUsageOff { email } => format!(
            "Signed in to ChatGPT as {}, but plan usage was not allowed, so OpenAI Codex \
             cannot use your plan. Run `harness chatgpt login` again and allow it.",
            email.as_deref().unwrap_or("your account")
        ),
    }
}

pub async fn login() -> anyhow::Result<()> {
    let cancel = CancellationToken::new();
    let on_progress = |progress: SignInProgress| {
        let SignInProgress::OpenBrowser(url) = progress;
        println!("Opening your browser to sign in to ChatGPT. Approve it there.");
        harness_adapters::codex::open_in_browser(&url);
        println!("If nothing opened, visit:\n{url}");
    };
    let result = tokio::select! {
        result = sign_in(&cancel, on_progress) => result,
        _ = tokio::signal::ctrl_c() => {
            cancel.cancel();
            Err(SignInError::Cancelled)
        }
    };
    match result {
        Ok(outcome) => {
            println!("{}", describe(&outcome, plan_usage_enabled()));
            Ok(())
        }
        Err(error) => bail!("{error}"),
    }
}

pub fn status() -> anyhow::Result<()> {
    let status = chatgpt_status();
    if !status.signed_in {
        println!("ChatGPT: not signed in. Run `harness chatgpt login`.");
        return Ok(());
    }
    println!(
        "ChatGPT: signed in as {}",
        status.email.as_deref().unwrap_or("your account")
    );
    println!(
        "Plan usage: {}",
        if status.plan_usage {
            "allowed"
        } else {
            "not allowed"
        }
    );
    println!(
        "OpenAI Codex on your plan: {}",
        match (status.plan_usage, plan_usage_enabled()) {
            (false, _) => "no (plan usage was not allowed)",
            (true, true) => "yes",
            (true, false) => "no (off in this build; set HARNESS_CHATGPT_PLAN=1)",
        }
    );
    Ok(())
}

pub async fn logout() -> anyhow::Result<()> {
    match sign_out().await {
        Ok(true) => println!("Signed out of ChatGPT."),
        Ok(false) => println!(
            "Signed out of ChatGPT here, but OpenAI did not confirm ending the session. \
             You can disconnect Harness in your ChatGPT settings."
        ),
        Err(error) => bail!("{error}"),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn connected() -> SignInOutcome {
        SignInOutcome::Connected {
            email: Some("me@example.com".into()),
        }
    }

    #[test]
    fn a_sign_in_says_whether_codex_is_on_the_plan() {
        let on = describe(&connected(), true);
        assert!(on.contains("me@example.com") && on.contains("now runs on your ChatGPT plan"));
        let off = describe(&connected(), false);
        assert!(off.contains("HARNESS_CHATGPT_PLAN=1"), "{off}");
        assert!(!off.contains("now runs"));
    }

    #[test]
    fn a_sign_in_without_plan_usage_says_how_to_allow_it() {
        let text = describe(&SignInOutcome::PlanUsageOff { email: None }, true);
        assert!(text.contains("your account"));
        assert!(text.contains("harness chatgpt login"), "{text}");
    }
}
