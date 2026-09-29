package harness.codegraff.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.viewmodel.compose.viewModel
import harness.codegraff.android.theme.HarnessTheme
import harness.codegraff.android.ui.HarnessApp

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            HarnessTheme {
                HarnessApp(model = viewModel())
            }
        }
    }
}
