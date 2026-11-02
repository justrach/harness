//! Fixture-only provider data for native Accounts screenshots; no RPC or credentials.
use super::*;

impl AccountsPage {
    pub fn fixture_provider_snapshot(
        &mut self,
        fixture: &serde_json::Value,
        cx: &mut Context<Self>,
    ) -> anyhow::Result<()> {
        // Validate all inputs before changing the page. These are the same wire
        // replies used by the existing ui-scenes Accounts fixture.
        let snapshot: AgentAccountsSnapshot = serde_json::from_value(fixture["snapshot"].clone())?;
        let logins: Vec<GraffLoginProvider> =
            serde_json::from_value(fixture["graffLogins"].clone())?;
        let usage: Option<CodegraffUsage> =
            serde_json::from_value(fixture["codegraffUsage"].clone())?;
        let jobs: Option<CodegraffJobs> = serde_json::from_value(fixture["codegraffJobs"].clone())?;
        self.snapshot = Loadable::Ready(snapshot);
        self.graff_logins = Loadable::Ready(logins);
        self.codegraff_usage = Loadable::Ready(usage);
        self.codegraff_jobs = Loadable::Ready(jobs);
        self.error = None;
        self.fixture_provider_scroll(0., cx);
        Ok(())
    }

    /// Capture a section of the actual scrolling page, without a login action.
    pub fn fixture_provider_scroll(&mut self, y: f32, cx: &mut Context<Self>) {
        self.scroll
            .scroll
            .set_offset(gpui::point(px(0.), px(-y.max(0.))));
        cx.notify();
    }
}
