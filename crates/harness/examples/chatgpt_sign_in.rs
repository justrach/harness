//! Sign this computer in to ChatGPT from Harness (plan usage), or sign out.
//!
//! ```text
//! cargo run -p harness-adapters --example chatgpt_sign_in            # sign in
//! cargo run -p harness-adapters --example chatgpt_sign_in -- status
//! cargo run -p harness-adapters --example chatgpt_sign_in -- sign-out
//! ```
//!
//! Signing in opens the browser on this computer and waits up to five minutes.

use harness_adapters::codex::{SignInOutcome, SignInProgress, chatgpt_status, sign_in, sign_out};
use tokio_util::sync::CancellationToken;

#[tokio::main]
async fn main() {
    match std::env::args().nth(1).as_deref() {
        Some("status") => {
            let status = chatgpt_status();
            println!(
                "signed in: {}, plan usage: {}, account: {}",
                status.signed_in,
                status.plan_usage,
                status.email.as_deref().unwrap_or("-")
            );
        }
        Some("sign-out") => match sign_out().await {
            Ok(true) => println!("Signed out."),
            Ok(false) => println!(
                "Signed out here, but OpenAI did not confirm the revocation. \
                 You can disconnect Harness in ChatGPT settings."
            ),
            Err(error) => println!("{error}"),
        },
        _ => {
            let cancel = CancellationToken::new();
            let result = sign_in(&cancel, |SignInProgress::OpenBrowser(url)| {
                println!("Opening your browser to sign in to ChatGPT…");
                let opener = if cfg!(target_os = "macos") {
                    "open"
                } else {
                    "xdg-open"
                };
                if std::process::Command::new(opener)
                    .arg(&url)
                    .status()
                    .is_err()
                {
                    println!("Open this page: {url}");
                }
            })
            .await;
            match result {
                Ok(SignInOutcome::Connected { email }) => {
                    println!(
                        "Signed in as {}; plan usage is on.",
                        email.as_deref().unwrap_or("your account")
                    );
                }
                Ok(SignInOutcome::PlanUsageOff { .. }) => {
                    println!("Signed in, but plan usage was not allowed.");
                }
                Err(error) => println!("{error}"),
            }
        }
    }
}
