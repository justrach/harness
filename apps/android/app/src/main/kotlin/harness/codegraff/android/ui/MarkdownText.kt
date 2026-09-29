package harness.codegraff.android.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import harness.codegraff.android.model.MdBlock
import harness.codegraff.android.model.MdSpan
import harness.codegraff.android.model.parseMarkdown
import harness.codegraff.android.theme.GeistMono
import harness.codegraff.android.theme.Theme

/** Renders assistant text. Re-parses on each streamed update; transcripts are short enough that this stays cheap. */
@Composable
fun MarkdownText(text: String, modifier: Modifier = Modifier) {
    val blocks = remember(text) { parseMarkdown(text) }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(Theme.spaceMD)) {
        blocks.forEach { block ->
            when (block) {
                is MdBlock.Paragraph -> SpanText(block.spans, MaterialTheme.typography.bodyLarge)
                is MdBlock.Heading -> SpanText(
                    block.spans,
                    if (block.level <= 1) MaterialTheme.typography.titleLarge else MaterialTheme.typography.titleMedium,
                    weight = FontWeight.SemiBold,
                )
                is MdBlock.ListBlock -> Column(verticalArrangement = Arrangement.spacedBy(Theme.spaceXS)) {
                    block.items.forEachIndexed { index, item ->
                        Row {
                            Text(
                                if (block.ordered) "${index + 1}." else "•",
                                style = MaterialTheme.typography.bodyLarge,
                                modifier = Modifier.width(24.dp),
                            )
                            SpanText(item, MaterialTheme.typography.bodyLarge)
                        }
                    }
                }
                is MdBlock.Code -> Surface(
                    color = MaterialTheme.colorScheme.surfaceContainerHigh,
                    shape = RoundedCornerShape(Theme.panelRadius),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        block.text,
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = GeistMono),
                        modifier = Modifier.horizontalScroll(rememberScrollState()).padding(Theme.spaceMD),
                    )
                }
            }
        }
    }
}

@Composable
private fun SpanText(
    spans: List<MdSpan>,
    style: androidx.compose.ui.text.TextStyle,
    weight: FontWeight? = null,
) {
    val codeBackground = MaterialTheme.colorScheme.surfaceContainerHigh
    val annotated: AnnotatedString = remember(spans, codeBackground) {
        buildAnnotatedString {
            spans.forEach { span ->
                val spanStyle = SpanStyle(
                    fontWeight = if (span.bold) FontWeight.SemiBold else null,
                    fontStyle = if (span.italic) FontStyle.Italic else null,
                    fontFamily = if (span.code) GeistMono else null,
                    fontSize = if (span.code) 0.92.em else androidx.compose.ui.unit.TextUnit.Unspecified,
                    background = if (span.code) codeBackground else androidx.compose.ui.graphics.Color.Unspecified,
                )
                withStyle(spanStyle) { append(span.text) }
            }
        }
    }
    Text(annotated, style = if (weight != null) style.copy(fontWeight = weight) else style)
}
