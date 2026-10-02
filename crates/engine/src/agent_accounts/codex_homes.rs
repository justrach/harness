//! Host-owned Codex credential homes. Conversation/configuration entries are
//! linked to the ordinary Codex home; credentials and model caches stay private.
//! The shared-state/private-auth approach is also used by T3 Code's
//! CodexHomeLayout (https://github.com/pingdotgg/t3code); this is a Rust
//! implementation using Harness's existing saved-login slots.

use super::*;
use harness_proto::{CODEX_ACCOUNT_OPTION, ModelOption, ModelOptionChoice};

impl AgentAccounts {
    pub(super) fn codex_slot_home(&self, id: &str) -> PathBuf {
        self.inner.config.root_dir().join("codex-homes").join(id)
    }

    /// Catalog choices contain only identities, never credentials or paths.
    pub async fn codex_account_option(&self) -> Result<Option<ModelOption>, EngineError> {
        let snapshot = self.list(false).await?;
        let accounts: Vec<_> = snapshot
            .accounts
            .into_iter()
            .filter(|a| a.harness == HarnessId::Codex && a.switchable)
            .collect();
        let Some(default) = accounts.iter().find(|a| a.active).or(accounts.first()) else {
            return Ok(None);
        };
        Ok(Some(ModelOption {
            id: CODEX_ACCOUNT_OPTION.into(),
            label: "Codex account".into(),
            default_choice: default.id.clone(),
            choices: accounts
                .iter()
                .map(|a| ModelOptionChoice {
                    id: a.id.clone(),
                    label: a
                        .email
                        .clone()
                        .or(a.display_name.clone())
                        .unwrap_or_else(|| "API key".into()),
                })
                .collect(),
        }))
    }

