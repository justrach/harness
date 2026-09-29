package harness.codegraff.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.lifecycle.viewmodel.compose.viewModel
import harness.codegraff.android.theme.HarnessTheme
import harness.codegraff.android.ui.HomeScreen
import harness.codegraff.android.ui.SessionScreen

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            HarnessTheme {
                HarnessApp()
            }
        }
    }
}

@Composable
fun HarnessApp(model: AppModel = viewModel()) {
    val state by model.state.collectAsState()
    val open = state.openChat
    if (open == null) {
        HomeScreen(state = state, onOpen = model::open)
    } else {
        SessionScreen(
            chat = open,
            state = state,
            onBack = model::back,
            onSend = { model.send(open.id, it) },
        )
    }
}
