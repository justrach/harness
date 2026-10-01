//! Splits a run with sub-agents into the parent's time and its children's,
//! so a trace answers whether delegating paid off. The columns match the
//! `subagent_split.py` report in graff's eval harness.

use serde::Serialize;

/// One child, from graff's per-child `subagent` line or, on traces written
/// before that line existed, from the child's own model requests.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct ChildRun {
    pub label: String,
    pub start_ms: u64,
    pub end_ms: u64,
    pub requests: u64,
    /// `None` when the trace predates the per-child line.
    pub ok: Option<bool>,
    pub tools: Option<u64>,
    pub effort: Option<String>,
}

impl ChildRun {
    pub fn ms(&self) -> u64 {
        self.end_ms.saturating_sub(self.start_ms)
    }
}

/// All times are milliseconds; `*_at_ms` values are offsets from the run start.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Delegation {
    pub children: Vec<ChildRun>,
    /// `subagent` calls made by the root agent.
    pub spawns: u64,
    pub first_spawn_at_ms: Option<u64>,
    /// First to last spawn: what spawning one child per model call costs.
    pub spawn_spread_ms: Option<u64>,
    /// First child start to last child finish.
    pub child_critical_ms: Option<u64>,
    pub slowest_child_ms: Option<u64>,
    /// Child time summed over the critical path; 1.0 means the children never overlapped.
    pub parallelism: Option<f64>,
    /// The root agent's own model time.
    pub parent_model_ms: u64,
    /// Time the root agent spent blocked in `agent_output`.
    pub parent_wait_ms: u64,
    /// Last child finish to the root's last request: integration and checks.
    pub tail_ms: Option<u64>,
}

pub(crate) fn split(
    spawns: &[u64],
    root_spans: &[(u64, u64)],
    children: Vec<ChildRun>,
    parent_wait_ms: u64,
) -> Delegation {
    let mut d = Delegation {
        spawns: spawns.len() as u64,
        parent_model_ms: root_spans.iter().map(|(a, b)| b.saturating_sub(*a)).sum(),
        parent_wait_ms,
        ..Default::default()
    };
    if let (Some(lo), Some(hi)) = (spawns.iter().min(), spawns.iter().max()) {
        d.first_spawn_at_ms = Some(*lo);
        d.spawn_spread_ms = Some(hi - lo);
    }
    let lo = children.iter().map(|c| c.start_ms).min();
    let hi = children.iter().map(|c| c.end_ms).max();
    if let (Some(lo), Some(hi)) = (lo, hi) {
        let critical = hi.saturating_sub(lo);
        let total: u64 = children.iter().map(ChildRun::ms).sum();
        let end = root_spans.iter().map(|s| s.1).max().unwrap_or(hi).max(hi);
        d.child_critical_ms = Some(critical);
        d.slowest_child_ms = children.iter().map(ChildRun::ms).max();
        d.parallelism = (critical > 0).then(|| total as f64 / critical as f64);
        d.tail_ms = Some(end - hi);
    }
    d.children = children;
    d
}

#[cfg(test)]
mod tests {
    use super::*;

    fn child(label: &str, start_ms: u64, end_ms: u64) -> ChildRun {
        ChildRun {
            label: label.into(),
            start_ms,
            end_ms,
            ..Default::default()
        }
    }

    #[test]
    fn three_children_two_overlapping() {
        let root = [(0, 10_000), (12_000, 14_000), (70_000, 80_000)];
        let kids = vec![
            child("a", 14_000, 54_000),
            child("b", 15_000, 40_000),
            child("c", 24_000, 61_000),
        ];
        let d = split(&[11_000, 13_000, 21_000], &root, kids, 30_000);
        assert_eq!(d.spawns, 3);
        assert_eq!(d.first_spawn_at_ms, Some(11_000));
        assert_eq!(d.spawn_spread_ms, Some(10_000));
        assert_eq!(d.child_critical_ms, Some(47_000));
        assert_eq!(d.slowest_child_ms, Some(40_000));
        let parallelism = d.parallelism.unwrap();
        assert!((parallelism - 102_000.0 / 47_000.0).abs() < 1e-9);
        assert_eq!(d.parent_model_ms, 22_000);
        assert_eq!(d.parent_wait_ms, 30_000);
        assert_eq!(d.tail_ms, Some(19_000));
    }

    #[test]
    fn no_children_leaves_the_split_empty() {
        let d = split(&[], &[(0, 500)], Vec::new(), 0);
        assert_eq!(d.parent_model_ms, 500);
        assert_eq!(
            (d.child_critical_ms, d.tail_ms, d.parallelism),
            (None, None, None)
        );
    }
}
