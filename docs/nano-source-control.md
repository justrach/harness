# Native source-control surfaces

Open a session, open a surface panel's New tab picker, and select **Git
history** or **GitHub**. These are native Harness views, inspired by Zeron's
Git/GitHub integrations—not installed plugins or a port of its Luau host.
No interpreter, plugin loader, new process launcher or dependency is added.

## Git history

History comes from the existing host-routed `ListGitHistory` service, 50
commits per page. It shows subjects, author/date, abbreviated SHA, HEAD,
branch/tag labels, merge commits and local ahead/behind counts. Its rail is
a chronological list, not a branch topology graph. Previous/Next page and
Refresh are explicit; an idle panel does not poll or fetch remotes.
**Changes** opens the existing live working-tree/branch/turn diff surface.

**Staging** opens the native Git changes workflow described below. History
itself remains read-only. Existing diff discard and PR merge flows keep their
current confirmations and host-side ownership checks.

History requests target the session's actual checkout and owning device.
Navigation and same-session checkout/branch changes cancel pending history
requests, clear old rows and reject late replies. Errors retain the last
successful page in the same checkout; Refresh retries explicitly. Raw Git
process output is never displayed by the new history view.

## Staging, commit and push

From **Git history → Staging**, inspect the separately listed staged and
unstaged files. A partly staged file appears in both sections. **Stage** adds
only that file's current contents to the index; **Unstage** removes only that
file from the index and preserves its working contents. There is no automatic
stage-all, destructive per-file discard, or arbitrary shell command field.

Enter a commit message and select **Commit staged…**, then confirm the staged
file count and message. Only the index is committed. Git uses the user's
configured identity and normal hooks; the app does not add an attribution or
bypass a failing hook. The message is cleared only after a successful reply.

**Push…** shows the branch, existing upstream remote/branch and exact HEAD
before **Confirm push**. It publishes committed history, not unstaged files.
This first write slice requires an already configured upstream: it never
guesses a remote, publishes a new branch automatically, or force-pushes.
Set the upstream in a terminal when one is missing. Authentication, hook or
non-fast-forward failures require attention outside this view; no raw Git
stderr or credential-bearing URL is shown here.

The UI sends typed `GetCheckoutGitState` and `ApplyCheckoutGitAction` requests
to the session's owning device. Mutations carry checkout and snapshot fences;
stale requests are rejected rather than acting on a different checkout or
index. The host also rejects mutations while an agent in the same checkout is
working or awaiting input. A confirmation never survives a chat/checkout
change. Pending actions disable repeat submissions; errors require an
explicit Refresh to inspect the actual state before retrying. Closing the
view cancels its reply subscription, not an already started host action.

Snapshots cover HEAD, index bytes/staged blobs, changed-file bytes/modes and
effective Git configuration. Renames are represented as an explicit deletion
and addition. The host bounds snapshots to 1,000 changed files, 8 MiB per
file and 32 MiB of changed content; unsupported/special files, symlinks,
changed submodules and non-UTF-8 paths require a terminal. This first mutation
implementation supports Unix hosts; Windows fails closed instead of falling
back to unsafe filesystem traversal. The UI commit field is limited to
4 KiB. Local engine actions share a checkout gate with discard RPCs, but
external Git commands/filesystem writers are not transactionally locked out.
A push pins the confirmed SHA, even if another writer advances HEAD after the
last snapshot check.

## GitHub

The **Session pull requests** view gathers the existing watched PR summaries
for sessions in the selected repository on the same device. Shared branches
are deduplicated, and the selected session wins. It shows state, title,
source/base branch and shared-checkout provenance. Open on GitHub launches
the PR URL; Open session switches to its conversation. Merge is offered only
for the selected session through the existing confirm-then-merge flow.

