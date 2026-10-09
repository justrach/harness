package harness.codegraff.android.model

import harness.codegraff.android.perf.Perf
import harness.codegraff.android.perf.PerfSpan

// Session doc entries and the transcript row model: a port of
// crates/ui/src/shell/transcript.rs rows_for_entry (TranscriptRows.swift). One row is
// one markdown top-level block, tool group or chip, never one message: streamed tokens
// re-render one row. Row ids are stable ("{entryId}#{partId}.{blockIx}" for markdown,
// "{entryId}#g{groupIx}" for tool groups) so the live to complete flip never changes identity.

enum class MessageRole { User, Assistant, System }

enum class MessageStatus { Streaming, Complete, Aborted }

data class UserInputQuestion(
    val id: String,
    val header: String,
    val question: String,
    val options: List<String>,
    val multiSelect: Boolean? = null,
)

data class UserInputAnswer(val questionId: String, val labels: List<String>)

/**
 * A tool call as the desktop renders it: a tag ("exec", "readFile", ...), its scalar fields as text, and its list
 * fields item by item (`applyPatch` changes, `todo` items).
 */
data class RenderToolCall(
    val tag: String,
    val fields: Map<String, String> = emptyMap(),
    val lists: Map<String, List<String>> = emptyMap(),
) {
    private fun string(key: String): String? = fields[key]

    val chipLabel: String
        get() = when (tag) {
            "exec" -> "Run"
            "readFile" -> "Read"
            "writeFile" -> "Write"
            "editFile" -> "Edit"
            "applyPatch" -> "Patch"
            "search" -> "Search"
            "glob" -> "Glob"
            "webFetch" -> "Fetch"
            "webSearch" -> "Web"
            "todo" -> "Todo"
            "mcp" -> "MCP"
            else -> "Tool"
        }

    private fun shortPath(path: String): String {
        val comps = path.split('/').filter { it.isNotEmpty() }
        return if (comps.size > 2) comps.takeLast(2).joinToString("/") else path
    }

    val chipDetail: String
        get() = when (tag) {
            "exec" -> string("command").orEmpty()
            "readFile", "writeFile", "editFile" -> shortPath(string("path").orEmpty())
            "applyPatch" -> {
                val n = lists["changes"]?.size ?: string("changes")?.split(',')?.size ?: 0
                if (n == 1) "1 file" else "$n files"
            }
            "search", "glob" -> string("pattern").orEmpty()
            "webFetch" -> string("url").orEmpty()
            "webSearch" -> string("query").orEmpty()
            "todo" -> string("summary") ?: "task list"
            "mcp" -> (string("server")?.let { "$it · " } ?: "") + (string("tool") ?: "")
            else -> string("name").orEmpty()
        }

    /** Preserve full paths in the expanded row and on the clipboard. */
    val expandedDetail: String
        get() = when (tag) {
            "readFile", "writeFile", "editFile" -> string("path").orEmpty()
            else -> chipDetail
        }
}

data class ToolItem(val call: RenderToolCall, val isError: Boolean, val resolved: Boolean)

/** "Ran 3 commands · edited 2 files · 1 failed" (transcript.rs tool_group_summary). */
fun toolGroupSummary(tools: List<ToolItem>): String {
    val segments = mutableListOf<String>()
    val runs = tools.count { it.call.tag == "exec" }
    if (runs > 0) segments += if (runs == 1) "ran 1 command" else "ran $runs commands"
    val edits = tools.count { it.call.tag in setOf("editFile", "writeFile", "applyPatch") }
    if (edits > 0) segments += if (edits == 1) "edited 1 file" else "edited $edits files"
    val reads = tools.count { it.call.tag == "readFile" }
    if (reads > 0) segments += if (reads == 1) "read 1 file" else "read $reads files"
    val searches = tools.count { it.call.tag in setOf("search", "glob", "webSearch", "webFetch") }
    if (searches > 0) segments += if (searches == 1) "1 search" else "$searches searches"
    val other = tools.size - runs - edits - reads - searches
    if (other > 0) segments += if (other == 1) "1 tool" else "$other tools"
    val failed = tools.count { it.isError }
    if (failed > 0) segments += "$failed failed"
    val first = segments.firstOrNull() ?: return "${tools.size} tools"
    return (listOf(first.replaceFirstChar { it.uppercase() }) + segments.drop(1)).joinToString(" · ")
}

sealed interface MessagePart {
    val id: String

