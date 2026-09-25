//! Resolve the published beta for the newest numeric Codegraff release branch.
//! A beta is selected by branch version and workflow run/attempt, never by
//! GitHub's stable `latest` pointer or by lexicographic tag order.

use serde::Deserialize;

const API: &str = "https://api.github.com/repos/justrach/codegraff";

#[derive(Deserialize)]
struct GitRef {
    #[serde(rename = "ref")]
    name: String,
}

#[derive(Deserialize)]
struct Release {
    tag_name: String,
    prerelease: bool,
    draft: bool,
    published_at: Option<String>,
}

pub(crate) fn numeric_version(text: &str) -> Option<[u64; 4]> {
    let mut version = [0; 4];
    let parts: Vec<_> = text.split('.').collect();
    if !(3..=4).contains(&parts.len()) {
        return None;
    }
    for (slot, part) in version.iter_mut().zip(parts) {
        *slot = part.parse().ok()?;
    }
    Some(version)
}

fn beta_run(tag: &str, branch: [u64; 4]) -> Option<(u64, u64)> {
    let (version, run) = tag.strip_prefix('v')?.split_once("-beta.")?;
    if numeric_version(version)? != branch {
        return None;
    }
    let (run, attempt) = run.split_once('.')?;
    Some((run.parse().ok()?, attempt.parse().ok()?))
}

pub(crate) fn beta_key(tag: &str) -> Option<([u64; 4], u64, u64)> {
    let version = tag.strip_prefix('v')?.split_once("-beta.")?.0;
    let branch = numeric_version(version)?;
    let (run, attempt) = beta_run(tag, branch)?;
    Some((branch, run, attempt))
}

fn latest_branch(refs: &[GitRef]) -> Option<[u64; 4]> {
    refs.iter()
        .filter_map(|branch| numeric_version(branch.name.strip_prefix("refs/heads/release/v")?))
        .max()
}

fn latest_published_beta(releases: &[Release], branch: [u64; 4]) -> Option<&str> {
    releases
        .iter()
        .filter(|release| release.prerelease && !release.draft && release.published_at.is_some())
        .filter_map(|release| {
            Some((
                beta_run(&release.tag_name, branch)?,
                release.tag_name.as_str(),
            ))
        })
        .max_by_key(|(run, _)| *run)
        .map(|(_, tag)| tag)
}

pub async fn latest_tag(client: &reqwest::Client) -> anyhow::Result<String> {
    let refs: Vec<GitRef> = client
        .get(format!("{API}/git/matching-refs/heads/release/v"))
        .header(reqwest::header::ACCEPT, "application/vnd.github+json")
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    let branch = latest_branch(&refs)
        .ok_or_else(|| anyhow::anyhow!("no numeric Codegraff release branch found"))?;
    let mut newest: Option<((u64, u64), String)> = None;
    let mut complete = false;
    for page in 1..=10 {
        let releases: Vec<Release> = client
            .get(format!("{API}/releases?per_page=100&page={page}"))
            .header(reqwest::header::ACCEPT, "application/vnd.github+json")
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        if let Some(tag) = latest_published_beta(&releases, branch) {
            let run = beta_run(tag, branch).expect("selected beta has a valid run");
            if newest.as_ref().is_none_or(|(previous, _)| run > *previous) {
                newest = Some((run, tag.to_string()));
            }
        }
        if releases.len() < 100 {
            complete = true;
            break;
        }
    }
    anyhow::ensure!(
        complete,
        "too many Codegraff releases to select a beta safely"
    );
    newest
        .map(|(_, tag)| tag)
        .ok_or_else(|| anyhow::anyhow!("the newest Codegraff release branch has no published beta"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn branch_and_beta_selection_are_numeric() {
        let branches = ["v0.0.302.9", "v0.0.302.10", "v0.0.303", "v0.0.303.0"]
            .into_iter()
            .map(|name| GitRef {
                name: format!("refs/heads/release/{name}"),
            })
            .collect::<Vec<_>>();
        let branch = latest_branch(&branches).unwrap();
        assert_eq!(branch, [0, 0, 303, 0]);
        let releases = [
            ("v0.0.303-beta.9.2", true, false, Some("now")),
            ("v0.0.303-beta.10.1", true, false, Some("now")),
            ("v0.0.303-beta.11.1", true, true, Some("now")),
            ("v0.0.303-beta.12.1", true, false, None),
            ("v0.0.302.10-beta.99.1", true, false, Some("now")),
        ]
        .into_iter()
        .map(|(tag_name, prerelease, draft, published_at)| Release {
            tag_name: tag_name.into(),
            prerelease,
            draft,
            published_at: published_at.map(str::to_string),
        })
        .collect::<Vec<_>>();
        assert_eq!(
            latest_published_beta(&releases, branch),
            Some("v0.0.303-beta.10.1")
        );
        assert_eq!(beta_run("v0.0.303-beta.10.1-extra", branch), None);
    }
}
