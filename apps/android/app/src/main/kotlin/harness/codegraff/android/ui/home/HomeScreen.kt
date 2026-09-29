package harness.codegraff.android.ui.home

import androidx.compose.animation.core.animateFloatAsState
import harness.codegraff.android.model.ChatGPTComputer
import harness.codegraff.android.model.OnboardingState
import harness.codegraff.android.ui.signin.ChatGPTSignInSheet
import androidx.compose.ui.platform.testTag
import harness.codegraff.android.perf.Perf
import harness.codegraff.android.perf.PerfSpan
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.text.KeyboardOptions
import harness.codegraff.android.AppModel
import harness.codegraff.android.WorkspaceState
import harness.codegraff.android.model.Chat
import harness.codegraff.android.model.HomeFilter
import harness.codegraff.android.model.HomeGroup
import harness.codegraff.android.model.HomeGroupBy
import harness.codegraff.android.model.HomeGrouping
import harness.codegraff.android.model.HomeStatusFilter
import harness.codegraff.android.model.NewSessionDestination
import harness.codegraff.android.model.relativeTime
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.Glyph
import harness.codegraff.android.theme.GlyphView
import harness.codegraff.android.theme.HarnessBadge
import harness.codegraff.android.theme.Motion
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.sans
import harness.codegraff.android.ui.Route
import harness.codegraff.android.ui.components.GlassCircleButton
import harness.codegraff.android.ui.components.glass
import harness.codegraff.android.ui.components.navigationBarHeight
import harness.codegraff.android.ui.components.statusBarHeight
import harness.codegraff.android.ui.components.pressWashClickable
import harness.codegraff.android.ui.rememberPref

