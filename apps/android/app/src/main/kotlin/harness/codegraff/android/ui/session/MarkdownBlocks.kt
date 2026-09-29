package harness.codegraff.android.ui.session

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import harness.codegraff.android.model.MdBlock
import harness.codegraff.android.model.MdSpan
import harness.codegraff.android.model.TableAlign
import harness.codegraff.android.theme.CodeFont
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.mono
import harness.codegraff.android.theme.sans

// Desktop markdown palette and hierarchy at a mobile reading scale (MarkdownBlockView.swift):
// body 17/26, code 14/21, monochrome links (primary text plus a muted underline, never accent).

private object MD {
    const val TEXT_SIZE = 17f
    const val LINE_HEIGHT = 26f
    const val CODE_TEXT_SIZE = 14f
    const val CODE_LINE_HEIGHT = 21f

    fun heading(level: Int): Pair<Float, Float> = when (level) {
        1 -> 23f to 31f
        2 -> 20f to 28f
        3 -> 18f to 26f
        else -> 17f to 26f
    }
}

@Composable
private fun rememberInline(spans: List<MdSpan>, size: Float, weight: FontWeight, base: Color): AnnotatedString {
    val p = Theme.palette
    val uriHandler = LocalUriHandler.current
    return remember(spans, size, weight, base, p) {
        buildAnnotatedString {
            for (span in spans) {
                val style = when {
                    span.code -> SpanStyle(
                        fontFamily = CodeFont, fontSize = (size - 1.5f).sp, color = p.inlineCodeText, background = p.inlineCodeWash,
                    )
                    else -> SpanStyle(
                        fontWeight = if (span.bold) FontWeight.SemiBold else weight,
                        fontStyle = if (span.italic) FontStyle.Italic else null, color = base,
                    )
                }
                val decorations = buildList {
                    if (span.strike) add(TextDecoration.LineThrough)
                    if (span.link != null) add(TextDecoration.Underline)
                }
                val styled = if (decorations.isEmpty()) style else style.copy(textDecoration = TextDecoration.combine(decorations))
                if (span.link != null) {
                    val link = LinkAnnotation.Url(
                        span.link, TextLinkStyles(styled),
                    ) { runCatching { uriHandler.openUri(span.link) } }
                    withLink(link) { append(span.text) }
                } else {
                    withStyle(styled) { append(span.text) }
                }
            }
        }
    }
}

@Composable
private fun RichText(spans: List<MdSpan>, size: Float, line: Float, weight: FontWeight = FontWeight.Normal, base: Color = Theme.palette.text, modifier: Modifier = Modifier) {
    val text = rememberInline(spans, size, weight, base)
    Text(text, style = sans(size, weight, line), color = base, modifier = modifier)
}

/** One top-level markdown block as a transcript row. */
@Composable
fun MarkdownBlockView(block: MdBlock, modifier: Modifier = Modifier) {
    val p = Theme.palette
    when (block) {
        is MdBlock.Paragraph -> RichText(block.spans, MD.TEXT_SIZE, MD.LINE_HEIGHT, modifier = modifier.fillMaxWidth())
        is MdBlock.Heading -> {
            val (size, line) = MD.heading(block.level)
            RichText(block.spans, size, line, FontWeight.SemiBold, modifier = modifier.fillMaxWidth())
        }
        is MdBlock.Code -> CodeBlock(block, modifier)
        is MdBlock.Blockquote -> Row(modifier.fillMaxWidth().height(IntrinsicSize.Min)) {
            Box(Modifier.width(3.dp).fillMaxHeight().background(p.borderStrong, RoundedCornerShape(2.dp)))
            Column(Modifier.padding(start = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                block.children.forEach { child ->
                    if (child is MdBlock.Paragraph) {
                        RichText(child.spans, MD.TEXT_SIZE, MD.LINE_HEIGHT, base = p.textMuted)
                    } else {
                        MarkdownBlockView(child)
                    }
                }
            }
        }
        is MdBlock.ListBlock -> Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            block.items.forEachIndexed { index, item ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        if (block.ordered) "${block.start + index}." else "•",
                        style = sans(MD.TEXT_SIZE, FontWeight.Normal, MD.LINE_HEIGHT), color = p.textMuted,
                        textAlign = TextAlign.End, modifier = Modifier.width(if (block.ordered) 24.dp else 16.dp),
                    )
                    RichText(item, MD.TEXT_SIZE, MD.LINE_HEIGHT, modifier = Modifier.weight(1f))
                }
            }
        }
        is MdBlock.Table -> TableBlock(block, modifier)
        MdBlock.Rule -> Box(modifier.fillMaxWidth().height(1.dp).background(p.border))
    }
}