Select **Repository** to browse beyond session-linked PRs. The native
repository browser shows paged **Pull requests** and **Issues** with
**Open / Closed / All** filters. It uses the selected session's real checkout
and owning device to resolve a GitHub remote, and shows the resulting
`owner/repository` explicitly. Existing upstream/branch remote selection rules
apply; the result is repository-wide, not filtered to the session's branch.

Open a PR for **Summary**, **Code** and **Activity**. Code lists paged files
with status/addition/deletion counts and one expandable patch at a time.
Missing/binary/clipped patches are clearly marked incomplete. Activity shows
paged GitHub timeline entries, comments and review summaries; it is not an
inline review-thread editor. Issues have their own description and activity.
Remote text is rendered as plain native text: no HTML, remote image loading
or executable provider links. **Open on GitHub** constructs a validated
canonical URL for the selected item.

The browser reuses the host's installed/authenticated `gh`, bounded process
runner and remote resolution; no token store or hidden sign-in is added.
All new API calls are GET-only and occur on explicit navigation/refresh, not
a new polling loop. Repo keys fence subsequent pages/details; the host
rechecks checkout/repository identity after a provider request. Chat,
checkout/branch changes and panel closure cancel subscriptions and reject
late replies. Refresh starts a fresh repository listing.

This slice supports `github.com` repositories on a branch; enterprise hosts
and detached HEAD require a browser/terminal. It does not create PRs/issues,
post comments/reviews, merge unrelated repository PRs, switch branches or
check out PR code. Existing selected-session merge confirmation is unchanged.
Provider pages are capped at 30 entries, descriptions/patches at 16 KiB and
event bodies at 8 KiB. GitHub may itself omit large diffs; clipping/omission
is labelled rather than presenting a partial patch as complete.

## NanoUI contribution boundary

The reusable piece is a domain-neutral, stateless timeline row in
`nanoui.kit`: connector rail and marker geometry, with ordinary native text
and controls supplied by the caller. Git parsing, GitHub state, host routing,
merge authorization and repository ownership remain in Harness. The component
is proposed upstream in [NanoUI PR #177](https://github.com/justrach/nanoui/pull/177);
only its implementation and exports are cherry-picked into Harness's vendor
package, with provenance recorded there.

## Verification

```sh
scripts/heavy-build.sh sh -c 'cd apps/nano && zig build test -Dtest-filter="native git" -j2'
scripts/heavy-build.sh sh -c 'cd apps/nano && zig build vectors -j2'
scripts/heavy-build.sh sh -c 'cd apps/nano && zig build test -Dtest-filter="repository github" -j2'
scripts/heavy-build.sh cargo test -p harness-engine --lib github_repository
scripts/heavy-build.sh cargo test -p harness-engine --lib git_actions
scripts/heavy-build.sh cargo test -p harness-engine --test desktop_requests
scripts/heavy-build.sh sh -c 'cd apps/nano && zig build -Doptimize=ReleaseSafe -j2'
node scripts/test-nano-source-control-e2e.mjs
node scripts/test-nano-git-workflow-e2e.mjs
node scripts/test-nano-github-repository-e2e.mjs
```

The native tests use synthetic chats, host identities, commit pages and PRs,
exercise mounted controls, verify host routing and paging, reject delayed
responses after navigation, and ensure reads never dispatch mutation RPCs.
`NANO_GIT_SNAP_DIR` saves synthetic light/dark history evidence;
`NANO_GIT_WORKFLOW_SNAP_DIR` saves staging/confirmation evidence. Workflow
regressions check per-file requests, confirmations, busy/error guards, host
routing, teardown and rejection of delayed replies. The end-to-end
fixture creates its own repository, engine, home and data directories; it
never reads the developer's application data or uses a GitHub account.
`NANO_GITHUB_REPO_SNAP_DIR` captures repository browser fixtures. Its
end-to-end runner uses a fake `gh` executable, a synthetic Git remote and
loopback-only sandboxing, so UI/engine integration never contacts GitHub.
