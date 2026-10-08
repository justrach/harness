package harness.codegraff.android.ui

import kotlinx.coroutines.launch
import harness.codegraff.android.perf.Perf
import harness.codegraff.android.perf.PerfSpan
import androidx.compose.runtime.rememberCoroutineScope
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfo
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import harness.codegraff.android.AppModel
import harness.codegraff.android.model.NewSessionDestination
import harness.codegraff.android.theme.Glyph
import harness.codegraff.android.theme.GlyphView
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.sans
import harness.codegraff.android.ui.home.HomeScreen
import harness.codegraff.android.ui.home.SpaceScreen
import harness.codegraff.android.ui.newsession.NewSessionScreen
import harness.codegraff.android.ui.session.SessionScreen
import harness.codegraff.android.ui.settings.SettingsSheet
import harness.codegraff.android.ui.sheets.NewSpaceSheet
import harness.codegraff.android.ui.sheets.SessionHostPickerSheet
import harness.codegraff.android.ui.signin.SignInScreen

/** iPad-style regular width: the session list becomes a sidebar next to the open session, like the desktop. */
private val SplitBreakpoint = 600.dp
private val SidebarWidth = 380.dp

/**
 * The app shell (HomeView.swift): a phone keeps one stack (Home, then a session, space or new-session
 * page pushed over it); a tablet or unfolded foldable puts Home beside the open page, and picking a row
 * replaces the detail instead of stacking behind it. When a hinge splits the screen, the sidebar ends at the fold.
 */
@Composable
fun HarnessApp(model: AppModel) {
    val state by model.workspace.collectAsState()
    // Keeps relative times and stale-session checks moving without tying them to every write.
    LaunchedEffect(model) { model.runClock() }
    var signedIn by rememberSaveable { mutableStateOf(true) }
    if (!signedIn) {
        SignInScreen(onDemo = { signedIn = true })
        return
    }

    var path by rememberSaveable(stateSaver = Route.PathSaver) { mutableStateOf(listOf<Route>()) }
    var showSettings by rememberSaveable { mutableStateOf(false) }
    var showNewSpace by rememberSaveable { mutableStateOf(false) }
    var showHostPicker by rememberSaveable { mutableStateOf(false) }
    val homeListState = rememberLazyListState()
    val p = Theme.palette

    BackHandler(enabled = path.isNotEmpty()) { path = path.dropLast(1) }

    BoxWithConstraints(Modifier.fillMaxSize().background(p.bg)) {
        val split = maxWidth >= SplitBreakpoint
        val density = LocalDensity.current
        val hingeLeft: Dp? = currentWindowAdaptiveInfo().windowPosture.hingeList
            .firstOrNull { it.isSeparating && it.isVertical }?.bounds?.left?.let { with(density) { it.toDp() } }
        val sidebar = hingeLeft?.takeIf { it in 240.dp..(maxWidth - 240.dp) } ?: SidebarWidth

        /** Open a route from the list. In the split layout the sidebar replaces what the detail shows instead of stacking behind it. */
        fun open(route: Route) {
            // Only opening a chat is timed, the same journey the desktop reports as conversation_load_ms.
            if (route is Route.Chat) Perf.startInteraction(PerfSpan.NavigationOpen)
            path = if (split) listOf(route) else path + route
        }

        /** The session switcher's jump: from inside a session, swap that session out instead of stacking another. */
        fun switchTo(chatId: String) {
            if (!split && path.lastOrNull() is Route.Chat) path = path.dropLast(1) + Route.Chat(chatId) else open(Route.Chat(chatId))
        }

        val selectedChatId = if (split) (path.firstOrNull() as? Route.Chat)?.id else null

        @Composable
        fun Home(modifier: Modifier) = HomeScreen(
            state, model, selectedChatId, homeListState,
            onOpen = ::open,
            onShowSettings = { showSettings = true },
            onShowNewSpace = { showNewSpace = true },
            onShowHostPicker = { showHostPicker = true },
            modifier = modifier,
        )

        @Composable
        fun Page(route: Route, modifier: Modifier) {
            val back = { path = path.dropLast(1) }
            // Tap to first frame of the page it opened.
            LaunchedEffect(route) { Perf.finishInteraction(PerfSpan.NavigationOpen) }
            when (route) {
                is Route.Chat -> SessionScreen(route.id, state, model, showBack = !split, onBack = back, modifier = modifier)
                is Route.Space -> SpaceScreen(route.id, state, model, showBack = !split, onBack = back, onOpen = ::open, modifier = modifier)
                is Route.NewSession -> NewSessionScreen(
                    route.destination, state, model, showBack = !split, onBack = back,
                    // Replace the canvas with the live session (in-place swap, no back-through-canvas).
                    onCreated = { chatId -> path = if (split) listOf(Route.Chat(chatId)) else path.dropLast(1) + Route.Chat(chatId) },
                    modifier = modifier,
                )
            }
        }

        CompositionLocalProvider(LocalSwitchToSession provides ::switchTo) {
            if (split) {
                Row(Modifier.fillMaxSize()) {
                    Home(Modifier.width(sidebar).fillMaxHeight())
                    val current = path.lastOrNull()
                    if (current == null) SplitDetailPlaceholder(Modifier.weight(1f).fillMaxHeight())
                    else Page(current, Modifier.weight(1f).fillMaxHeight())
                }
            } else {
                AnimatedContent(
                    targetState = path,
                    transitionSpec = {
                        val forward = targetState.size > initialState.size
                        val spec = tween<androidx.compose.ui.unit.IntOffset>(260)
                        (slideInHorizontally(spec) { if (forward) it else -it / 3 } togetherWith
                            slideOutHorizontally(spec) { if (forward) -it / 3 else it }).using(SizeTransform(clip = false))
                    },
                    label = "stack",
                ) { stack ->
                    val current = stack.lastOrNull()
                    if (current == null) Home(Modifier.fillMaxSize()) else Page(current, Modifier.fillMaxSize())
                }
            }
        }
    }

    if (showSettings) {
        val deletion by model.accountDeletion.collectAsState()
        val scope = rememberCoroutineScope()
        SettingsSheet(
            onDismiss = { showSettings = false },
            onSignOut = { signedIn = false; path = emptyList() },
            canDeleteAccount = model.canDeleteAccount,
            deletion = deletion,
            // No live account backend yet: the row is hidden in the offline demo, so this is only the seam.
            onDeleteAccount = { scope.launch { model.deleteAccount(api = null) } },
            onDismissDeletionError = model::dismissAccountDeletionError,
            workspace = state,
            loadCompactAt = model::graffCompactAt,
            saveCompactAt = model::setGraffCompactAt,
        )
    }
    if (showNewSpace) {
        NewSpaceSheet(state, model, onCreated = { id -> path = listOf(Route.Space(id)) }, onDismiss = { showNewSpace = false })
    }
    if (showHostPicker) {
        SessionHostPickerSheet(
            state, selectedDeviceId = null,
            onSelected = { deviceId -> path = listOf(Route.NewSession(NewSessionDestination.Projectless(deviceId))) },
            onDismiss = { showHostPicker = false },
        )
    }
}

/** The split layout's detail column before a session is picked. */
@Composable
private fun SplitDetailPlaceholder(modifier: Modifier = Modifier) {
    val p = Theme.palette
    Column(modifier.background(p.bg), verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically), horizontalAlignment = Alignment.CenterHorizontally) {
        GlyphView(Glyph.Chat, 32.dp, p.textFaint, strokeWidth = 1.1f)
        Text("Pick a session, or start one with +", style = sans(15f), color = p.textMuted)
    }
}
