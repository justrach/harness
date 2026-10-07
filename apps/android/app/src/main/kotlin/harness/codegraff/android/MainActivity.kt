package harness.codegraff.android

import android.content.pm.ApplicationInfo
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import harness.codegraff.android.perf.Perf
import harness.codegraff.android.perf.PerfSharing
import harness.codegraff.android.sync.LiveConnection
import harness.codegraff.android.sync.LiveSync
import harness.codegraff.android.theme.HarnessTheme
import harness.codegraff.android.theme.rememberThemeStore
import harness.codegraff.android.ui.HarnessApp

class MainActivity : ComponentActivity() {
    private val model: AppModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        AppModel.scenario = intent?.getStringExtra("scenario")
        devEdge()?.let { connection -> AppModel.liveFactory = { LiveSync.open(applicationContext, connection) } }
        PerfSharing.init(this)
        // Only a launch counts as startup; a rotation or a return to the app is not one.
        if (Perf.isColdStart()) Perf.watchFirstFrame(this)
        setContent {
            val themeStore = rememberThemeStore()
            HarnessTheme(themeStore) {
                HarnessApp(model = model)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        Perf.resume(this)
        model.foregrounded()
    }

    override fun onPause() {
        model.backgrounded()
        Perf.pause(this)
        PerfSharing.flush(this)
        super.onPause()
    }

    /**
     * Debug rig for a dev-mode edge (`AUTH_MODE=dev`), the counterpart of the iOS launch arguments `-setedge`,
     * `-setmode dev`, `-setuser` and `-setorg`:
     * `adb shell am start -n harness.codegraff.android/.MainActivity --es edge http://10.0.2.2:27640 --es user u1 --es org o1`.
     * Only debuggable builds read it.
     */
    private fun devEdge(): LiveConnection? {
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) return null
        val extras = intent?.extras ?: return null
        val edge = extras.getString("edge") ?: return null
        val user = extras.getString("user") ?: return null
        return LiveConnection.dev(edge, user, extras.getString("org").orEmpty())
    }
}
