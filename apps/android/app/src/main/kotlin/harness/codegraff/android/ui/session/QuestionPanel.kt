package harness.codegraff.android.ui.session

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import harness.codegraff.android.model.UserInputAnswer
import harness.codegraff.android.model.UserInputQuestion
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.sans
import harness.codegraff.android.ui.components.glass
import kotlinx.coroutines.delay

/** The question wizard that replaces the composer while input is requested (composer.rs Wizard). */
@Composable
fun QuestionPanel(
    requestId: String,
    questions: List<UserInputQuestion>,
    modifier: Modifier = Modifier,
    respond: (String, List<UserInputAnswer>) -> Unit,
) {
    if (questions.isEmpty()) return // a request whose questions fail to decode must never crash the session
    val p = Theme.palette
    var page by remember { mutableStateOf(0) }
    val picked = remember { mutableStateMapOf<String, Set<String>>() }
    val typed = remember { mutableStateMapOf<String, String>() }
    var autoAdvance by remember { mutableStateOf<Int?>(null) }

    val question = questions[page.coerceIn(0, questions.lastIndex)]
    fun canAdvance(q: UserInputQuestion) = !typed[q.id].isNullOrEmpty() || picked[q.id].orEmpty().isNotEmpty()
    fun advance() {
        val q = questions[page.coerceIn(0, questions.lastIndex)]
        if (!canAdvance(q)) return
        if (page < questions.lastIndex) { page += 1; return }
        respond(requestId, questions.map { qq ->
            val own = typed[qq.id].orEmpty().trim()
            UserInputAnswer(qq.id, if (own.isNotEmpty()) listOf(own) else picked[qq.id].orEmpty().toList())
        })
    }
    // Single-select auto-advances after 220ms (AUTO_ADVANCE_MS).
    LaunchedEffect(autoAdvance) {
        if (autoAdvance != null) { delay(220); advance(); autoAdvance = null }
    }

    val shape = RoundedCornerShape(26.dp)
    Column(
        modifier.padding(horizontal = 12.dp).widthIn(max = 736.dp).fillMaxWidth()
            .glass(shape).border(1.dp, p.hairline(0.05f), shape).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(question.header.uppercase(), style = sans(10.5f, FontWeight.Medium).copy(letterSpacing = 1.sp), color = p.textMuted.opacity(0.6f))
            Spacer(Modifier.weight(1f))
            if (questions.size > 1) {
                Text(
                    "${page + 1}/${questions.size}", style = sans(10f), color = p.textMuted,
                    modifier = Modifier.height(20.dp).background(p.ink(0.06f), RoundedCornerShape(6.dp)).padding(horizontal = 6.dp),
                )
            }
        }
        Text(question.question, style = sans(15f, FontWeight.Medium), color = p.text)
        if (question.multiSelect == true) Text("Select one or more options.", style = sans(12f), color = p.textMuted)
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            question.options.forEachIndexed { ix, option ->
                val isPicked = typed[question.id].isNullOrEmpty() && option in picked[question.id].orEmpty()
                val rowShape = RoundedCornerShape(12.dp)
                Row(
                    Modifier.fillMaxWidth().clip(rowShape)
                        .background(if (isPicked) p.ink(0.09f) else p.ink(0.025f), rowShape)
                        .border(1.dp, if (isPicked) p.ink(0.16f) else androidx.compose.ui.graphics.Color.Transparent, rowShape)
                        .clickable(role = Role.Button) {
                            typed.remove(question.id)
                            if (question.multiSelect == true) {
                                val set = picked[question.id].orEmpty()
                                picked[question.id] = if (option in set) set - option else set + option
                            } else {
                                picked[question.id] = setOf(option)
                                autoAdvance = (autoAdvance ?: 0) + 1
                            }
                        }
                        .padding(horizontal = 14.dp, vertical = 10.dp).heightIn(min = 28.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Text(option, style = sans(13.5f, FontWeight.Medium), color = p.text, modifier = Modifier.weight(1f))
                    if (ix < 9) {
                        Box(Modifier.size(22.dp).background(p.ink(0.06f), RoundedCornerShape(6.dp)), contentAlignment = Alignment.Center) {
                            Text("${ix + 1}", style = sans(11f), color = p.textMuted)
                        }
                    }
                }
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(Modifier.fillMaxWidth().height(1.dp).background(p.hairline(0.06f)))
            Box(Modifier.fillMaxWidth().padding(top = 6.dp)) {
                val text = typed[question.id].orEmpty()
                if (text.isEmpty()) Text("Or type your own answer", style = sans(13f), color = p.textFaint)
                BasicTextField(
                    value = text, onValueChange = { typed[question.id] = it },
                    textStyle = sans(13f).copy(color = p.text), cursorBrush = SolidColor(p.text),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (page > 0) {
                Box(Modifier.heightIn(min = 48.dp).clip(CircleShape).clickable { page -= 1 }.padding(horizontal = 4.dp), contentAlignment = Alignment.Center) {
                    Text("Back", style = sans(13f, FontWeight.Medium), color = p.textMuted)
                }
            }
            Spacer(Modifier.weight(1f))
            val enabled = canAdvance(question)
            Box(
                Modifier.height(34.dp).alpha(if (enabled) 1f else 0.4f).background(p.text, CircleShape).clip(CircleShape)
                    .clickable(enabled = enabled, role = Role.Button) { advance() }.padding(horizontal = 16.dp),
                contentAlignment = Alignment.Center,
            ) { Text(if (page < questions.lastIndex) "Next" else "Submit", style = sans(13f, FontWeight.Medium), color = p.bg) }
        }
    }
}
