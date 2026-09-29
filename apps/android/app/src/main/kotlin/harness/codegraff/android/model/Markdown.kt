package harness.codegraff.android.model

// A small markdown reader for transcript text: paragraphs, headings, bullet and
// numbered lists, fenced code, block quotes, tables, rules, and the inline marks
// agents use most (`code`, **bold**, *italic*, ~~strike~~, [links](url)). Unterminated
// marks stay literal, so a half-streamed reply never flickers into the wrong shape.

data class MdSpan(
    val text: String,
    val bold: Boolean = false,
    val italic: Boolean = false,
    val code: Boolean = false,
    val strike: Boolean = false,
    val link: String? = null,
)

enum class TableAlign { Left, Center, Right }

sealed interface MdBlock {
    data class Paragraph(val spans: List<MdSpan>) : MdBlock
    data class Heading(val level: Int, val spans: List<MdSpan>) : MdBlock
    data class ListBlock(val ordered: Boolean, val start: Int, val items: List<List<MdSpan>>) : MdBlock
    data class Code(val lang: String?, val text: String) : MdBlock
    data class Blockquote(val children: List<MdBlock>) : MdBlock
    data class Table(val header: List<List<MdSpan>>, val rows: List<List<List<MdSpan>>>, val align: List<TableAlign>) : MdBlock
    data object Rule : MdBlock
}

private val bulletRe = Regex("""^\s*[-*+]\s+(.*)$""")
private val orderedRe = Regex("""^\s*(\d+)[.)]\s+(.*)$""")
private val headingRe = Regex("""^(#{1,6})\s+(.*)$""")
private val ruleRe = Regex("""^\s{0,3}([-*_])(\s*\1){2,}\s*$""")
private val tableSepRe = Regex("""^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$""")

private fun splitRow(line: String): List<String> =
    line.trim().removePrefix("|").removeSuffix("|").split('|').map { it.trim() }

fun parseMarkdown(src: String): List<MdBlock> {
    val blocks = mutableListOf<MdBlock>()
    val paragraph = mutableListOf<String>()
    var list: MutableList<List<MdSpan>>? = null
    var listOrdered = false
    var listStart = 1

    fun flushParagraph() {
        if (paragraph.isNotEmpty()) {
            blocks += MdBlock.Paragraph(parseInline(paragraph.joinToString(" ")))
            paragraph.clear()
        }
    }
    fun flushList() {
        list?.let { blocks += MdBlock.ListBlock(listOrdered, listStart, it.toList()) }
        list = null
    }

    val lines = src.split('\n')
    var i = 0
    while (i < lines.size) {
        val line = lines[i]
        if (line.trimStart().startsWith("```")) {
            flushParagraph(); flushList()
            val lang = line.trim().removePrefix("```").trim().ifEmpty { null }
            val body = mutableListOf<String>()
            i++
            // An unclosed fence (still streaming) renders as code so far.
            while (i < lines.size && !lines[i].trimStart().startsWith("```")) body += lines[i++]
            blocks += MdBlock.Code(lang, body.joinToString("\n"))
            i++
            continue
        }
        if (line.trimStart().startsWith(">")) {
            flushParagraph(); flushList()
            val quoted = mutableListOf<String>()
            while (i < lines.size && lines[i].trimStart().startsWith(">")) {
                quoted += lines[i].trimStart().removePrefix(">").removePrefix(" ")
                i++
            }
            blocks += MdBlock.Blockquote(parseMarkdown(quoted.joinToString("\n")))
            continue
        }
        if (line.contains('|') && i + 1 < lines.size && tableSepRe.matches(lines[i + 1]) && lines[i + 1].contains('-')) {
            flushParagraph(); flushList()
            val header = splitRow(line).map { parseInline(it) }
            val align = splitRow(lines[i + 1]).map { cell ->
                when {
                    cell.startsWith(":") && cell.endsWith(":") -> TableAlign.Center
                    cell.endsWith(":") -> TableAlign.Right
                    else -> TableAlign.Left
                }
            }
            val rows = mutableListOf<List<List<MdSpan>>>()
            i += 2
            while (i < lines.size && lines[i].contains('|') && lines[i].isNotBlank()) {
                rows += splitRow(lines[i]).map { parseInline(it) }
                i++
            }
            blocks += MdBlock.Table(header, rows, align)
            continue
        }
        val heading = headingRe.matchEntire(line)
        val bullet = bulletRe.matchEntire(line)
        val ordered = orderedRe.matchEntire(line)
        when {
            line.isBlank() -> { flushParagraph(); flushList() }
            ruleRe.matches(line) && paragraph.isEmpty() -> { flushList(); blocks += MdBlock.Rule }
            heading != null -> {
                flushParagraph(); flushList()
                blocks += MdBlock.Heading(heading.groupValues[1].length, parseInline(heading.groupValues[2]))
            }
            bullet != null || ordered != null -> {
                flushParagraph()
                val isOrdered = ordered != null && bullet == null
                if (list != null && listOrdered != isOrdered) flushList()
                if (list == null) {
                    list = mutableListOf(); listOrdered = isOrdered
                    listStart = if (isOrdered) ordered!!.groupValues[1].toIntOrNull() ?: 1 else 1
                }
                val text = if (bullet != null) bullet.groupValues[1] else ordered!!.groupValues[2]
                list!!.add(parseInline(text))
            }
            else -> { flushList(); paragraph += line.trim() }
        }
        i++
    }
    flushParagraph(); flushList()
    return blocks
}

private val linkRe = Regex("""^\[([^\]]+)]\(([^)\s]+)\)""")

fun parseInline(s: String): List<MdSpan> {
    val out = mutableListOf<MdSpan>()
    val plain = StringBuilder()
    fun flush() {
        if (plain.isNotEmpty()) { out += MdSpan(plain.toString()); plain.clear() }
    }
    var i = 0
    while (i < s.length) {
        val c = s[i]
        if (c == '`') {
            val end = s.indexOf('`', i + 1)
            if (end > i + 1) { flush(); out += MdSpan(s.substring(i + 1, end), code = true); i = end + 1; continue }
        }
        if (c == '[') {
            val m = linkRe.find(s.substring(i))
            if (m != null) {
                flush()
                out += parseInline(m.groupValues[1]).map { it.copy(link = m.groupValues[2]) }
                i += m.value.length
                continue
            }
        }
        if (s.startsWith("**", i)) {
            val end = s.indexOf("**", i + 2)
            if (end > i + 2) {
                flush(); out += parseInline(s.substring(i + 2, end)).map { it.copy(bold = true) }; i = end + 2; continue
            }
        }
        if (s.startsWith("~~", i)) {
            val end = s.indexOf("~~", i + 2)
            if (end > i + 2) {
                flush(); out += parseInline(s.substring(i + 2, end)).map { it.copy(strike = true) }; i = end + 2; continue
            }
        }
        if (c == '*' || c == '_') {
            val startsWord = c == '*' || i == 0 || !s[i - 1].isLetterOrDigit()
            val end = s.indexOf(c, i + 1)
            val endsWord = end > 0 && (end + 1 >= s.length || !(c == '_' && s[end + 1].isLetterOrDigit()))
            if (startsWord && end > i + 1 && !s[i + 1].isWhitespace() && endsWord) {
                flush(); out += parseInline(s.substring(i + 1, end)).map { it.copy(italic = true) }; i = end + 1; continue
            }
        }
        plain.append(c)
        i++
    }
    flush()
    return out
}
