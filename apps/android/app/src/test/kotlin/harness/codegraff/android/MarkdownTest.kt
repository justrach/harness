package harness.codegraff.android

import harness.codegraff.android.demo.DemoDataset
import harness.codegraff.android.model.MdBlock
import harness.codegraff.android.model.MdSpan
import harness.codegraff.android.model.parseInline
import harness.codegraff.android.model.parseMarkdown
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MarkdownTest {
    @Test
    fun inlineMarks() {
        assertEquals(
            listOf(MdSpan("a "), MdSpan("b", bold = true), MdSpan(" "), MdSpan("c", code = true), MdSpan(" "), MdSpan("d", italic = true)),
            parseInline("a **b** `c` *d*"),
        )
    }

    @Test
    fun unterminatedMarksStayLiteralWhileStreaming() {
        assertEquals(listOf(MdSpan("half **bold")), parseInline("half **bold"))
        assertEquals(listOf(MdSpan("open `code")), parseInline("open `code"))
    }

    @Test
    fun snakeCaseIsNotItalic() {
        assertEquals(listOf(MdSpan("use snake_case_name here")), parseInline("use snake_case_name here"))
    }

    @Test
    fun paragraphsListsHeadingsAndFences() {
        val blocks = parseMarkdown("# Title\n\nFirst line\ncontinues.\n\n- one\n- two\n\n1. a\n2. b\n\n```kotlin\nval x = 1\n```\n")
        assertEquals(5, blocks.size)
        assertTrue(blocks[0] is MdBlock.Heading)
        assertEquals("First line continues.", (blocks[1] as MdBlock.Paragraph).spans.single().text)
        assertEquals(false, (blocks[2] as MdBlock.ListBlock).ordered)
        assertEquals(2, (blocks[2] as MdBlock.ListBlock).items.size)
        assertEquals(true, (blocks[3] as MdBlock.ListBlock).ordered)
        assertEquals(MdBlock.Code("kotlin", "val x = 1"), blocks[4])
    }

    @Test
    fun unclosedFenceRendersAsCodeSoFar() {
        assertEquals(listOf(MdBlock.Code(null, "partial")), parseMarkdown("```\npartial"))
    }

    @Test
    fun everyPrefixOfTheDemoReplyParsesWithoutCrashing() {
        val reply = DemoDataset.STREAM_REPLY
        for (end in 0..reply.length) parseMarkdown(reply.substring(0, end))
    }
}
