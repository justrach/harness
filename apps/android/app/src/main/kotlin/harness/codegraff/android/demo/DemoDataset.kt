package harness.codegraff.android.demo

import harness.codegraff.android.model.Chat
import harness.codegraff.android.model.ChatConfig
import harness.codegraff.android.model.DeviceRow
import harness.codegraff.android.model.SessionRow
import harness.codegraff.android.model.SessionStatus
import harness.codegraff.android.model.Space
import harness.codegraff.android.model.ToolCall
import harness.codegraff.android.model.ToolKind
import harness.codegraff.android.model.TranscriptRow

/** Offline dataset so the app can be explored with no edge deployment (iOS `-demo`). */
class DemoDataset(
    val devices: List<DeviceRow>,
    val spaces: List<Space>,
    val chats: List<Chat>,
    val sessions: Map<String, SessionRow>,
    private val transcripts: Map<String, List<TranscriptRow>>,
) {
    fun transcript(chatId: String): List<TranscriptRow> = transcripts[chatId].orEmpty()

    fun device(id: String): DeviceRow? = devices.firstOrNull { it.id == id }

    fun space(id: String?): Space? = spaces.firstOrNull { it.id == id }

    companion object {
        private const val MIN = 60_000L
        private const val DAY = 86_400_000L

        fun standard(now: Long): DemoDataset {
            val mac = DeviceRow("dev-mac", "MacBook Pro", "macos", now)
            val vps = DeviceRow("dev-vps", "hetzner-01", "linux", now - 10 * MIN)
            val harness = Space("space-harness", mac.id, "/Users/dev/harness")
            val edge = Space("space-edge", vps.id, "/srv/deploys/edge")

            val claude = ChatConfig("claude-code", "claude-fable-5", "xhigh", "workspace-write")
            val codex = ChatConfig("codex", "gpt-5.6-terra", "high", "workspace-write")

            val chats = listOf(
                Chat("chat-veil", mac.id, "Streaming veil on transcript rows", branch = "veil-fade",
                    config = claude, lastMessagePreview = "Porting the paint-only fade…",
                    lastMessageAt = now - 40_000, createdAt = now - 60 * MIN,
                    spaceId = harness.id, lastSeenAt = now),
                Chat("chat-picker", mac.id, "Model picker catalog sync", branch = "main",
                    config = claude, lastMessagePreview = "Which device owns the catalog?",
                    lastMessageAt = now - 2 * MIN, createdAt = now - 120 * MIN,
                    spaceId = harness.id, lastSeenAt = now - 130_000),
                Chat("chat-tabs", mac.id, "Tool group header colors", branch = "main",
                    config = codex, lastMessagePreview = "Done — failed children stay quiet.",
                    lastMessageAt = now - 15 * MIN, createdAt = now - DAY,
                    spaceId = harness.id, lastSeenAt = now - 60 * MIN),
                Chat("chat-deploy", vps.id, "Wrangler deploy hygiene",
                    config = claude, lastMessagePreview = "Hibernation-safe flush timer",
                    lastMessageAt = now - DAY, createdAt = now - 2 * DAY,
                    spaceId = edge.id, lastSeenAt = now - DAY),
                Chat("chat-oklch", mac.id, "OKLCH conversion drift", archived = true, branch = "main",
                    config = claude, lastMessagePreview = "Gamma encode matches now.",
                    lastMessageAt = now - 3 * DAY, createdAt = now - 4 * DAY,
                    spaceId = harness.id, lastSeenAt = now - 3 * DAY),
                Chat("chat-presence", vps.id, "Presence beat coalescing", archived = true,
                    config = codex, lastMessagePreview = "Batched to one beat per 25s.",
                    lastMessageAt = now - 6 * DAY, createdAt = now - 7 * DAY,
                    spaceId = edge.id, lastSeenAt = now - 6 * DAY),
            )

            val sessions = mapOf(
                "chat-veil" to SessionRow("chat-veil", mac.id, SessionStatus.Working, now - 5_000),
                "chat-picker" to SessionRow("chat-picker", mac.id, SessionStatus.AwaitingInput, now - 10_000),
            )

            val transcripts = mapOf(
                "chat-tabs" to listOf(
                    TranscriptRow.User("u1", "Tool group headers turn red when any child fails — they should stay quiet, chips carry the error."),
                    TranscriptRow.ToolGroup(
                        "t1", "Ran 1 command · edited 1 file · 1 search · 1 failed",
                        listOf(
                            ToolCall(ToolKind.Search, "Search", "group_header_color"),
                            ToolCall(ToolKind.Run, "Run", "cargo test -p harness-ui tool_group", failed = true),
                            ToolCall(ToolKind.Edit, "Edit", "shell/transcript.rs"),
                        ),
                    ),
                    TranscriptRow.Assistant(
                        "a1",
                        "Done — the header keeps its muted color even on failure; only the chip label and the summary segment (“1 failed”) pick up the danger color.",
                    ),
                ),
                "chat-veil" to listOf(
                    TranscriptRow.User("u1", "Please verify the mobile layout."),
                    TranscriptRow.Assistant("a1", "Here's how the streamed reply renders on this device:"),
                ),
                "chat-picker" to listOf(
                    TranscriptRow.User("u1", "The model picker shows stale entries after a device reconnects."),
                    TranscriptRow.Assistant("a1", "Which device owns the catalog — the phone or the desktop host?"),
                ),
            )
            return DemoDataset(listOf(mac, vps), listOf(harness, edge), chats, sessions, transcripts)
        }

        /** The scripted reply the demo streams when you send a message. */
        const val STREAM_REPLY =
            "Here's how the streamed reply renders on this device: markdown re-parses only the tail, " +
                "and new text fades in through the paint-only veil. The transcript stays put while you type."
    }
}
