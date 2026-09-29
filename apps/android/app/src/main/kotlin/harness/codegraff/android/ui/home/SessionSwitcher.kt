package harness.codegraff.android.ui.home

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import harness.codegraff.android.AppState
import harness.codegraff.android.model.Chat
import harness.codegraff.android.model.ChatIndicator
import harness.codegraff.android.model.HomeStatusFilter
import harness.codegraff.android.model.sortActive
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.sans
import harness.codegraff.android.ui.LocalSwitchToSession
import harness.codegraff.android.ui.components.HarnessSheet
import harness.codegraff.android.ui.components.glass

/**
 * The sessions you're juggling, in the order you last called them: anything running or waiting
 * on you, plus what you called recently, so a session that finished and was read stays put
 * instead of vanishing (SessionSwitcher.swift).
 */
class JuggledSessions(state: AppState) {
    val chats: List<Chat>
    private val indicators: Map<String, ChatIndicator>

    init {
        val picked = mutableListOf<Chat>()
        val marks = HashMap<String, ChatIndicator>()
        for (chat in sortActive(state.overviewChats)) {
            val indicator = state.indicator(chat)
            if (indicator == ChatIndicator.Idle && state.now - chat.calledAt >= RECENT_WINDOW_MS) continue
            picked += chat
            marks[chat.id] = indicator
            if (picked.size == LIMIT) break
        }
        chats = picked
        indicators = marks
    }

    fun indicator(chat: Chat): ChatIndicator = indicators[chat.id] ?: ChatIndicator.Idle

    fun others(chatId: String?): List<Chat> = chats.filter { it.id != chatId }

    fun count(filter: HomeStatusFilter, excluding: String?): Int =
        others(excluding).count { filter.matches(indicator(it)) }

    companion object {
        /** A session called this recently stays even once it's idle. */
        const val RECENT_WINDOW_MS = 3L * 60 * 60 * 1000
        const val LIMIT = 10
    }
}

private const val MAX_DOTS = 6

/**
 * Floating glass pill: one status dot per juggled session, in order, with the open one ringed.
 * Home adds "2 need you · 1 running"; the session screen keeps just the dots, sharing the
 * bottom with the composer.
 */
@Composable
fun SessionSwitcherPill(state: AppState, current: String?, compact: Boolean, modifier: Modifier = Modifier) {
    val juggled = JuggledSessions(state)
    val hasOthers = juggled.others(current).isNotEmpty()
    var showSheet by remember { mutableStateOf(false) }
    val p = Theme.palette
    val summary = summaryText(juggled, current)
    val description = "${juggled.others(current).size} other sessions" + (summary?.let { ", $it" } ?: "")

    AnimatedVisibility(hasOthers, modifier, enter = fadeIn() + scaleIn(initialScale = 0.9f), exit = fadeOut() + scaleOut(targetScale = 0.9f)) {
        Row(
            Modifier
                .height(if (compact) 36.dp else 44.dp)
                .glass(CircleShape, elevated = true)
                .clickable(role = Role.Button) { showSheet = true }
                .semantics { contentDescription = description }
                .padding(horizontal = if (compact) 12.dp else 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
                val shown = juggled.chats.take(MAX_DOTS)
                shown.forEach { chat ->
                    Box(Modifier.size(11.dp), contentAlignment = Alignment.Center) {
                        StatusMark(juggled.indicator(chat))
                        if (chat.id == current) {
                            Box(Modifier.size(11.dp).border(1.2.dp, p.text.opacity(0.7f), CircleShape))
                        }
                    }
                }
                val extra = juggled.chats.size - shown.size
                if (extra > 0) Text("+$extra", style = sans(12f, FontWeight.Medium), color = p.textMuted)
            }
            if (!compact && summary != null) Text(summary, style = sans(14f, FontWeight.Medium), color = p.text)
        }
    }
    if (showSheet) SessionSwitcherSheet(state, current) { showSheet = false }
}

/**
 * Running is a ring, needs you a filled dot, finished-and-read a quiet grey dot: shape carries
 * the state, since some themes paint running and needs-you in near-identical hues.
 */
@Composable
private fun StatusMark(indicator: ChatIndicator) {
    val p = Theme.palette
    when (indicator) {
        ChatIndicator.Working -> Box(Modifier.size(7.dp).border(1.8.dp, p.statusWorking, CircleShape))
        ChatIndicator.AwaitingInput, ChatIndicator.Errored, ChatIndicator.Completed ->
            Box(Modifier.size(7.dp).background(p.warning, CircleShape))
        ChatIndicator.Idle -> Box(Modifier.size(7.dp).background(p.ink(0.25f), CircleShape))
    }
}

private fun summaryText(juggled: JuggledSessions, current: String?): String? {
    val needsYou = juggled.count(HomeStatusFilter.Attention, current)
    val running = juggled.count(HomeStatusFilter.Running, current)
    val parts = buildList {
        if (needsYou > 0) add("$needsYou need you")
        if (running > 0) add("$running running")
    }
    return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
}

/** The pill's list: the juggled sessions in the same order, the open one marked. Picking a row jumps there. */
@Composable
fun SessionSwitcherSheet(state: AppState, current: String?, onDismiss: () -> Unit) {
    val juggled = JuggledSessions(state)
    val switchTo = LocalSwitchToSession.current
    val p = Theme.palette
    HarnessSheet("Your sessions", onDismiss) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            juggled.chats.forEach { chat ->
                Box(Modifier.fillMaxWidth()) {
                    ChatRow(chat, state, showLocation = true) {
                        onDismiss()
                        if (chat.id != current) switchTo?.invoke(chat.id)
                    }
                    if (chat.id == current) {
                        Box(
                            Modifier.align(Alignment.CenterStart).padding(vertical = 10.dp).width(3.dp).height(36.dp)
                                .clip(CircleShape).background(p.text.opacity(0.7f)),
                        )
                    }
                }
            }
            Text(
                "In the order you last called them. Sessions stay while they run or need you, and for a few hours after you last called them.",
                style = sans(12f), color = p.textMuted,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 16.dp),
            )
        }
    }
}
