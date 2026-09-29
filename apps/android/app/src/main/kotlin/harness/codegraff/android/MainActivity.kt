package harness.codegraff.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.viewmodel.compose.viewModel
import harness.codegraff.android.perf.Perf
import harness.codegraff.android.perf.PerfSharing
import harness.codegraff.android.theme.HarnessTheme
import harness.codegraff.android.theme.rememberThemeStore
import harness.codegraff.android.ui.HarnessApp

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        AppModel.scenario = intent?.getStringExtra("scenario")
        AppModel.chatGptResult = intent?.getStringExtra("chatgptResult")
        PerfSharing.init(this)
        // Only a launch counts as startup; a rotation or a return to the app is not one.
        if (Perf.isColdStart()) Perf.watchFirstFrame(this)
        setContent {
            val themeStore = rememberThemeStore()
            HarnessTheme(themeStore) {
                HarnessApp(model = viewModel())
            }
        }
    }

    override fun onResume() {
        super.onResume()
        Perf.resume(this)
    }

    override fun onPause() {
        Perf.pause(this)
        PerfSharing.flush(this)
        super.onPause()
    }
}
