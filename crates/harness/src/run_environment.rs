use crate::{RunOrigin, process};

/// Attribute build-wait markers only to the run explicitly owning this child.
/// Discovery, titles and callers without a directory must not inherit a parent
/// session's attribution when Harness itself was launched by an agent.
pub(crate) fn apply_run_environment(cmd: &mut process::Command, origin: Option<&RunOrigin>) {
    if let Some(dir) = origin.and_then(|origin| origin.build_wait_dir.as_ref()) {
        cmd.env("HARNESS_BUILD_WAIT_DIR", dir);
    } else {
        cmd.env_remove("HARNESS_BUILD_WAIT_DIR");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{OsStr, OsString};

    fn configured_directory(cmd: &mut process::Command) -> Option<Option<OsString>> {
        cmd.as_std_mut()
            .get_envs()
            .find(|(key, _)| *key == OsStr::new("HARNESS_BUILD_WAIT_DIR"))
            .map(|(_, value)| value.map(OsStr::to_os_string))
    }

    #[test]
    fn build_wait_environment_sets_the_current_runs_directory() {
        let origin = RunOrigin {
            build_wait_dir: Some(std::path::PathBuf::from("synthetic/current run")),
            ..Default::default()
        };
        let mut cmd = process::Command::new("synthetic-agent");
        cmd.env("HARNESS_BUILD_WAIT_DIR", "synthetic/other-run");
        apply_run_environment(&mut cmd, Some(&origin));
        assert_eq!(
            configured_directory(&mut cmd),
            Some(Some(OsString::from("synthetic/current run")))
        );
    }

    #[test]
    fn build_wait_environment_removes_inheritance_without_a_directory() {
        for origin in [None, Some(RunOrigin::default())] {
            let mut cmd = process::Command::new("synthetic-agent");
            cmd.env("HARNESS_BUILD_WAIT_DIR", "synthetic/other-run");
            apply_run_environment(&mut cmd, origin.as_ref());
            // An explicit removal, not merely an absent override: inherited
            // process environment must be scrubbed as well.
            assert_eq!(configured_directory(&mut cmd), Some(None));
        }
    }
}
