//! "Sign in with Codegraff" in the account menu. The engine owns the device
//! flow (`harness_engine::codegraff_auth`, shared with `graff login`); this
//! side starts it, opens the approval page, and polls the status until the
//! key lands.

use super::*;

/// How often, and for how long, a pending browser sign-in is polled (the
/// gateway's device codes live ten minutes).
const POLL_EVERY: std::time::Duration = std::time::Duration::from_millis(1500);
const POLL_FOR: std::time::Duration = std::time::Duration::from_secs(600);

#[derive(Debug, Clone, Default, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub(super) struct CodegraffStatus {
    pub configured: bool,
    pub signed_in: bool,
    pub email: Option<String>,
    pub name: Option<String>,
    pub pending: bool,
    pub error: Option<String>,
}

impl Shell {
    /// A cloud sidebar click lands on that computer's existing Accounts row.
    /// This is navigation only: no Start, Stop or Delete action is dispatched.
    pub(super) fn open_cloud_computer_settings(
        &mut self,
        sandbox_id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.open_settings_search_result(SettingsSection::Agents, cx);
        self.ensure_settings_search(cx).focus_pending = false;
        if self.accounts_page.is_none() {
            let state = self.state.clone();
            self.accounts_page = Some(cx.new(|cx| AccountsPage::new(state, cx)));
        }
        if let Some(page) = self.accounts_page.clone() {
            page.update(cx, |page, cx| {
                page.reveal_cloud_computer(sandbox_id, window, cx)
            });
        }
        cx.notify();
    }

    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_cloud_settings_selected(&self, cx: &App) -> Option<String> {
        if !matches!(self.route, Route::Settings(SettingsSection::Agents)) {
            return None;
        }
        self.accounts_page
            .as_ref()?
            .read(cx)
            .fixture_revealed_cloud_computer()
            .map(str::to_owned)
    }

    /// Re-read the sign-in state (menu open, after a flow finishes).
    pub(super) fn refresh_codegraff_status(&mut self, cx: &mut Context<Self>) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        self.codegraff_status_task = Some(cx.spawn(async move |this, cx| {
            let result = engine
                .client()
                .call(methods::CODEGRAFF_AUTH_STATUS, serde_json::json!({}))
                .await;
            if let Ok(value) = result
                && let Ok(status) = serde_json::from_value::<CodegraffStatus>(value)
            {
                this.update(cx, |shell, cx| {
                    if shell.codegraff != Some(status.clone()) {
                        shell.codegraff = Some(status);
                        cx.notify();
                    }
                })
                .ok();
            }
        }));
    }

    fn codegraff_sign_in(&mut self, cx: &mut Context<Self>) {
        self.close_user_menu(cx);
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        self.codegraff_flow = Some(cx.spawn(async move |this, cx| {
            let started = engine
                .client()
                .call(methods::CODEGRAFF_SIGN_IN, serde_json::json!({}))
                .await;
            let url = match started {
                Ok(value) => value.get("url").and_then(|u| u.as_str()).map(str::to_owned),
                Err(error) => {
                    this.update(cx, |shell, cx| {
                        shell.sidebar_notice = Some(format!("Codegraff sign-in: {error}").into());
                        cx.notify();
                    })
                    .ok();
                    return;
                }
            };
            let Some(url) = url else { return };
            this.update(cx, |shell, cx| {
                cx.open_url(&url);
                shell.codegraff = Some(CodegraffStatus {
                    pending: true,
                    ..shell.codegraff.clone().unwrap_or_default()
                });
                cx.notify();
            })
            .ok();
            // Poll until the browser round trip settles (or we give up).
            let deadline = std::time::Instant::now() + POLL_FOR;
            while std::time::Instant::now() < deadline {
                cx.background_executor().timer(POLL_EVERY).await;
                let Ok(value) = engine
                    .client()
                    .call(methods::CODEGRAFF_AUTH_STATUS, serde_json::json!({}))
                    .await
                else {
                    continue;
                };
                let Ok(status) = serde_json::from_value::<CodegraffStatus>(value) else {
                    continue;
                };
                let settled = !status.pending;
                this.update(cx, |shell, cx| {
                    if settled && let Some(error) = status.error.clone() {
                        shell.sidebar_notice = Some(format!("Codegraff sign-in failed: {error}").into());
                    }
                    if settled && status.signed_in {
                        // The account may already have a sandbox running.
                        shell
                            .state
                            .update(cx, |state, cx| state.refresh_cloud_sandboxes(cx));
                    }
                    shell.codegraff = Some(status);
                    cx.notify();
                })
                .ok();
                if settled {
                    break;
                }
            }
        }));
    }

    /// Account-menu rows: who you're signed in as, or the way in.
    pub(super) fn render_codegraff_menu_rows(&mut self, theme: &Theme, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let status = self.codegraff.clone().unwrap_or_default();
        let mut rows = Vec::new();
        if status.signed_in {
            let who = status
                .email
                .clone()
                .or(status.name.clone())
                .unwrap_or_else(|| "Signed in".into());
            // One "Sign out" in this menu (Harness's own): the Codegraff sign-in is managed in
            // Settings → Accounts, beside its usage and cloud sandboxes.
            rows.push(
                popover::menu_row(theme, false, "user-menu-codegraff-account")
                    .id("user-menu-codegraff-account")
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.close_user_menu(cx);
                        this.open_settings(SettingsSection::Agents, cx);
                    }))
                    .child(icon(icons::GLOBAL).size(px(16.0)).text_color(theme.accent))
                    .child(
                        div()
                            .min_w_0()
                            .truncate()
                            .child(SharedString::from(format!("Codegraff · {who}"))),
                    )
                    .into_any_element(),
            );
        } else if status.pending {
            rows.push(
                popover::menu_row(theme, false, "user-menu-codegraff-pending")
                    .id("user-menu-codegraff-pending")
                    .opacity(0.7)
                    .on_click(cx.listener(|this, _, _, cx| this.codegraff_sign_in(cx)))
                    .child(icon(icons::GLOBAL).size(px(16.0)).text_color(theme.text_muted))
                    .child(SharedString::from("Waiting for browser… (click to reopen)"))
                    .into_any_element(),
            );
        } else {
            rows.push(
                popover::menu_row(theme, false, "user-menu-codegraff-signin")
                    .id("user-menu-codegraff-signin")
                    .on_click(cx.listener(|this, _, _, cx| this.codegraff_sign_in(cx)))
                    .child(icon(icons::GLOBAL).size(px(16.0)).text_color(theme.text_muted))
                    .child(SharedString::from("Sign in with Codegraff"))
                    .into_any_element(),
            );
        }
        rows
    }
}