    /// Resolve on the execution host. Unknown/removed accounts fail closed;
    /// they must never fall back to another billable login.
    pub async fn codex_run_home(
        &self,
        selected: Option<&str>,
    ) -> Result<Option<(String, PathBuf)>, EngineError> {
        if selected.is_some_and(|id| !valid_slot_id(id)) {
            return Err(EngineError::Other("Unknown Codex account.".into()));
        }
        let _ops = self.inner.ops.lock().await;
        let snapshot = self.list_locked(false).await?;
        let id = match selected {
            Some(id) => id.to_owned(),
            None => match snapshot
                .accounts
                .iter()
                .find(|a| a.harness == HarnessId::Codex && a.active)
            {
                Some(account) => account.id.clone(),
                None => return Ok(None),
            },
        };
        let slot = self.read_slots(HarnessId::Codex).into_iter().find(|s| s.id == id)
            .ok_or_else(|| EngineError::Other("This Codex account is no longer saved on this device. Add it again in Settings → Agents.".into()))?;
        let shared = &self.inner.config.codex_home;
        std::fs::create_dir_all(shared)?;
        let shared = shared.canonicalize()?;
        let home = self.codex_slot_home(&id);
        private_directory(&home)?;
        let auth = home.join("auth.json");
        match std::fs::symlink_metadata(&auth) {
            Ok(metadata) if !metadata.is_file() || metadata.file_type().is_symlink() => {
                return Err(EngineError::Other(
                    "Codex account credentials must be a private file.".into(),
                ));
            }
            Ok(_) => {
                let detected = read_json(&auth).and_then(parse_codex_auth).ok_or_else(|| {
                    EngineError::Other(
                        "Codex account credentials are unreadable. Sign in again.".into(),
                    )
                })?;
                if detected.account_key != slot.account_key {
                    return Err(EngineError::Other(
                        "Codex account credentials do not match the selected account.".into(),
                    ));
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                write_file_atomic(&auth, slot.credentials.to_string().as_bytes(), true)?;
            }
            Err(e) => return Err(e.into()),
        }
        // Create shared directories before the first native process, including
        // when a new login has not created any conversation storage yet.
        for name in [
            "sessions",
            "archived_sessions",
            "skills",
            "plugins",
            "prompts",
            "generated_images",
        ] {
            std::fs::create_dir_all(shared.join(name))?;
        }
        for entry in std::fs::read_dir(&shared)? {
            let entry = entry?;
            let name = entry.file_name();
            if matches!(
                name.to_str(),
                Some("auth.json" | "models_cache.json" | "log" | "memories" | "tmp")
            ) {
                continue;
            }
            link_shared(&entry.path(), &home.join(name))?;
        }
        // SQLite files can be created after home setup. Pin their directory,
        // rather than relying on links to whichever files already existed.
        link_shared(&shared, &home.join(".shared-state"))?;
        Ok(Some((id, home)))
    }

    pub(super) fn refreshed_codex_credentials(&self, slot: &Slot) -> Option<serde_json::Value> {
        if slot.harness != HarnessId::Codex || !valid_slot_id(&slot.id) {
            return None;
        }
        let auth = self.codex_slot_home(&slot.id).join("auth.json");
        let metadata = std::fs::symlink_metadata(&auth).ok()?;
        if !metadata.is_file() || metadata.file_type().is_symlink() {
            return None;
        }
        let detected = read_json(&auth).and_then(parse_codex_auth)?;
        (detected.account_key == slot.account_key).then_some(detected.credentials?)
    }

    /// A successful explicit re-login replaces the canonical credential too.
    pub(super) fn replace_codex_home_login(&self, detected: &Detected) -> Result<(), EngineError> {
        let home = self.codex_slot_home(&slot_id_for(HarnessId::Codex, &detected.account_key));
        if home.exists() {
            private_directory(&home)?;
            let credentials = detected
                .credentials
                .as_ref()
                .ok_or_else(|| EngineError::Other("Codex login has no credentials.".into()))?;
            write_file_atomic(
                &home.join("auth.json"),
                credentials.to_string().as_bytes(),
                true,
            )?;
        }
        Ok(())
    }
}

fn valid_slot_id(id: &str) -> bool {
    id.len() == 16
        && id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn private_directory(path: &Path) -> Result<(), EngineError> {
    std::fs::create_dir_all(path)?;
    let metadata = std::fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(EngineError::Other(
            "Codex account home must be a private directory.".into(),
        ));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

fn link_shared(source: &Path, destination: &Path) -> Result<(), EngineError> {
    match std::fs::symlink_metadata(destination) {
        Ok(metadata)
            if metadata.file_type().is_symlink() && std::fs::read_link(destination)? == source =>
        {
            return Ok(());
        }
        Ok(_) => {
            return Err(EngineError::Other(
                "Codex account home conflicts with shared state.".into(),
            ));
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e.into()),
    }
    #[cfg(unix)]
    std::os::unix::fs::symlink(source, destination)?;
    #[cfg(windows)]
    {
        if source.is_dir() {
            std::os::windows::fs::symlink_dir(source, destination)?;
        } else {
            std::os::windows::fs::symlink_file(source, destination)?;
        }
    }
    Ok(())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn fixture(root: &Path) -> AgentAccounts {
        AgentAccounts::new(AgentAccountsConfig {
            data_dir: root.join("engine"),
            codex_home: root.join("codex"),
            claude_config_dir: root.join("claude"),
            claude_config_file: root.join("claude.json"),
            cursor_sdk_auth_file: root.join("cursor/auth.json"),
            graff_home: root.join("graff"),
        })
    }

    fn login(account: &str, token: &str) -> Detected {
        let claims = serde_json::json!({
            "email": format!("{account}@example.com"),
            "https://api.openai.com/auth": { "chatgpt_account_id": account }
        });
        parse_codex_auth(serde_json::json!({"tokens": {
            "id_token": format!("fixture.{}.fixture", BASE64_URL.encode(claims.to_string())),
            "access_token": token, "refresh_token": format!("fixture-refresh-{token}")
        }}))
        .unwrap()
    }

    fn save(accounts: &AgentAccounts, login: &Detected) -> String {
        accounts.snapshot_detected(HarnessId::Codex, login).unwrap();
        slot_id_for(HarnessId::Codex, &login.account_key)
    }

    #[tokio::test]
    async fn concurrent_accounts_share_resume_storage_without_swapping_global_auth() {
        use std::os::unix::fs::PermissionsExt;
        let root = tempfile::tempdir().unwrap();
        let accounts = fixture(root.path());
        let a = login("account-a", "fixture-access-a");
        let b = login("account-b", "fixture-access-b");
        let a_id = save(&accounts, &a);
        let b_id = save(&accounts, &b);
        let shared = &accounts.inner.config.codex_home;
        std::fs::create_dir_all(shared).unwrap();
        let global = b.credentials.as_ref().unwrap().to_string();
        std::fs::write(shared.join("auth.json"), &global).unwrap();
        std::fs::write(shared.join("config.toml"), "model = 'fixture'\n").unwrap();
        let (a_home, b_home) = tokio::join!(
            accounts.codex_run_home(Some(&a_id)),
            accounts.codex_run_home(Some(&b_id))
        );
        let (_, a_home) = a_home.unwrap().unwrap();
        let (_, b_home) = b_home.unwrap().unwrap();
        assert_ne!(a_home, b_home);
        assert_eq!(read_json(&a_home.join("auth.json")), a.credentials);
        assert_eq!(read_json(&b_home.join("auth.json")), b.credentials);
        assert_eq!(
            std::fs::read_to_string(shared.join("auth.json")).unwrap(),
            global
        );
        std::fs::write(a_home.join("sessions/rollout.jsonl"), "fixture transcript").unwrap();
        assert_eq!(
            std::fs::read_to_string(b_home.join("sessions/rollout.jsonl")).unwrap(),
            "fixture transcript"
        );
        for name in ["sessions", "config.toml", "plugins", ".shared-state"] {
            assert_eq!(
                a_home.join(name).canonicalize().unwrap(),
                b_home.join(name).canonicalize().unwrap()
            );
        }
        assert_eq!(
            std::fs::metadata(&a_home).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            std::fs::metadata(a_home.join("auth.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        let option = accounts.codex_account_option().await.unwrap().unwrap();
        assert_eq!(option.default_choice, b_id);
        assert_eq!(option.choices.len(), 2);
        assert!(option.choices.iter().any(|c| c.id == a_id));
        assert!(
            !serde_json::to_string(&option)
                .unwrap()
                .contains("fixture-access")
        );
    }

    #[tokio::test]
    async fn native_token_refresh_survives_restart_activation_and_explicit_relogin() {
        let root = tempfile::tempdir().unwrap();
        let accounts = fixture(root.path());
        let id = save(&accounts, &login("account-a", "fixture-original"));
        let (_, home) = accounts.codex_run_home(Some(&id)).await.unwrap().unwrap();
        let refreshed = login("account-a", "fixture-refreshed");
        std::fs::write(
            home.join("auth.json"),
            refreshed.credentials.as_ref().unwrap().to_string(),
        )
        .unwrap();
        // A stale CLI snapshot must not replace the native process's refreshed token.
        save(&accounts, &login("account-a", "fixture-original"));
        let accounts = fixture(root.path());
        accounts.codex_run_home(Some(&id)).await.unwrap();
        assert_eq!(read_json(&home.join("auth.json")), refreshed.credentials);
        accounts.activate(HarnessId::Codex, &id).await.unwrap();
        assert_eq!(
            read_json(&accounts.inner.config.codex_auth_file()),
            refreshed.credentials
        );
        let relogin = login("account-a", "fixture-relogin");
        accounts.replace_codex_home_login(&relogin).unwrap();
        assert_eq!(read_json(&home.join("auth.json")), relogin.credentials);
    }

    #[tokio::test]
    async fn legacy_chat_pins_first_account_and_resumes_it_after_cli_switch() {
        use crate::workspace_host::{WorkspaceHost, WorkspaceHostConfig};
        use crate::{DocHost, DocHostConfig, HarnessRegistry, RunJournal, SessionsEngine};
        use harness_adapters::CodexHarness;
        use harness_proto::{RunRequest, SandboxLevel, SessionStatus};
        use harness_sync::DocsStore;
        let root = tempfile::tempdir().unwrap();
        let accounts = fixture(root.path());
        let a = save(&accounts, &login("account-a", "fixture-access-a"));
        let b = save(&accounts, &login("account-b", "fixture-access-b"));
        accounts.activate(HarnessId::Codex, &a).await.unwrap();
        let store = Arc::new(DocsStore::open(root.path().join("docs")).unwrap());
        let workspace = WorkspaceHost::open(
            store.clone(),
            WorkspaceHostConfig {
                device_id: "test-host".into(),
                device_name: "Test".into(),
                platform: "test".into(),
                org_id: "test-org".into(),
                user_id: "test-user".into(),
                edge: None,
            },
        )
        .unwrap();
        workspace
            .create_chat("legacy", None, Some("test-host"), None, None)
            .unwrap();
        let executable = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../harness/tests/fixtures/fake-codex.sh");
        let registry = Arc::new(HarnessRegistry::new());
        registry.register(Arc::new(CodexHarness::new().with_executable(executable)));
        let sessions = SessionsEngine::new(
            "test-host".into(),
            Arc::new(RunJournal::open(root.path().join("journals")).unwrap()),
            registry,
        );
        sessions.set_agent_accounts(accounts.clone());
        let docs = DocHost::new(
            store.clone(),
            DocHostConfig {
                device_id: "test-host".into(),
                default_harness: HarnessId::Codex,
                edge: None,
            },
        );
        docs.set_workspace(workspace.clone());
        sessions.set_doc_host(docs.clone());
        let request = RunRequest {
            prompt: "scenario:publication".into(),
            harness: None,
            model: None,
            reasoning: None,
            model_options: Default::default(),
            cwd: root.path().to_string_lossy().into_owned(),
            sandbox: SandboxLevel::WorkspaceWrite,
            auto_approve: true,
            attachments: vec![],
            worktree: None,
            resume: None,
        };
        for expected_resume in [false, true] {
            sessions
                .dispatch("legacy", HarnessId::Codex, request.clone(), None)
                .await
                .unwrap();
            tokio::time::timeout(Duration::from_secs(10), async {
                while sessions
                    .session_status("legacy")
                    .is_none_or(|s| s.status != SessionStatus::Idle)
                {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
            })
            .await
            .unwrap();
            let run = sessions.last_request("legacy").unwrap();
            assert_eq!(run.model_options[CODEX_ACCOUNT_OPTION], a);
            assert_eq!(run.resume.is_some(), expected_resume);
            assert_eq!(
                workspace.chat_config("legacy").unwrap().model_options[CODEX_ACCOUNT_OPTION],
                a
            );
            sessions.interrupt("legacy").await.unwrap();
            accounts.activate(HarnessId::Codex, &b).await.unwrap();
        }
        workspace.shutdown();
        docs.shutdown_workers().await;
        let reloaded = WorkspaceHost::open(
            store,
            WorkspaceHostConfig {
                device_id: "test-host".into(),
                device_name: "Test".into(),
                platform: "test".into(),
                org_id: "test-org".into(),
                user_id: "test-user".into(),
                edge: None,
            },
        )
        .unwrap();
        assert_eq!(
            reloaded.chat_config("legacy").unwrap().model_options[CODEX_ACCOUNT_OPTION],
            a
        );
        reloaded.shutdown();
    }

    #[tokio::test]
    async fn unavailable_and_corrupt_accounts_fail_closed_and_forget_preserves_rollouts() {
        let root = tempfile::tempdir().unwrap();
        let accounts = fixture(root.path());
        let id = save(&accounts, &login("account-a", "fixture-access"));
        let (_, home) = accounts.codex_run_home(Some(&id)).await.unwrap().unwrap();
        let auth = home.join("auth.json");
        assert!(accounts.codex_run_home(Some("../../escape")).await.is_err());
        assert!(
            accounts
                .codex_run_home(Some("0000000000000000"))
                .await
                .is_err()
        );
        std::fs::write(&auth, "invalid json").unwrap();
        assert!(accounts.codex_run_home(Some(&id)).await.is_err());
        std::fs::write(
            &auth,
            login("other-account", "fixture-wrong")
                .credentials
                .unwrap()
                .to_string(),
        )
        .unwrap();
        assert!(accounts.codex_run_home(Some(&id)).await.is_err());
        std::fs::remove_file(&auth).unwrap();
        std::os::unix::fs::symlink(root.path().join("outside.json"), &auth).unwrap();
        assert!(accounts.codex_run_home(Some(&id)).await.is_err());
        std::fs::write(home.join("sessions/keep.jsonl"), "keep").unwrap();
        accounts.forget(HarnessId::Codex, &id).await.unwrap();
        assert!(!home.exists());
        assert!(
            accounts
                .inner
                .config
                .codex_home
                .join("sessions/keep.jsonl")
                .exists()
        );
        assert!(accounts.codex_run_home(Some(&id)).await.is_err());
    }
}