/**
 * Home, the mobile shell. The desktop sidebar collapses into one screen: a space dropdown in the
 * bar (default "All") scopes the attention-sorted session list below it. Close becomes
 * swipe-to-archive (HomeView.swift).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    state: WorkspaceState,
    model: AppModel,
    selectedChatId: String?,
    listState: LazyListState,
    onOpen: (Route) -> Unit,
    onShowSettings: () -> Unit,
    onShowNewSpace: () -> Unit,
    onShowHostPicker: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val p = Theme.palette
    // "" = All. Sticky across launches; falls back to All if the space is gone.
    val spaceFilter = rememberPref("homeSpaceFilter", "")
    val groupByPref = rememberPref("homeGroupBy", HomeGroupBy.None.name.lowercase())
    val collapsedPref = rememberPref("homeCollapsedGroups", "")
    // Not persisted: a filter left on across launches reads as lost sessions.
    var searchText by rememberSaveable { mutableStateOf("") }
    var statusFilter by rememberSaveable { mutableStateOf(HomeStatusFilter.All) }
    // Lives here, not in the empty state: an agent turning on mid-sign-in swaps that state out from under the sheet.
    var chatGPTComputers by remember { mutableStateOf<List<ChatGPTComputer>?>(null) }

    val selectedSpace = state.spaces.firstOrNull { it.id == spaceFilter.value }
    val grouping = HomeGroupBy.fromKey(groupByPref.value)
    val collapsedGroups = collapsedPref.value.split(',').filter { it.isNotEmpty() }.toSet()
    // Filtering, grouping and counting are the list's real work: redo it only when an input changes,
    // not on every recomposition (typing in search, a dropdown opening, a chip animating).
    val scoped = remember(state, selectedSpace) { selectedSpace?.let { state.chatsIn(it.id) } ?: state.overviewChats }
    val chats = remember(state, scoped, searchText, statusFilter) {
        HomeFilter.apply(scoped, searchText, statusFilter, state::indicator, state::filterNames)
    }
    val groups = remember(chats, grouping, state.pinnedSessionIds) {
        Perf.measure(PerfSpan.HomeGroup) { HomeGrouping.groups(chats, grouping, state.pinnedSessionIds.toSet()) }
    }
    val counts = remember(state, scoped) { statusCounts(state, scoped) }
    val archived = remember(state, selectedSpace, searchText) { state.archivedMatches(selectedSpace?.id, searchText) }
    val topInset = statusBarHeight()

    val chatGPT = model.chatGPTSignIn
    if (chatGPT != null) {
        chatGPTComputers?.let { ChatGPTSignInSheet(it, chatGPT, onDismiss = { chatGPTComputers = null }) }
    }

    Box(modifier.fillMaxSize().background(p.surface)) {
        LazyColumn(
            Modifier.fillMaxSize(),
            state = listState,
            contentPadding = PaddingValues(
                top = topInset + 56.dp,
                bottom = 148.dp + navigationBarHeight(),
            ),
        ) {
            if (scoped.isNotEmpty()) {
                item(key = "filters") {
                    Row(
                        // Chips draw 28dp inside 44dp touch targets, so the row needs less padding to keep its rhythm.
                        Modifier.padding(start = 16.dp, end = 16.dp, top = 0.dp, bottom = 0.dp).horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        HomeStatusChips(statusFilter, counts) { statusFilter = it }
                        GroupPill(grouping) { groupByPref.set(it.name.lowercase()) }
                    }
                }
            }
            if (chats.isEmpty()) {
                val archivedHit = statusFilter == HomeStatusFilter.All && searchText.isNotEmpty() && archived.isNotEmpty()
                if (!archivedHit) {
                    item(key = "empty") {
                        val readiness = state.agentReadiness
                        if (scoped.isEmpty() && readiness.state != OnboardingState.Ready) {
                            // Nothing started yet: until an agent is ready on a computer, say how to bring one in.
                            BringYourAgent(readiness, state::deviceName, chatGPT = model.chatGPTSignIn != null) { chatGPTComputers = it }
                        } else {
                            Text(
                                if (scoped.isEmpty()) "No sessions yet — start one with +" else "No matching sessions",
                                style = sans(12f), color = p.textFaint,
                                modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp).testTag("home-empty"),
                            )
                        }
                    }
                }
            } else {
                groups.forEach { group ->
                    val collapsed = grouping != HomeGroupBy.None && group.id in collapsedGroups
                    if (grouping != HomeGroupBy.None) {
                        item(key = "header-${group.id}") {
                            HomeGroupHeader(group, state, collapsed) {
                                val next = if (group.id in collapsedGroups) collapsedGroups - group.id else collapsedGroups + group.id
                                collapsedPref.set(next.sorted().joinToString(","))
                            }
                        }
                    }
                    if (!collapsed) {
                        items(group.chats, key = { it.id }, contentType = { "session" }) { chat ->
                            // Rows glide to their new place when the order changes (Motion.resort).
                            SessionRow(
                                chat, state, model, selected = chat.id == selectedChatId,
                                modifier = Modifier.animateItem(fadeInSpec = null, placementSpec = Motion.resort(), fadeOutSpec = null),
                            ) { onOpen(Route.Chat(chat.id)) }
                        }
                    }
                }
            }
            // The desktop's archived shelf sits under the active list, scoped by the same space
            // filter and search. Archived sessions are never running or waiting, so a status filter hides it.
            if (statusFilter == HomeStatusFilter.All && archived.isNotEmpty()) {
                archivedShelf(archived, state, model, selectedChatId, onOpen)
            }
        }

        // The bar floats over the list: an opaque strip under the status bar, then a soft fade.
        Box(
            Modifier.fillMaxWidth().height(topInset + 56.dp + 16.dp)
                .background(Brush.verticalGradient(0f to p.surface, 0.78f to p.surface.opacity(0.94f), 1f to Color.Transparent)),
        )
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 16.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            SpaceDropdown(state, selectedSpace?.displayName, spaceFilter.value, { spaceFilter.set(it) }, onShowNewSpace)
            Spacer(Modifier.weight(1f))
            // One glass capsule holds both trailing controls, like the native toolbar group.
            Row(Modifier.height(44.dp).glass(CircleShape, elevated = true), verticalAlignment = Alignment.CenterVertically) {
                NewButton(state, selectedSpace?.id, onOpen, onShowHostPicker, onShowNewSpace)
                Box(
                    Modifier.size(width = 56.dp, height = 44.dp).clickable(role = Role.Button, onClick = onShowSettings)
                        .semantics { contentDescription = "Settings" },
                    contentAlignment = Alignment.Center,
                ) { GlyphView(Glyph.PersonCircle, 22.dp, p.text, strokeWidth = 1.7f) }
            }
        }

        // Bottom stack, over the list: the session switcher pill, then search (iOS 26 puts search at the bottom).
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(bottom = 8.dp + navigationBarHeight()).imePadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            SessionSwitcherPill(state, current = null, compact = false)
            SearchField(searchText, { searchText = it }, Modifier.padding(horizontal = 16.dp))
        }
    }
}

private fun statusCounts(state: WorkspaceState, chats: List<Chat>): Map<HomeStatusFilter, Int> {
    val counts = HashMap<HomeStatusFilter, Int>()
    for (chat in chats) {
        val indicator = state.indicator(chat)
        for (filter in HomeStatusFilter.entries) if (filter.matches(indicator)) counts[filter] = (counts[filter] ?: 0) + 1
    }
    return counts
}

// MARK: bar controls

@Composable
private fun SpaceDropdown(state: WorkspaceState, title: String?, selectedId: String, onSelect: (String) -> Unit, onNewSpace: () -> Unit) {
    val p = Theme.palette
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.height(44.dp).glass(CircleShape, elevated = true)
                .clickable(role = Role.Button) { open = true }
                .semantics { contentDescription = "Filter by space" }
                .padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Text(title ?: "All", style = sans(16f, FontWeight.SemiBold), color = p.text, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 200.dp))
            GlyphView(Glyph.ChevronDown, 10.dp, p.textFaint, strokeWidth = 3f)
        }
        HarnessMenu(open, { open = false }) {
            MenuRow("All", null, selectedId.isEmpty() || state.spaces.none { it.id == selectedId }) { onSelect(""); open = false }
            state.spaces.forEach { space ->
                MenuRow(space.displayName, deviceTag(state, space.deviceId), space.id == selectedId) { onSelect(space.id); open = false }
            }
            HorizontalDivider(color = p.border)
            MenuRow("New space…", null, false, glyph = Glyph.FolderPlus) { open = false; onNewSpace() }
        }
    }
}

private fun deviceTag(state: WorkspaceState, deviceId: String): String =
    if (state.deviceOnline(deviceId)) "@ ${state.deviceName(deviceId)}" else "@ ${state.deviceName(deviceId)} · offline"

@Composable
private fun NewButton(
    state: WorkspaceState,
    selectedSpaceId: String?,
    onOpen: (Route) -> Unit,
    onShowHostPicker: () -> Unit,
    onShowNewSpace: () -> Unit,
) {
    val p = Theme.palette
    var open by remember { mutableStateOf(false) }
    Box {
        Box(
            Modifier.size(width = 56.dp, height = 44.dp).clickable(role = Role.Button) { open = true }
                .semantics { contentDescription = "New session" },
            contentAlignment = Alignment.Center,
        ) { GlyphView(Glyph.Plus, 20.dp, p.text, strokeWidth = 2f) }
        HarnessMenu(open, { open = false }) {
            val selected = state.spaces.firstOrNull { it.id == selectedSpaceId }
            if (selected != null) {
                MenuRow("New session in ${selected.displayName}", null, false) {
                    open = false; onOpen(Route.NewSession(NewSessionDestination.Project(selected.id)))
                }
            } else if (state.spaces.isNotEmpty()) {
                Text("New session in…", style = sans(12f, FontWeight.Medium), color = p.textMuted, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
                state.spaces.forEach { space ->
                    MenuRow(space.displayName, deviceTag(state, space.deviceId), false) {
                        open = false; onOpen(Route.NewSession(NewSessionDestination.Project(space.id)))
                    }
                }
            }
            MenuRow("Session without a project…", null, false, glyph = Glyph.Close) { open = false; onShowHostPicker() }
            MenuRow("New space…", null, false, glyph = Glyph.FolderPlus) { open = false; onShowNewSpace() }
        }
    }
}

@Composable
internal fun HarnessMenu(expanded: Boolean, onDismiss: () -> Unit, content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit) {
    DropdownMenu(
        expanded = expanded, onDismissRequest = onDismiss,
        shape = RoundedCornerShape(18.dp),
        containerColor = Theme.palette.surfaceDialog,
        border = androidx.compose.foundation.BorderStroke(1.dp, Theme.palette.hairline(0.08f)),
        content = content,
    )
}

@Composable
internal fun MenuRow(
    title: String, subtitle: String?, selected: Boolean, glyph: Glyph? = null,
    enabled: Boolean = true, destructive: Boolean = false, onClick: () -> Unit,
) {
    val p = Theme.palette
    DropdownMenuItem(
        enabled = enabled,
        text = {
            Column {
                Text(title, style = sans(15f), color = if (destructive) p.danger else p.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (subtitle != null) Text(subtitle, style = sans(12f), color = p.textMuted)
            }
        },
        leadingIcon = {
            Box(Modifier.size(20.dp), contentAlignment = Alignment.Center) {
                when {
                    selected -> GlyphView(Glyph.Check, 16.dp, p.text, strokeWidth = 2.4f)
                    glyph != null -> GlyphView(glyph, 16.dp, p.textMuted)
                }
            }
        },
        onClick = onClick,
    )
}

@Composable
private fun SearchField(text: String, onChange: (String) -> Unit, modifier: Modifier = Modifier) {
    val p = Theme.palette
    Row(
        modifier.fillMaxWidth().height(52.dp).glass(CircleShape, elevated = true).padding(horizontal = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        GlyphView(Glyph.Search, 16.dp, p.textMuted)
        Box(Modifier.weight(1f)) {
            if (text.isEmpty()) Text("Search sessions", style = sans(16f), color = p.textFaint)
            BasicTextField(
                value = text, onValueChange = onChange, singleLine = true,
                textStyle = sans(16f).copy(color = p.text), cursorBrush = SolidColor(p.text),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Search sessions" },
            )
        }
        if (text.isNotEmpty()) {
            Box(Modifier.size(28.dp).clip(CircleShape).clickable { onChange("") }.semantics { contentDescription = "Clear search" }, contentAlignment = Alignment.Center) {
                GlyphView(Glyph.Close, 12.dp, p.textMuted, strokeWidth = 2.4f)
            }
        }
    }
}

// MARK: chips

/** All · Needs you · Running, with live counts. Sits above the list. */
@Composable
private fun HomeStatusChips(selection: HomeStatusFilter, counts: Map<HomeStatusFilter, Int>, onSelect: (HomeStatusFilter) -> Unit) {
    val p = Theme.palette
    HomeStatusFilter.entries.forEach { filter ->
        val selected = selection == filter
        val count = counts[filter] ?: 0
        // The chip is drawn 28dp tall but the touch target is the full 44dp row.
        Box(
            Modifier.heightIn(min = 44.dp)
                // Tapping the active chip again clears it.
                .clickable(interactionSource = null, indication = null, role = Role.Tab) {
                    onSelect(if (selected && filter != HomeStatusFilter.All) HomeStatusFilter.All else filter)
                }
                .semantics { this.selected = selected },
            contentAlignment = Alignment.Center,
        ) {
            Row(
                Modifier.height(28.dp)
                    .background(if (selected) p.elementActive else Color.Transparent, CircleShape)
                    .border(1.dp, if (selected) Color.Transparent else p.border, CircleShape)
                    .padding(horizontal = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                if (filter != HomeStatusFilter.All) {
                    Box(Modifier.size(6.dp).background(if (filter == HomeStatusFilter.Running) p.statusWorking else p.warning, CircleShape))
                }
                Text(filter.label, style = sans(13f, if (selected) FontWeight.SemiBold else FontWeight.Medium), color = if (selected) p.text else p.textMuted)
                if (filter != HomeStatusFilter.All && count > 0) {
                    Text("$count", style = sans(12f, FontWeight.Medium), color = if (selected) p.text else p.textFaint)
                }
            }
        }
    }
}

/** Grouping sits on the filter row as a labeled pill: one tap opens the choices, one tap picks. */
@Composable
private fun GroupPill(grouping: HomeGroupBy, onSelect: (HomeGroupBy) -> Unit) {
    val p = Theme.palette
    var open by remember { mutableStateOf(false) }
    val grouped = grouping != HomeGroupBy.None
    Box {
        Box(
            Modifier.heightIn(min = 44.dp)
                .clickable(interactionSource = null, indication = null, role = Role.Button) { open = true }
                .semantics { contentDescription = "Group by"; stateDescription = grouping.label },
            contentAlignment = Alignment.Center,
        ) {
            Row(
                Modifier.height(28.dp)
                    .background(if (grouped) p.elementActive else Color.Transparent, CircleShape)
                    .border(1.dp, if (grouped) Color.Transparent else p.border, CircleShape)
                    .padding(horizontal = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                GlyphView(groupGlyph(grouping, true), 12.dp, if (grouped) p.text else p.textMuted, strokeWidth = 2f)
                Text(if (grouped) grouping.label else "Group", style = sans(13f, if (grouped) FontWeight.SemiBold else FontWeight.Medium), color = if (grouped) p.text else p.textMuted)
                GlyphView(Glyph.ChevronDown, 9.dp, p.textFaint, strokeWidth = 3f)
            }
        }
        HarnessMenu(open, { open = false }) {
            HomeGroupBy.entries.forEach { option ->
                MenuRow(option.label, null, option == grouping, glyph = groupGlyph(option, false)) { onSelect(option); open = false }
            }
        }
    }
}

private fun groupGlyph(by: HomeGroupBy, pill: Boolean): Glyph = when (by) {
    HomeGroupBy.None -> if (pill) Glyph.Layers else Glyph.List
    HomeGroupBy.Project -> Glyph.Folder
    HomeGroupBy.Device -> Glyph.Laptop
}

/** A section header: the project's color dot or the device's online dot, the name, the session count, and a chevron that collapses. */
@Composable
private fun HomeGroupHeader(group: HomeGroup, state: WorkspaceState, collapsed: Boolean, toggle: () -> Unit) {
    val p = Theme.palette
    val title = when (val kind = group.kind) {
        HomeGroup.Kind.All -> "All"
        HomeGroup.Kind.Pinned -> "Pinned"
        is HomeGroup.Kind.Project -> kind.spaceId?.let { id -> state.spaces.firstOrNull { it.id == id }?.displayName }
            ?: if (kind.spaceId == null) "No project" else (group.chats.firstOrNull()?.cwd?.trimEnd('/')?.substringAfterLast('/') ?: "Project")
        is HomeGroup.Kind.Device -> state.deviceName(kind.deviceId)
    }
    val rotation by animateFloatAsState(if (collapsed) -90f else 0f, label = "chevron")
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 12.dp).padding(top = 8.dp, bottom = 2.dp)
            .pressWashClickable(toggle, cornerRadius = 8.dp)
            .semantics { contentDescription = "$title, ${group.chats.size} sessions"; stateDescription = if (collapsed) "Collapsed" else "Expanded" }
            .padding(horizontal = 8.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        when (val kind = group.kind) {
            HomeGroup.Kind.Pinned -> GlyphView(Glyph.Pin, 12.dp, p.textMuted, strokeWidth = 2f)
            is HomeGroup.Kind.Project ->
                if (kind.spaceId != null) Box(Modifier.size(8.dp).background(p.projectTint(kind.spaceId), CircleShape))
                else Box(Modifier.size(8.dp).border(1.5.dp, p.textFaint, CircleShape))
            is HomeGroup.Kind.Device -> Box {
                GlyphView(deviceGlyph(state, kind.deviceId), 14.dp, p.textMuted)
                Box(
                    Modifier.align(Alignment.BottomEnd).size(6.dp)
                        .background(if (state.deviceOnline(kind.deviceId)) p.statusCompleted else p.textFaint, CircleShape),
                )
            }
            else -> Box(Modifier.size(8.dp).border(1.5.dp, p.textFaint, CircleShape))
        }
        Text(title, style = sans(13f, FontWeight.SemiBold), color = p.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text("${group.chats.size}", style = sans(12f, FontWeight.Medium), color = p.textFaint)
        Spacer(Modifier.weight(1f))
        Box(Modifier.rotate(rotation)) { GlyphView(Glyph.ChevronDown, 11.dp, p.textFaint, strokeWidth = 3f) }
    }
}

private fun deviceGlyph(state: WorkspaceState, deviceId: String): Glyph = when (state.devices.firstOrNull { it.id == deviceId }?.platform) {
    "linux" -> Glyph.Server
    "windows" -> Glyph.Monitor
    "ios" -> Glyph.Phone
    else -> Glyph.Laptop
}

// MARK: rows

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SessionRow(
    chat: Chat, state: WorkspaceState, model: AppModel, selected: Boolean,
    modifier: Modifier = Modifier, onOpen: () -> Unit,
) {
    val p = Theme.palette
    val pinned = state.isPinned(chat.id)
    val swipe = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            when (value) {
                SwipeToDismissBoxValue.EndToStart -> { model.archive(chat.id); true }
                SwipeToDismissBoxValue.StartToEnd -> { model.setPinned(chat.id, !pinned); false }
                SwipeToDismissBoxValue.Settled -> false
            }
        },
    )
    SwipeToDismissBox(
        state = swipe,
        modifier = modifier.padding(horizontal = 12.dp, vertical = 1.dp),
        backgroundContent = {
            val towardArchive = swipe.dismissDirection == SwipeToDismissBoxValue.EndToStart
            val towardPin = swipe.dismissDirection == SwipeToDismissBoxValue.StartToEnd
            Box(
                Modifier.fillMaxSize().clip(RoundedCornerShape(10.dp))
                    .background(if (towardPin) p.accent else if (towardArchive) p.surfaceRaised else Color.Transparent)
                    .padding(horizontal = 20.dp),
                contentAlignment = if (towardPin) Alignment.CenterStart else Alignment.CenterEnd,
            ) {
                if (towardPin) GlyphView(Glyph.Pin, 20.dp, p.accentOn, strokeWidth = 2f)
                if (towardArchive) GlyphView(Glyph.Archive, 20.dp, p.text, strokeWidth = 2f)
            }
        },
    ) {
        Box(
            Modifier.fillMaxWidth()
                .background(p.surface)
                .background(if (selected) p.elementActive else Color.Transparent, RoundedCornerShape(10.dp)),
        ) {
            ChatRow(chat, state, showLocation = true, modifier = Modifier.padding(horizontal = 0.dp), onSelect = onOpen)
        }
    }
}