    data class Text(override val id: String, val text: String) : MessagePart
    data class Tool(override val id: String, val call: RenderToolCall, val isError: Boolean, val resolved: Boolean) : MessagePart
    data class Input(
        override val id: String,
        val requestId: String,
        val questions: List<UserInputQuestion>,
        val resolved: Boolean,
    ) : MessagePart
    data class Error(override val id: String, val message: String) : MessagePart
    /** An image the agent produced; the bytes stay on the host that made it. */
    data class Image(override val id: String, val path: String, val name: String, val mimeType: String) : MessagePart
}

data class MessageEntry(
    val id: String,
    val role: MessageRole,
    val parts: List<MessagePart>,
    val createdAt: Long,
    val deviceId: String,
    val status: MessageStatus?,
)

/** An optimistic echo of a message that has not been adopted by the host yet. */
data class PendingSend(val messageId: String, val text: String)

sealed interface RowKind {
    data class User(val text: String, val pending: Boolean = false) : RowKind
    data class Markdown(val block: MdBlock, val streaming: Boolean) : RowKind
    data class ToolGroup(val tools: List<ToolItem>, val autoOpen: Boolean) : RowKind
    data class InputChip(val header: String, val resolved: Boolean) : RowKind
    data class ErrorChip(val message: String) : RowKind
    data class GeneratedImage(val name: String) : RowKind
}

data class TranscriptRow(
    val id: String,
    val turnStart: Boolean,
    val kind: RowKind,
    val entryId: String,
    val timestamp: Long?,
    /** "{entryId}#{partId}" for markdown rows: two adjacent rows sharing it are blocks of the same part (the tighter gap). */
    val partKey: String?,
    /** Leading gap in dp, resolved at build time from the previous row. */
    val topGap: Float = 0f,
)

/**
 * Row-build cache (TranscriptBuilderCache in TranscriptView.swift): a memo of parsed text parts keyed by
 * "{entryId}#{partId}", so a settled part is parsed exactly once and a streamed token re-parses only the
 * live tail rather than the whole transcript. Rows that did not change keep their identity, which lets
 * the lazy list skip them. Owned per session, not per composition, so re-opening a chat re-parses nothing.
 */
class TranscriptBuilderCache {
    private class Parsed(val source: String, val blocks: List<MdBlock>)

    private val parsed = HashMap<String, Parsed>()
    private var lastEntries: List<MessageEntry>? = null
    private var lastPending: List<PendingSend>? = null
    private var lastRows: List<TranscriptRow> = emptyList()

    /** How many markdown parses this cache has run (a test hook). */
    var parseCount = 0
        private set

    fun rows(entries: List<MessageEntry>, pendingSends: List<PendingSend> = emptyList()): List<TranscriptRow> {
        if (entries === lastEntries && pendingSends == lastPending) return lastRows
        return Perf.measure(PerfSpan.TranscriptRows) { build(entries, pendingSends) }
    }

    private fun build(entries: List<MessageEntry>, pendingSends: List<PendingSend>): List<TranscriptRow> {
        val live = HashSet<String>()
        val built = TranscriptRowBuilder.rows(entries, pendingSends) { key, text ->
            live += key
            val hit = parsed[key]
            if (hit != null && hit.source == text) {
                hit.blocks
            } else {
                parseCount++
                Perf.measure(PerfSpan.MarkdownParse) { parseMarkdown(text) }.also { parsed[key] = Parsed(text, it) }
            }
        }
        // Drop memos for parts that no longer exist; the size guard keeps the append-only path allocation-free.
        if (parsed.size > live.size) parsed.keys.retainAll(live)
        val previous = lastRows.associateBy { it.id }
        val rows = built.map { row -> previous[row.id]?.takeIf { it == row } ?: row }
        lastEntries = entries
        lastPending = pendingSends
        lastRows = rows
        return rows
    }
}

object TranscriptRowBuilder {
    /** MD.blockGap. */
    const val BLOCK_GAP = 12f
    private const val SPACE_LG = 16f
    private const val SPACE_MD = 12f
    private const val SPACE_SM = 8f

