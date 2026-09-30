package harness.codegraff.android.demo

import harness.codegraff.android.model.AgentDescriptor
import harness.codegraff.android.model.ChangeRequestState
import harness.codegraff.android.model.ChangeRequestSummary
import harness.codegraff.android.model.Chat
import harness.codegraff.android.model.ChatConfig
import harness.codegraff.android.model.DeviceRow
import harness.codegraff.android.model.MessageEntry
import harness.codegraff.android.model.MessagePart
import harness.codegraff.android.model.MessageRole
import harness.codegraff.android.model.MessageStatus
import harness.codegraff.android.model.RenderToolCall
import harness.codegraff.android.model.RepoRef
import harness.codegraff.android.model.SessionRow
import harness.codegraff.android.model.SessionStatus
import harness.codegraff.android.model.Space
import harness.codegraff.android.model.UserInputQuestion

data class FolderEntry(val name: String, val isDir: Boolean, val isRepo: Boolean)

data class FolderListing(val path: String, val parent: String?, val entries: List<FolderEntry>, val truncated: Boolean)

/**
 * Offline demo dataset (DemoDataset.swift): realistic spaces, sessions and transcripts so the
 * app can be explored, and screenshotted, with no edge deployment. The same fixtures the iOS
 * `-demo` mode shows.
 */
