package harness.codegraff.android.ui

import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.layout.AnimatedPane
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffoldRole
import androidx.compose.material3.adaptive.layout.PaneAdaptedValue
import androidx.compose.material3.adaptive.navigation.NavigableListDetailPaneScaffold
import androidx.compose.material3.adaptive.navigation.rememberListDetailPaneScaffoldNavigator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import harness.codegraff.android.AppModel
import kotlinx.coroutines.launch

/**
 * The canonical Material 3 list-detail layout. On a phone or a folded cover
 * screen it is one pane with a back stack; on a tablet or an unfolded foldable
 * the sessions list and the open session sit side by side, and the scaffold
 * keeps both panes clear of the hinge. Back is predictive on Android 14+.
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
fun HarnessApp(model: AppModel) {
    val state by model.state.collectAsState()
    val navigator = rememberListDetailPaneScaffoldNavigator<String>()
    val scope = rememberCoroutineScope()

    NavigableListDetailPaneScaffold(
        navigator = navigator,
        listPane = {
            AnimatedPane {
                HomePane(
                    state = state,
                    selectedId = navigator.currentDestination?.contentKey,
                    onOpen = { id ->
                        model.markSeen(id)
                        scope.launch { navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, id) }
                    },
                )
            }
        },
        detailPane = {
            AnimatedPane {
                val chat = navigator.currentDestination?.contentKey?.let(state::chat)
                if (chat == null) {
                    EmptySessionPane()
                } else {
                    SessionPane(
                        chat = chat,
                        state = state,
                        // The list is hidden only in single-pane mode, the one case that needs a way back.
                        showBack = navigator.scaffoldValue[ListDetailPaneScaffoldRole.List] == PaneAdaptedValue.Hidden,
                        onBack = { scope.launch { navigator.navigateBack() } },
                        onSend = { model.send(chat.id, it) },
                    )
                }
            }
        },
    )
}
