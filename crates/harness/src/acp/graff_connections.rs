//! Verified provider/model switching for resumed macOS chats.
use super::{
    graff_models::verify_resumed_model, request_draining_for_session, scan_available_commands,
};
use crate::HarnessError;
use crate::jsonrpc::{Incoming, RpcClient};
use harness_proto::SlashCommand;
use serde_json::{Value, json};

/// Never infer success from a command's acknowledgement: the fresh catalog
/// must name the exact provider and model before the user's text can be sent.
pub(super) async fn ensure_resumed_model(
    client: &RpcClient,
    incoming: &mut tokio::sync::mpsc::Receiver<Incoming>,
    session_id: &str,
    session: &mut Value,
    initial_commands: &[SlashCommand],
    requested: &str,
) -> Result<(), HarnessError> {
    let catalog = request_draining_for_session(
        client,
        incoming,
        "graff/models",
        json!({}),
        Some(session_id),
    )
    .await?;
    retain_session_metadata(session, &catalog);
    let (provider, model) = requested
        .split_once('/')
        .ok_or_else(|| HarnessError::Protocol("Invalid graff provider/model selection".into()))?;
    if provider.is_empty()
        || model.is_empty()
        || requested
            .chars()
            .any(|c| c.is_whitespace() || c.is_control())
    {
        return Err(HarnessError::Protocol(
            "Invalid graff provider/model selection".into(),
        ));
    }
    let offered = catalog
        .get("models")
        .and_then(Value::as_array)
        .is_some_and(|models| {
            models.iter().any(|row| {
                row["provider"].as_str() == Some(provider)
                    && row["name"].as_str() == Some(model)
                    && row["authenticated"] == true
            })
        });
    if !offered {
        return Err(HarnessError::Protocol(format!(
            "graff cannot switch to {requested}: sign in to that connection and refresh its models before retrying"
        )));
    }
    let mismatch = match verify_resumed_model(&catalog, requested) {
        Ok(()) => return Ok(()),
        Err(error) => error,
    };
    let commands = if session.get("availableCommands").is_some() {
        scan_available_commands(session)
    } else {
        initial_commands.to_vec()
    };
    // Old engines retain their explicit mismatch/recovery behavior. Never
    // manufacture an unadvertised command or submit user text to the old route.
    if !commands.iter().any(|command| command.name == "model") {
        return Err(mismatch);
    }
    let response = request_draining_for_session(
        client, incoming, "session/prompt",
        json!({"sessionId":session_id,"prompt":[{"type":"text","text":format!("/model {provider} {model}")}]}),
        Some(session_id),
    ).await?;
    if response["stopReason"] != "end_turn" {
        return Err(HarnessError::Protocol(format!(
            "graff did not complete the switch to {requested}; your message was not sent"
        )));
    }
    retain_session_metadata(session, &response);
    let confirmed = request_draining_for_session(
        client,
        incoming,
        "graff/models",
        json!({}),
        Some(session_id),
    )
    .await?;
    retain_session_metadata(session, &confirmed);
    verify_resumed_model(&confirmed, requested)?;
    if !confirmed["models"].as_array().is_some_and(|rows| {
        rows.iter().any(|row| {
            row["provider"].as_str() == Some(provider)
                && row["name"].as_str() == Some(model)
                && row["authenticated"] == true
        })
    }) {
        return Err(HarnessError::Protocol(format!(
            "graff no longer offers an authenticated connection for {requested}; your message was not sent"
        )));
    }
    Ok(())
}

fn retain_session_metadata(session: &mut Value, response: &Value) {
    for key in ["configOptions", "availableCommands"] {
        if response[key].is_array() {
            session[key] = response[key].clone();
        }
    }
}
