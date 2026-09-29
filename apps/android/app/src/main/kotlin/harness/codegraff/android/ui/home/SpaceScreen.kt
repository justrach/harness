package harness.codegraff.android.ui.home

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import harness.codegraff.android.AppModel
import harness.codegraff.android.WorkspaceState
import harness.codegraff.android.model.NewSessionDestination
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.Glyph
import harness.codegraff.android.theme.GlyphView
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.sans
import harness.codegraff.android.ui.Route
import harness.codegraff.android.ui.components.GlassCircleButton
import harness.codegraff.android.ui.components.statusBarHeight

/**
 * Space detail: the phone's answer to the desktop's horizontal session tabs. The space's sessions
 * as a vertical list, swipe-to-archive (tab close), and "+" to start a session in this space
 * (SpaceView.swift).
 */
@Composable
fun SpaceScreen(
    spaceId: String,
    state: WorkspaceState,
    model: AppModel,
    showBack: Boolean,
    onBack: () -> Unit,
    onOpen: (Route) -> Unit,
    modifier: Modifier = Modifier,
) {
    val p = Theme.palette
    val space = state.spaces.firstOrNull { it.id == spaceId }
    val chats = state.chatsIn(spaceId)
    val archived = state.archivedMatches(spaceId, "")
    val topInset = statusBarHeight()

    Box(modifier.fillMaxSize().background(p.surface)) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = topInset + 56.dp, bottom = 32.dp)) {
            if (chats.isEmpty()) {
                item {
                    Column(Modifier.fillMaxWidth().padding(vertical = 48.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        GlyphView(Glyph.Chat, 30.dp, p.textFaint, strokeWidth = 1.1f)
                        Text("No sessions in this space", style = sans(13f), color = p.textFaint)
                        Box(
                            Modifier.height(48.dp).clip(CircleShape).background(p.ink(0.08f), CircleShape)
                                .clickable(role = Role.Button) { onOpen(Route.NewSession(NewSessionDestination.Project(spaceId))) }.padding(horizontal = 20.dp),
                            contentAlignment = Alignment.Center,
                        ) { Text("Start a session", style = sans(13f, FontWeight.Medium), color = p.text) }
                    }
                }
            }
            items(chats, key = { it.id }) { chat -> SessionRow(chat, state, model, selected = false) { onOpen(Route.Chat(chat.id)) } }
            if (archived.isNotEmpty()) archivedShelf(archived, state, model, null, onOpen)
        }
        Box(Modifier.fillMaxWidth().height(topInset + 56.dp + 12.dp).background(Brush.verticalGradient(0f to p.surface, 0.8f to p.surface.opacity(0.94f), 1f to Color.Transparent)))
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 8.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (showBack) GlassCircleButton(onBack, "Back") { GlyphView(Glyph.ChevronLeft, 20.dp, p.text, strokeWidth = 2.4f) }
            Column(Modifier.weight(1f).padding(start = if (showBack) 0.dp else 8.dp), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(space?.displayName ?: "Space", style = sans(13f, FontWeight.Medium), color = p.text, maxLines = 1)
                if (space != null) {
                    Text("${space.path} · ${state.deviceName(space.deviceId)}", style = sans(10.5f), color = p.textMuted.opacity(0.6f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            GlassCircleButton({ onOpen(Route.NewSession(NewSessionDestination.Project(spaceId))) }, "New session") { GlyphView(Glyph.Plus, 20.dp, p.text, strokeWidth = 2f) }
        }
    }
}
