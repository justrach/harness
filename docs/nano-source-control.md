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

This first slice is read-only. It does not add stage, unstage, commit, push,
discard-file or branch-switch operations. Those need separately designed
checkout/index fences and explicit confirmation rather than arbitrary shell
commands passed from a view. Existing diff discard and PR merge flows keep
their current confirmations and host-side ownership checks.

History requests target the session's actual checkout and owning device.
Navigation and same-session checkout/branch changes cancel pending history
requests, clear old rows and reject late replies. Errors retain the last
successful page in the same checkout; Refresh retries explicitly. Raw Git
process output is never displayed by the new history view.

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
scripts/heavy-build.sh cargo test -p harness-engine --test desktop_requests
scripts/heavy-build.sh sh -c 'cd apps/nano && zig build -Doptimize=ReleaseSafe -j2'
node scripts/test-nano-source-control-e2e.mjs
```

The native tests use synthetic chats, host identities, commit pages and PRs,
exercise mounted controls, verify host routing and paging, reject delayed
responses after navigation, and ensure reads never dispatch mutation RPCs.
`NANO_GIT_SNAP_DIR` saves synthetic light/dark UI evidence. The end-to-end
fixture creates its own repository, engine, home and data directories; it
never reads the developer's application data or uses a GitHub account.
