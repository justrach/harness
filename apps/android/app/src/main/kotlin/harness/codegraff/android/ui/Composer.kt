package harness.codegraff.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.unit.dp
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.Type

@Composable
fun Composer(onSend: (String) -> Unit, modifier: Modifier = Modifier) {
    val p = Theme.palette
    var text by remember { mutableStateOf("") }
    val canSend = text.isNotBlank()
    Row(
        modifier
            .fillMaxWidth()
            .padding(Theme.spaceMD)
            .border(1.dp, p.border, RoundedCornerShape(Theme.bubbleRadius))
            .background(p.surface, RoundedCornerShape(Theme.bubbleRadius))
            .padding(start = Theme.spaceLG, end = Theme.spaceSM, top = Theme.spaceSM, bottom = Theme.spaceSM),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.weight(1f)) {
            if (text.isEmpty()) Text("Message", style = Type.body, color = p.textFaint)
            BasicTextField(
                value = text,
                onValueChange = { text = it },
                textStyle = Type.body.copy(color = p.text),
                cursorBrush = SolidColor(p.accent),
                maxLines = 6,
            )
        }
        Box(
            Modifier
                .size(34.dp)
                .clip(CircleShape)
                .background(if (canSend) p.accent else p.hover)
                .clickable(enabled = canSend) {
                    onSend(text)
                    text = ""
                },
            contentAlignment = Alignment.Center,
        ) {
            Text("↑", style = Type.title, color = if (canSend) p.accentOn else p.textFaint)
        }
    }
}