// MARK: archived shelf

private const val ARCHIVED_INITIAL = 10
private const val ARCHIVED_PAGE = 25

/**
 * The desktop sidebar's settled shelf for archived sessions: a hairline header that folds
 * ("Archived" open, "Archived (N)" collapsed), slim rows, and Show-more paging (10, then +25).
 * Swipe-to-unarchive mirrors the active rows' swipe-to-archive (ArchivedShelf.swift).
 */
internal fun androidx.compose.foundation.lazy.LazyListScope.archivedShelf(
    archived: List<Chat>, state: WorkspaceState, model: AppModel, selectedChatId: String?, onOpen: (Route) -> Unit,
) {
    item(key = "archived") {
        var open by rememberSaveable { mutableStateOf(true) }
        var shown by rememberSaveable { mutableIntStateOf(ARCHIVED_INITIAL) }
        val p = Theme.palette
        Column {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 12.dp)
                    .pressWashClickable({ open = !open; shown = ARCHIVED_INITIAL }, cornerRadius = 6.dp)
                    .semantics { contentDescription = if (open) "Collapse archived" else "Expand archived, ${archived.size} sessions" }
                    .heightIn(min = 44.dp).padding(horizontal = 10.dp).padding(top = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(if (open) "Archived" else "Archived (${archived.size})", style = sans(12f, FontWeight.Medium), color = p.textMuted.opacity(0.5f))
                Box(Modifier.weight(1f).height(1.dp).background(p.border.opacity(0.6f)))
                GlyphView(if (open) Glyph.ChevronDown else Glyph.ChevronRight, 10.dp, p.textMuted.opacity(0.5f), strokeWidth = 2.6f)
            }
            if (open) {
                archived.take(shown).forEach { chat -> ArchivedRow(chat, state, model) { onOpen(Route.Chat(chat.id)) } }
                if (archived.size > shown) {
                    val remaining = archived.size - shown
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 12.dp)
                            .pressWashClickable({ shown = maxOf(shown, ARCHIVED_INITIAL) + ARCHIVED_PAGE }, cornerRadius = 6.dp)
                            .padding(horizontal = 10.dp).height(44.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        GlyphView(Glyph.Plus, 13.dp, p.textMuted.opacity(0.55f), strokeWidth = 2.2f)
                        Text("Show ${minOf(remaining, ARCHIVED_PAGE)} more", style = sans(15f), color = p.textMuted.opacity(0.55f))
                    }
                }
            }
        }
    }
}

