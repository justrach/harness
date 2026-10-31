//! Reserved, live-only `WatchToolProgress` record for an explicitly confirmed
//! shared build-slot wait. This is not transcript content or an idle heuristic.

pub const BUILD_WAIT_TOOL_ID: &str = "harness:build-wait";

pub fn build_wait_item(since: i64) -> crate::ToolProgressItem {
    crate::ToolProgressItem {
        tool_id: BUILD_WAIT_TOOL_ID.into(),
        output: since.to_string(),
        state: Some("waiting".into()),
    }
}

/// Earliest valid start (Unix seconds) among reserved waiting records only.
pub fn build_wait_since(items: &[crate::ToolProgressItem]) -> Option<i64> {
    items
        .iter()
        .filter(|item| {
            item.tool_id == BUILD_WAIT_TOOL_ID && item.state.as_deref() == Some("waiting")
        })
        .filter_map(|item| item.output.parse::<i64>().ok().filter(|since| *since > 0))
        .min()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_wait_contract_selects_only_valid_reserved_waits() {
        let valid = build_wait_item(123);
        assert_eq!(valid.tool_id, BUILD_WAIT_TOOL_ID);
        assert_eq!(valid.output, "123");
        assert_eq!(valid.state.as_deref(), Some("waiting"));
        assert_eq!(build_wait_since(&[]), None);
        assert_eq!(
            build_wait_since(&[valid.clone(), build_wait_item(99)]),
            Some(99)
        );
        let mut invalid = vec![build_wait_item(0), build_wait_item(-1)];
        for output in ["", "abc", "1.5", " 123", "9223372036854775808"] {
            let mut item = valid.clone();
            item.output = output.into();
            invalid.push(item);
        }
        for state in [None, Some("running".into()), Some("acquired".into())] {
            let mut item = valid.clone();
            item.state = state;
            invalid.push(item);
        }
        let mut ordinary = valid.clone();
        ordinary.tool_id = "shell".into();
        invalid.push(ordinary);
        assert_eq!(build_wait_since(&invalid), None);
        invalid.push(valid);
        assert_eq!(build_wait_since(&invalid), Some(123));
    }
}