@Composable
private fun CodeBlock(block: MdBlock.Code, modifier: Modifier) {
    val p = Theme.palette
    val shape = RoundedCornerShape(10.dp)
    Column(modifier.fillMaxWidth().clip(shape).background(p.surface, shape).border(1.dp, p.border, shape)) {
        if (!block.lang.isNullOrEmpty()) {
            Text(block.lang, style = sans(11f), color = p.textMuted, modifier = Modifier.padding(horizontal = 12.dp, vertical = 5.dp))
        }
        Text(
            highlight(block.text, block.lang, p.text, p.tokenKeyword, p.tokenString, p.tokenNumber, p.textFaint),
            style = mono(MD.CODE_TEXT_SIZE, lineHeight = MD.CODE_LINE_HEIGHT), color = p.text,
            softWrap = false,
            modifier = Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 10.dp),
        )
    }
}

@Composable
private fun TableBlock(block: MdBlock.Table, modifier: Modifier) {
    val p = Theme.palette
    val shape = RoundedCornerShape(10.dp)
    val columns = block.header.size
    Column(
        modifier.clip(shape).border(1.dp, p.border, shape).horizontalScroll(rememberScrollState()),
    ) {
        @Composable fun cell(spans: List<MdSpan>, col: Int, header: Boolean, first: Boolean) {
            val align = block.align.getOrNull(col) ?: TableAlign.Left
            Box(
                Modifier.width(150.dp).padding(horizontal = 12.dp, vertical = 8.dp),
                contentAlignment = when (align) {
                    TableAlign.Left -> androidx.compose.ui.Alignment.CenterStart
                    TableAlign.Center -> androidx.compose.ui.Alignment.Center
                    TableAlign.Right -> androidx.compose.ui.Alignment.CenterEnd
                },
            ) { RichText(spans, 14f, 20f, if (header) FontWeight.SemiBold else FontWeight.Normal) }
        }
        Row(Modifier.background(p.ink(0.04f))) { block.header.forEachIndexed { c, s -> cell(s, c, true, c == 0) } }
        block.rows.forEach { row ->
            Box(Modifier.fillMaxWidth().height(1.dp).background(p.border))
            Row { for (c in 0 until columns) cell(row.getOrElse(c) { emptyList() }, c, false, c == 0) }
        }
    }
}

/** A tiny token highlighter (keywords, strings, numbers, comments), painted with the theme's syntax colors. */
internal fun highlight(code: String, lang: String?, base: Color, keyword: Color, string: Color, number: Color, comment: Color): AnnotatedString {
    val keywords = when (lang?.lowercase()) {
        "swift" -> setOf("func", "let", "var", "if", "else", "for", "while", "return", "struct", "class", "enum", "import", "guard", "switch", "case", "in", "private", "static", "extension", "some")
        "rust", "rs" -> setOf("fn", "let", "mut", "if", "else", "for", "while", "return", "struct", "enum", "impl", "use", "pub", "const", "match", "mod", "trait", "self", "u64", "usize")
        "kotlin", "kt" -> setOf("fun", "val", "var", "if", "else", "for", "while", "return", "class", "object", "import", "when", "is", "in", "private", "data", "sealed")
        "ts", "typescript", "js", "javascript" -> setOf("function", "const", "let", "var", "if", "else", "for", "while", "return", "class", "import", "export", "async", "await", "interface", "type")
        "python", "py" -> setOf("def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "with", "lambda", "None", "True", "False")
        else -> emptySet()
    }
    return buildAnnotatedString {
        code.split('\n').forEachIndexed { lineIx, line ->
            if (lineIx > 0) append('\n')
            val commentAt = line.indexOf("//").let { if (it >= 0) it else line.indexOf("# ").takeIf { h -> h == 0 } ?: -1 }
            val body = if (commentAt >= 0) line.substring(0, commentAt) else line
            var i = 0
            while (i < body.length) {
                val c = body[i]
                when {
                    c == '"' -> {
                        val end = body.indexOf('"', i + 1).let { if (it < 0) body.length - 1 else it }
                        withStyle(SpanStyle(color = string)) { append(body.substring(i, end + 1)) }
                        i = end + 1
                    }
                    c.isDigit() -> {
                        var j = i
                        while (j < body.length && (body[j].isDigit() || body[j] == '.' || body[j] == '_')) j++
                        withStyle(SpanStyle(color = number)) { append(body.substring(i, j)) }
                        i = j
                    }
                    c.isLetter() || c == '_' -> {
                        var j = i
                        while (j < body.length && (body[j].isLetterOrDigit() || body[j] == '_')) j++
                        val word = body.substring(i, j)
                        withStyle(SpanStyle(color = if (word in keywords) keyword else base)) { append(word) }
                        i = j
                    }
                    else -> { append(c); i++ }
                }
            }
            if (commentAt >= 0) withStyle(SpanStyle(color = comment, fontStyle = FontStyle.Italic)) { append(line.substring(commentAt)) }
        }
    }
}
