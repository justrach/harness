# ADR 0004: Offer ACP registry agents without forking the adapter model

- Status: Proposed
- Date: 2026-09-25

## Context

Zed installs any agent listed in the public ACP registry from inside the editor (`https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json`). Each entry has an `id`, `name`, `version`, `description`, `icon`, and a `distribution`: an `npx` or `uvx` package with arguments, or per-platform `binary` archives with a `sha256`, a `cmd`, `args`, and `env`. Registry agents are CI-checked to return `authMethods` from the ACP handshake.

Harness already has most of the machinery. The generic ACP driver (`crates/harness/src/acp`) runs any ACP agent. `adapter_install` installs a pinned npm package once into the managed adapters directory, and `archive_install` installs a checksummed release archive. Adding Exo took one `AcpAgentSpec`, one `HarnessId` variant, a registry slot, an icon and a settings blurb.

What stops a registry agent from appearing without a release is identity. `HarnessId` is a `Copy` enum used in about 1,200 places. It is serialized as a kebab-case string in chat configs (`ChatConfig.harness`), agent accounts, `harness-prefs.json`, the sync wire, and RPC. The enum itself decodes strictly. Chat rows are read leniently (`lenient_chat_config`): an older desktop shows a chat with an unknown agent, but without its config. `harness-prefs.json` now skips unknown ids instead of resetting the whole file (since 2026-09-25). Older builds still lose the whole file. The iOS app stores agent ids as plain strings and tolerates new ones.

ADR 0003 decided that a new harness joins by adding an adapter in this repo.

## Options

**A. Generate built-in specs from the registry at build time.** A script reads `registry.json` and emits `AcpAgentSpec`s, `HarnessId` variants, icons and blurbs for the agents we choose to ship, pinned to the registry version. Every release picks up registry agents the same way Exo was added. No wire change beyond new ids. ADR 0003 stands. Cost: new agents wait for a Harness release.

**B. Runtime registry agents.** `HarnessId` grows a runtime-identified variant, for example `Acp(AgentKey)` with an interned key that keeps the type `Copy`. It serializes as `acp:<registry-id>`, and Settings → Agents gains an "Add from registry" list. Cost: ADR 0003 has to be amended, and older peers cannot decode `acp:*` ids, so B needs a prerequisite release (below) and a staged rollout.

**Prerequisite for B: lossless unknown ids.** Chat rows and prefs already survive unknown ids, but they drop the value: a row's config is hidden, and a prefs entry is skipped. B would need an unknown id to be preserved as `Unknown(raw)` and round-trip unchanged, so an older peer that edits a chat does not erase its registry agent.

## Recommendation

Do A now. It keeps ADR 0003, reuses the proven Exo path, and can be scripted from the registry file. `scripts/acp-registry-report.py` is the first step. It lists registry agents without an adapter, with their distributions, and flags adapter pins that trail the registry. On 2026-09-25 those were the Grok npm fallback (1.0.4 against 1.0.41, bumped after a live handshake check) and the Antigravity archive (1.1.1 against 1.2.1, bumped with SHA-512s streamed from all five pinned archives; the pre-sign-in handshake matched 1.1.1, cold start fell from 6.4 s to 3.3 s, and the unpacked size fell from 919 MB to 398 MB). The signed-in flow of 1.2.1 was not exercised. Revisit B only if people ask for agents between releases. When B lands, amend ADR 0003 to say that a registry agent is still an adapter: the generic ACP spec parameterized by a registry manifest, with no per-agent code in the shell.

## Candidate check (2026-09-25)

The two most prominent missing agents both passed a pre-sign-in handshake against Harness's `initialize` shape, run in a throwaway `HOME`:

| Agent | Launch | Init | Auth methods | Signed-out `session/new` |
| --- | --- | ---: | --- | --- |
| Gemini CLI 0.61.0 | `npx @google/gemini-cli --acp` | 0.8 s | oauth-personal, gemini-api-key, vertex-ai, gateway | "Gemini API key is missing or not configured." |
| GitHub Copilot CLI 1.0.88 | `npx @github/copilot --acp` | 2.8 s | copilot-login | "Authentication required" |

Both advertise `loadSession` and image prompts. Neither was added, because a real turn needs a signed-in account to verify. The sign-in path also matters: Harness only drives `authenticate` for Grok and Antigravity today.

## Consequences

- A: registry agents arrive with Harness releases and are off by default like every non-default agent. Pins and checksums come from the registry, and installs reuse `adapter_install` and `archive_install`.
- Lenient prefs decoding (done): a newer build's new agent ids no longer reset this build's agent preferences.
- B, if adopted: agents install without a release, at the cost of an identity migration across the desktop app, sync and RPC.
