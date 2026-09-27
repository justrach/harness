# browse as Harness's browser

Agents Harness runs can use [browse](https://github.com/justrach/browse) with
the user's own sign-ins, through browse's Connected apps (protocol
`v1-p256-sig`, browse `docs/connected-apps.md`, justrach/browse#4). The code
is `crates/engine/src/browse_link/`; the Settings card is
`crates/ui/src/settings/browse_link.rs` (Settings › Accounts › browse).

## How it works

- **Pairing.** With browse running and Settings › Agent › Connected apps on,
  Connect sends Harness's public key to browse's `/pair`. Both apps show the
  same six digits; the user confirms in browse and picks what Harness may do.
  Harness pins browse's key. The private key is a login Keychain item on macOS
  (never a file), one per data directory; the pairing record
  (`browse-link.json`) holds no secret.
- **Runs.** Each run of an agent that takes HTTP MCP servers (graff, and ACP
  agents advertising `mcpCapabilities.http`) gets a `browse` server at a local
  relay on `127.0.0.1`, with a bearer token for that run only. Agents can't
  sign, so the relay signs each request, puts the run's page session on every
  `tools/call` (`_meta["browse/session"]`), and checks browse's signature on
  the answer. When the run ends the token stops working and the run's pages
  close (`/session/close`).
- **Refusals** come back to the model as tool errors it can read ("run_js
  needs the run-js scope"). A signed `unknown_client` (revoked in browse, or
  unused for 30 days) forgets the pairing and Settings says to connect again.
  An answer not signed by the pinned key is never believed.
- **Without browse** running and paired, runs get no browse server and use
  Harness's own browser pane as before.

## Testing

`cargo test -p harness-engine --lib browse_link` runs the wire format and a
full flow against a fake browse that checks every signature.

Against a real browse, in a test world so the user's profile is untouched:

```sh
cd ~/browse && S=com.codegraff.search.test.harness \
  && defaults write $S bench -bool true && defaults write $S welcomed -bool true \
  && defaults write $S connect.on -bool true \
  && open -n --env SEARCH_PROBE=harness build/browse.app
HARNESS_BROWSE_LIVE_WORLD=harness \
  cargo test -p harness-engine --lib live_browse_pairs -- --ignored --nocapture
```

The live test pairs (approving with browse's `bench ... ui connect yes`),
opens and reads a page through the relay, checks a refused scope, and closes
the run's pages. To point a whole Harness build at a test world, set
`HARNESS_BROWSE_CONNECT` to that world's `Agent/connect.json`.
