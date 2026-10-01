//! Totals across runs: where time and money went, which tools fail, how
//! often Jev is asked, and how much of the work children carry.

use std::collections::BTreeMap;

use serde::Serialize;

use crate::summary::{Observer, Percentiles, Tokens, ToolStat};

#[derive(Debug, Clone, Default, Serialize)]
pub struct Stats {
    pub runs: u64,
    pub turns: u64,
    pub requests: u64,
    pub cost_usd: f64,
    pub tokens: Tokens,
    pub cache_hit: Option<f64>,
    /// Most runs first.
    pub models: Vec<ModelStats>,
    /// The root agent's effort at the end of each turn.
    pub turn_efforts: Vec<Count>,
    /// Most calls first.
    pub tools: Vec<ToolStat>,
    pub jev: JevStats,
    pub delegation: DelegationStats,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct ModelStats {
    pub model: String,
    pub runs: u64,
    pub turns: u64,
    pub requests: u64,
    pub cost_usd: f64,
    /// The root agent's requests on this model.
    pub ttft_ms: Percentiles,
    pub request_ms: Percentiles,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Count {
    pub name: String,
    pub n: u64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
pub struct JevStats {
    /// Runs on a route graff offers `jev_effort` on.
    pub eligible_runs: u64,
    pub eligible_turns: u64,
    pub runs_with_calls: u64,
    pub calls: u64,
    pub child_calls: u64,
    pub errors: u64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
pub struct DelegationStats {
    pub runs_with_children: u64,
    pub children: u64,
    pub failed_children: u64,
    /// Children's own time, summed.
    pub child_ms: u64,
    /// Each run's first child start to last child finish, summed.
    pub child_critical_ms: u64,
    pub parent_wait_ms: u64,
}

#[derive(Default)]
pub struct StatsBuilder {
    stats: Stats,
    models: BTreeMap<String, ModelAcc>,
    efforts: BTreeMap<String, u64>,
    tools: BTreeMap<String, ToolStat>,
}

#[derive(Default)]
struct ModelAcc {
    runs: u64,
    turns: u64,
    requests: u64,
    cost_usd: f64,
    ttft_ms: Vec<u64>,
    request_ms: Vec<u64>,
}

impl StatsBuilder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn add(&mut self, run: &Observer) {
        let s = run.summary();
        let st = &mut self.stats;
        let requests = s.requests.root + s.requests.children + s.requests.helpers;
        st.runs += 1;
        st.turns += s.turns;
        st.requests += requests;
        st.cost_usd += s.cost_usd;
        st.tokens.add(&s.tokens);

        let model = if s.model.is_empty() {
            "(unknown)".to_string()
        } else {
            s.model.clone()
        };
        let m = self.models.entry(model).or_default();
        m.runs += 1;
        m.turns += s.turns;
        m.requests += requests;
        m.cost_usd += s.cost_usd;
        m.ttft_ms.extend(&run.root_ttft_ms);
        m.request_ms.extend(&run.root_request_ms);

        for effort in &run.turn_efforts {
            *self.efforts.entry(effort.clone()).or_default() += 1;
        }
        for tool in &s.tools.by_name {
            let t = self
                .tools
                .entry(tool.name.clone())
                .or_insert_with(|| ToolStat {
                    name: tool.name.clone(),
                    ..Default::default()
                });
            t.calls += tool.calls;
            t.errors += tool.errors;
            t.ms += tool.ms;
        }

        let jev = &mut st.jev;
        if s.jev.eligible_model {
            jev.eligible_runs += 1;
            jev.eligible_turns += s.turns;
        }
        jev.runs_with_calls += u64::from(s.jev.calls > 0);
        jev.calls += s.jev.calls;
        jev.child_calls += s.jev.child_calls;
        jev.errors += s.jev.errors;

        let d = &s.delegation;
        let del = &mut st.delegation;
        del.runs_with_children += u64::from(!d.children.is_empty());
        del.children += d.children.len() as u64;
        del.failed_children += d.children.iter().filter(|c| c.ok == Some(false)).count() as u64;
        del.child_ms += d.children.iter().map(|c| c.ms()).sum::<u64>();
        del.child_critical_ms += d.child_critical_ms.unwrap_or(0);
        del.parent_wait_ms += d.parent_wait_ms;
    }

    pub fn finish(self) -> Stats {
        let mut stats = self.stats;
        stats.cache_hit = stats.tokens.cache_hit();
        stats.models = self
            .models
            .into_iter()
            .map(|(model, m)| ModelStats {
                model,
                runs: m.runs,
                turns: m.turns,
                requests: m.requests,
                cost_usd: m.cost_usd,
                ttft_ms: Percentiles::of(&m.ttft_ms),
                request_ms: Percentiles::of(&m.request_ms),
            })
            .collect();
        stats
            .models
            .sort_by(|a, b| b.runs.cmp(&a.runs).then_with(|| a.model.cmp(&b.model)));
        stats.turn_efforts = self
            .efforts
            .into_iter()
            .map(|(name, n)| Count { name, n })
            .collect();
        stats
            .turn_efforts
            .sort_by(|a, b| b.n.cmp(&a.n).then_with(|| a.name.cmp(&b.name)));
        stats.tools = self.tools.into_values().collect();
        stats
            .tools
            .sort_by(|a, b| b.calls.cmp(&a.calls).then_with(|| a.name.cmp(&b.name)));
        stats
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::summary::tests::RUN;

    #[test]
    fn totals_two_runs() {
        let mut first = Observer::new();
        let mut second = Observer::new();
        for line in RUN.lines() {
            first.push_line(line);
            second.push_line(line);
        }
        let mut builder = StatsBuilder::new();
        builder.add(&first);
        builder.add(&second);
        let stats = builder.finish();
        assert_eq!((stats.runs, stats.turns, stats.requests), (2, 4, 10));
        assert!((stats.cost_usd - 0.084).abs() < 1e-9);
        assert_eq!(stats.models.len(), 1);
        assert_eq!(stats.models[0].ttft_ms.n, 2);
        assert_eq!(
            stats.turn_efforts,
            [Count {
                name: "high".into(),
                n: 4
            }]
        );
        assert_eq!(stats.tools[0].name, "jev_effort");
        assert_eq!(stats.tools[0].calls, 4);
        assert_eq!(
            stats.jev,
            JevStats {
                eligible_runs: 2,
                eligible_turns: 4,
                runs_with_calls: 2,
                calls: 4,
                child_calls: 2,
                errors: 0
            }
        );
        assert_eq!(stats.delegation.children, 4);
        assert_eq!(stats.delegation.failed_children, 2);
        assert_eq!(stats.delegation.child_ms, 44_000);
    }
}