/** Slim row: dimmed harness mark, muted title, time-ago (spaces.rs archived row). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ArchivedRow(chat: Chat, state: WorkspaceState, model: AppModel, onOpen: () -> Unit) {
    val p = Theme.palette
    val swipe = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            if (value == SwipeToDismissBoxValue.EndToStart) { model.unarchive(chat.id); true } else false
        },
    )
    SwipeToDismissBox(
        state = swipe, enableDismissFromStartToEnd = false,
        modifier = Modifier.padding(horizontal = 12.dp),
        backgroundContent = {
            Box(
                Modifier.fillMaxSize().clip(RoundedCornerShape(6.dp)).background(p.surfaceRaised).padding(horizontal = 20.dp),
                contentAlignment = Alignment.CenterEnd,
            ) { GlyphView(Glyph.Unarchive, 20.dp, p.text, strokeWidth = 2f) }
        },
    ) {
        Row(
            Modifier.fillMaxWidth().background(p.surface).pressWashClickable(onOpen, cornerRadius = 6.dp)
                .padding(horizontal = 10.dp).height(44.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            chat.config?.harness?.let { HarnessBadge(it, 14.dp, dimmed = true) }
            Text(chat.displayTitle, style = sans(15f), color = p.text.opacity(0.55f), maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            Text(relativeTime(chat.lastMessageAt ?: chat.createdAt, state.now), style = sans(13f), color = p.textMuted.opacity(0.55f), maxLines = 1)
        }
    }
}