    fun rows(
        entries: List<MessageEntry>,
        pendingSends: List<PendingSend> = emptyList(),
        parse: (key: String, text: String) -> List<MdBlock> = { _, text -> parseMarkdown(text) },
    ): List<TranscriptRow> {
        val rows = mutableListOf<TranscriptRow>()
        for (entry in entries) rowsForEntry(entry, rows, parse)
        // Optimistic echo: pending sends share their client-minted id, so the host's real entry replaces them without a flicker.
        val ids = entries.map { it.id }.toSet()
        for (pending in pendingSends) {
            if (pending.messageId in ids) continue
            rows += TranscriptRow(pending.messageId, true, RowKind.User(pending.text, pending = true), pending.messageId, null, null)
        }
        // A doc that merged two writers' copies of an entry can repeat an id. The lazy list keys rows by id and
        // cannot take a repeat, so the first row with an id wins.
        val seen = HashSet<String>()
        val unique = rows.filter { seen.add(it.id) }
        return unique.mapIndexed { ix, row -> row.copy(topGap = gap(row, unique.getOrNull(ix - 1), ix == 0)) }
    }

    private fun gap(row: TranscriptRow, previous: TranscriptRow?, isFirst: Boolean): Float = when {
        isFirst -> SPACE_LG + 10
        row.turnStart -> SPACE_LG
        // Same part means these are sibling markdown blocks, not a new turn.
        row.partKey != null && row.partKey == previous?.partKey -> BLOCK_GAP
        // Tool stacks are visually denser than prose, so use one larger step on both boundaries.
        isToolGroup(row) || isToolGroup(previous) -> SPACE_MD
        else -> SPACE_SM
    }

    private fun isToolGroup(row: TranscriptRow?) = row?.kind is RowKind.ToolGroup

    private fun rowsForEntry(
        entry: MessageEntry,
        rows: MutableList<TranscriptRow>,
        parse: (key: String, text: String) -> List<MdBlock>,
    ) {
        val streaming = entry.status == MessageStatus.Streaming
        val settled = entry.status != null && !streaming

        if (entry.role == MessageRole.User) {
            val text = entry.parts.filterIsInstance<MessagePart.Text>().joinToString("\n") { it.text }
            if (text.isEmpty()) return
            rows += TranscriptRow(entry.id, true, RowKind.User(text), entry.id, entry.createdAt, null)
            return
        }

        var first = true
        val pendingTools = mutableListOf<ToolItem>()
        var groupIx = 0
        val lastPartIx = entry.parts.lastIndex

        fun flushTools(lastIx: Int) {
            if (pendingTools.isEmpty()) return
            val autoOpen = streaming && lastIx == lastPartIx
            rows += TranscriptRow(
                "${entry.id}#g$groupIx", first, RowKind.ToolGroup(pendingTools.toList(), autoOpen),
                entry.id, null, null,
            )
            first = false
            pendingTools.clear()
            groupIx++
        }

        entry.parts.forEachIndexed { ix, part ->
            when (part) {
                is MessagePart.Tool -> {
                    pendingTools += ToolItem(part.call, part.isError, part.resolved)
                    if (ix == lastPartIx) flushTools(ix)
                }
                is MessagePart.Text -> {
                    flushTools(ix - 1)
                    if (part.text.isEmpty()) return@forEachIndexed
                    val key = "${entry.id}#${part.id}"
                    val isLiveTail = streaming && ix == lastPartIx
                    val blocks = parse(key, part.text)
                    blocks.forEachIndexed { blockIx, block ->
                        val last = blockIx == blocks.lastIndex
                        rows += TranscriptRow(
                            "$key.$blockIx", first, RowKind.Markdown(block, isLiveTail && last),
                            entry.id, if (settled && ix == lastPartIx && last) entry.createdAt else null, key,
                        )
                        first = false
                    }
                }
                is MessagePart.Input -> {
                    flushTools(ix - 1)
                    val header = part.questions.firstOrNull()?.header ?: "Question"
                    rows += TranscriptRow("${entry.id}#${part.id}", first, RowKind.InputChip(header, part.resolved), entry.id, null, null)
                    first = false
                }
                is MessagePart.Error -> {
                    flushTools(ix - 1)
                    rows += TranscriptRow("${entry.id}#${part.id}", first, RowKind.ErrorChip(part.message), entry.id, null, null)
                    first = false
                }
                is MessagePart.Image -> {
                    flushTools(ix - 1)
                    rows += TranscriptRow(
                        "${entry.id}#${part.id}", first, RowKind.GeneratedImage(part.name), entry.id,
                        if (settled && ix == lastPartIx) entry.createdAt else null, null,
                    )
                    first = false
                }
            }
        }
        flushTools(lastPartIx)
    }
}