class DemoDataset(
    val devices: List<DeviceRow>,
    val spaces: List<Space>,
    val chats: List<Chat>,
    val sessions: Map<String, SessionRow>,
    val changeRequests: Map<String, ChangeRequestSummary>,
    val entries: Map<String, List<MessageEntry>>,
    /** What each computer reports in `ListHarnesses`, by device id (onboarding). */
    val agents: Map<String, List<AgentDescriptor>> = emptyMap(),
) {
    companion object {
        /** The three onboarding agents, all found and on. */
        private val allAgentsReady = listOf(AgentDescriptor("graff"), AgentDescriptor("claude-code"), AgentDescriptor("codex"))

        /**
         * A signed-in account with nothing in it yet, for the "Bring in your agent" screen (intent extra `scenario`:
         * `onboarding-nocomputer`, `onboarding-noagent`, `onboarding-ready`).
         */
        fun onboarding(now: Long, computerOnline: Boolean, agentReady: Boolean): DemoDataset {
            val mac = DeviceRow("dev-mac", "MacBook Pro", "macos", if (computerOnline) now else now - DAY, now - 2 * DAY)
            // One agent of each unready kind: Graff not found, Claude Code installable, OpenAI Codex found but off.
            val agents = if (agentReady) allAgentsReady else listOf(
                AgentDescriptor("claude-code", installed = false, canInstall = true),
                AgentDescriptor("codex", installed = true, enabled = false),
            )
            return DemoDataset(listOf(mac), emptyList(), emptyList(), emptyMap(), emptyMap(), emptyMap(), mapOf(mac.id to agents))
        }

        /**
         * One session that runs on the ChatGPT plan and hit the plan's usage limit, for the plan indicator and the limit
         * card (intent extra `scenario` = `chatgpt-plan`).
         */
        fun chatGPTPlan(now: Long): DemoDataset {
            val mac = DeviceRow("dev-mac", "MacBook Pro", "macos", now, now - 30 * DAY)
            val space = Space("space-harness", mac.id, "/Users/dev/harness", null, true, now - 9 * DAY)
            val chat = Chat(
                "chat-plan", mac.id, "Plan session", false, space.path, "main",
                ChatConfig("graff", "chatgpt/gpt-6.1-sol", null, sandbox = "workspace-write"),
                "Usage limit reached", now - MIN, now - 60 * MIN, space.id, now,
            )
            val entries = mapOf(
                chat.id to listOf(
                    user("m1", "Summarize what changed in the last release.", now - 70_000),
                    assistant("m2", listOf(MessagePart.Error("e0", "HTTP 429 subscription_sharing_usage_limit_exceeded: manage usage at https://chatgpt.com/settings/usage")), now - 60_000, "dev-mac"),
                ),
            )
            return DemoDataset(listOf(mac), listOf(space), listOf(chat), emptyMap(), emptyMap(), entries, mapOf(mac.id to allAgentsReady))
        }

        private const val MIN = 60_000L
        private const val DAY = 86_400_000L

        /** A fake filesystem for the folder browser demo. */
        val fileTree: Map<String, List<String>> = mapOf(
            "/Users/dev" to listOf("Documents", "Downloads", "Projects", "scratch"),
            "/Users/dev/Documents" to listOf("notes", "specs"),
            "/Users/dev/Projects" to listOf("harness", "dotfiles", "blog", "playground"),
            "/Users/dev/Projects/harness" to listOf("apps", "crates", "docs", "edge"),
            "/Users/dev/Projects/blog" to listOf("content", "public"),
            "/srv" to listOf("deploys", "backups"),
            "/srv/deploys" to listOf("edge", "landing"),
        )

        private val repoNames = setOf("harness", "dotfiles", "blog", "playground", "edge", "landing")

        fun homePath(deviceId: String): String = if (deviceId == "dev-vps") "/srv" else "/Users/dev"

        /** The engine's ListFolders answer, from the fake filesystem: folders only, git repos badged. */
        fun listFolders(deviceId: String, path: String?): FolderListing {
            val resolved = (path ?: homePath(deviceId)).trimEnd('/').ifEmpty { "/" }
            val parent = if (resolved == "/") null else resolved.substringBeforeLast('/').ifEmpty { "/" }
            val entries = fileTree[resolved].orEmpty().map { FolderEntry(it, true, it in repoNames) }
            return FolderListing(resolved, parent, entries, truncated = false)
        }

        fun listRefs(spacePath: String): List<RepoRef> =
            if ("harness" in spacePath) {
                listOf(
                    RepoRef("main", true, null),
                    RepoRef("veil-fade", false, "/Users/dev/.harness/worktrees/harness-veil-fade"),
                    RepoRef("feature/diff-pane", false, null),
                    RepoRef("fix/tool-colors", false, null),
                )
            } else {
                listOf(RepoRef("main", true, null), RepoRef("staging", false, null))
            }

        fun standard(now: Long): DemoDataset {
            val mac = DeviceRow("dev-mac", "MacBook Pro", "macos", now, now - 30 * DAY)
            val vps = DeviceRow("dev-vps", "Codegraff Cloud", "linux", now - 10 * MIN, now - 12 * DAY)
            val harness = Space("space-harness", mac.id, "/Users/dev/harness", null, true, now - 9 * DAY)
            val edge = Space("space-edge", vps.id, "/srv/deploys/edge", null, true, now - 4 * DAY)

            val claude = ChatConfig("claude-code", "claude-fable-5", "xhigh", sandbox = "workspace-write")
            val codex = ChatConfig("codex", "gpt-5.6-terra", "high", sandbox = "workspace-write")

            val chats = listOf(
                Chat("chat-veil", mac.id, "Streaming veil on transcript rows", false,
                    "/Users/dev/.harness/worktrees/harness-veil-fade", "veil-fade", claude,
                    "Porting the paint-only fade…", now - 40_000, now - 60 * MIN, harness.id, now),
                Chat("chat-picker", mac.id, "Model picker catalog sync", false, harness.path, "main", claude,
                    "Which device owns the catalog?", now - 2 * MIN, now - 120 * MIN, harness.id, now - 130_000),
                Chat("chat-tabs", mac.id, "Tool group header colors", false, harness.path, "main", codex,
                    "Done — failed children stay quiet.", now - 15 * MIN, now - DAY, harness.id, now - 60 * MIN),
                Chat("chat-deploy", vps.id, "Wrangler deploy hygiene", false, edge.path, null, claude,
                    "Hibernation-safe flush timer", now - DAY, now - 2 * DAY, edge.id, now - DAY),
                // Archived: populate the shelf under the active list.
                Chat("chat-oklch", mac.id, "OKLCH conversion drift", true, harness.path, "main", claude,
                    "Gamma encode matches now.", now - 3 * DAY, now - 4 * DAY, harness.id, now - 3 * DAY),
                Chat("chat-presence", vps.id, "Presence beat coalescing", true, edge.path, null, codex,
                    "Batched to one beat per 25s.", now - 6 * DAY, now - 7 * DAY, edge.id, now - 6 * DAY),
            )
            val sessions = mapOf(
                "chat-veil" to SessionRow("chat-veil", mac.id, SessionStatus.Working, now - 95_000, now - 5_000),
                "chat-picker" to SessionRow("chat-picker", mac.id, SessionStatus.AwaitingInput, now - 400_000, now - 10_000),
            )
            val changeRequests = mapOf(
                "chat-veil" to ChangeRequestSummary(
                    "github", 90, "Stream pull request status on every client",
                    "https://github.com/harness-sh/harness/pull/90", ChangeRequestState.Open, "main", "veil-fade",
                ),
                "chat-picker" to ChangeRequestSummary(
                    "github", 84, "Synchronize model catalogs",
                    "https://github.com/harness-sh/harness/pull/84", ChangeRequestState.Merged, "main", "main",
                ),
                "chat-tabs" to ChangeRequestSummary(
                    "github", 77, "Refine tool group colors",
                    "https://github.com/harness-sh/harness/pull/77", ChangeRequestState.Closed, "main", "main",
                ),
            )
            return DemoDataset(
                listOf(mac, vps), listOf(harness, edge), chats, sessions, changeRequests, transcripts(now),
                agents = mapOf(mac.id to allAgentsReady, vps.id to listOf(AgentDescriptor("graff"))),
            )
        }

        private fun user(id: String, text: String, at: Long) = MessageEntry(
            id, MessageRole.User, listOf(MessagePart.Text("t0", text)), at, "ios-demo", MessageStatus.Complete,
        )

        private fun assistant(id: String, parts: List<MessagePart>, at: Long, device: String) = MessageEntry(
            id, MessageRole.Assistant, parts, at, device, MessageStatus.Complete,
        )

        private fun tool(id: String, tag: String, vararg fields: Pair<String, String>, error: Boolean = false) =
            MessagePart.Tool(id, RenderToolCall(tag, mapOf(*fields)), error, true)

        private fun transcripts(now: Long): Map<String, List<MessageEntry>> = mapOf(
            "chat-veil" to listOf(
                user("m1", "Port the streaming fade-in veil from the desktop transcript. It must never affect layout — opacity only, split at chunk boundaries.", now - 3_500_000),
                assistant("m2", listOf(
                    MessagePart.Text("t0", """
                        ## Veil port plan

                        The desktop veil (`veil.rs`) multiplies a fading alpha into each appended chunk's text color — **paint-layer only**, so shaping and wrapping never change. Three invariants to carry over:

                        1. Chunk spans keep their *exact* byte length when split
                        2. Fade duration tracks the append cadence: `clamp(ema × 3, 120, 400)` ms
                        3. Re-attach seeds the baseline — only post-switch appends animate

                        | Constant | Value |
                        | --- | --- |
                        | `VEIL_MIN_FADE_MS` | 120 |
                        | `VEIL_MAX_FADE_MS` | 400 |
                        | `VEIL_CURVE_POW` | 1.6 |

                        > The curve is `1 − (1−p)^1.6` — fast attack, soft landing.
                    """.trimIndent()),
                    tool("tool1", "readFile", "path" to "crates/ui/src/markdown/veil.rs"),
                    tool("tool2", "editFile", "path" to "Harness/Transcript/Veil.swift"),
                    tool("tool3", "exec", "command" to "xcodebuild -scheme Harness build"),
                    MessagePart.Text("t1", """
                        Implementation lands in `Veil.swift`:

                        ```swift
                        func veilOpacity(_ p: Double) -> Double {
                            1 - pow(1 - p, 1.6)  // fast attack, soft landing
                        }

                        // Duration follows the streaming cadence EMA.
                        let duration = min(max(ema * 3, 120), 400)
                        ```

                        The row keeps one `RowVeil` while streaming and drops it on the live→complete flip, exactly like the desktop lifecycle.
                    """.trimIndent()),
                ), now - 3_400_000, "dev-mac"),
            ),
            "chat-picker" to listOf(
                user("m1", "The model picker shows stale catalogs after switching devices — where should the catalog come from?", now - 400_000),
                assistant("m2", listOf(
                    MessagePart.Text("t0", "Two viable sources — the local device's harness install, or the space's owning device. The desktop recently moved to the latter (`aa128a6`). Before I wire the RPC, one decision:"),
                    MessagePart.Input("req-1", "req-1", listOf(
                        UserInputQuestion(
                            "q1", "Catalog source", "Which device should serve harness/model catalogs for the picker?",
                            listOf("Space's device (Recommended)", "Local device", "Union of both"), false,
                        ),
                    ), false),
                ), now - 380_000, "dev-mac"),
            ),
            "chat-tabs" to listOf(
                user("m1", "Tool group headers turn red when any child fails — they should stay quiet, chips carry the error.", now - 1_000_000),
                assistant("m2", listOf(
                    tool("tool1", "search", "pattern" to "group_header_color"),
                    tool("tool2", "exec", "command" to "cargo test -p harness-ui tool_group", error = true),
                    tool("tool3", "editFile", "path" to "crates/ui/src/shell/transcript.rs"),
                    MessagePart.Text("t0", "Done — the header keeps `text_muted` even on failure; only the chip label and the summary segment (\"1 failed\") pick up `danger`. Matches the desktop fix in `1749890`."),
                ), now - 950_000, "dev-mac"),
            ),
            "chat-deploy" to listOf(
                user("m1", "Audit the wrangler config for hibernation hygiene.", now - 86_500_000),
                assistant("m2", listOf(
                    MessagePart.Text("t0", "Flush timer now only arms while dirty; ping/pong uses the auto-response path so the DO never wakes for keepalives."),
                ), now - 86_400_000, "dev-vps"),
            ),
        )

        /** The reply the demo streams when you send a message (simulateTurn). */
        val STREAM_REPLY = """
            Here's how the streamed reply renders on this device:

            - Markdown re-parses **only the tail** — the last two top-level blocks
            - New text fades in through the paint-only veil
            - The transcript stays glued to the bottom until you scroll up

            ```rust
            // The desktop constant carries over verbatim.
            const STREAM_COMMIT_MS: u64 = 120;
            ```

            When the turn settles, this entry flips `streaming → complete`, the veil drops, and the row ids stay stable so nothing flickers.
        """.trimIndent()
    }
}
