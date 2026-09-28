# Harness edge

The Cloudflare Worker behind `https://edge.codegraff.com`: sign-in, sync rooms,
the device relay, attachments, release downloads and agent rooms. See
`../ARCHITECTURE.md`, `../docs/chat2-sync.md`, `../docs/registry-sync.md` and
`../docs/agent-rooms.md`.

## Develop

```sh
npm ci
npm test                 # unit (Node) and runtime (workerd) tiers
npm run dev              # wrangler dev on :27640, dev auth (bearer = user id)
```

Agent rooms need PostgreSQL with the agent-room migrations applied. Point local
Hyperdrive at it with
`CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_HYPERDRIVE=postgresql://user:password@host:port/db`;
without it, dev auth falls back to an in-memory room store.

## Deploy

Production deploys from this directory:

```sh
npm run deploy
```

`scripts/deploy.sh` refuses when `edge/` has uncommitted changes, uploads the
source archive built from the committed tree to
`harness-releases/harness-edge-source-0.1.0.tar.gz` (what `GET /source` links
to), then runs `wrangler deploy`. It needs a Wrangler login for the account in
`wrangler.jsonc` and the `HARNESS_AUTH_SIGNING_KEY` Worker secret already set.
Check `GET /health` and `GET /source` afterwards. To roll back, run
`npx wrangler rollback <version-id>` and re-run the archive upload from that
version's commit.
