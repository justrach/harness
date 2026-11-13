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

This is deliberately **not** a complete GitHub repository PR browser, a
review editor or an issue board. It reuses the engine's existing `gh`
installation, authentication, bounded requests and watch cache. There is no
new token store, hidden authentication prompt or second network poller.

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
scripts/heavy-build.sh cargo test -p harness-engine --lib git_actions
scripts/heavy-build.sh cargo test -p harness-engine --test desktop_requests
scripts/heavy-build.sh sh -c 'cd apps/nano && zig build -Doptimize=ReleaseSafe -j2'
node scripts/test-nano-source-control-e2e.mjs
node scripts/test-nano-git-workflow-e2e.mjs
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
