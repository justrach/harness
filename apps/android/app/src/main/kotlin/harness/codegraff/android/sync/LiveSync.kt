package harness.codegraff.android.sync

import android.content.Context
import android.util.Log
import harness.codegraff.android.core.ConnectivitySnapshot
import harness.codegraff.android.core.CoreConfig
import harness.codegraff.android.core.CoreListener
import harness.codegraff.android.core.LogSink
import harness.codegraff.android.core.MobileCore
import harness.codegraff.android.core.MobileCoreInterface
import harness.codegraff.android.core.SessionSnapshot
import harness.codegraff.android.core.TokenSource
import harness.codegraff.android.core.WorkspaceSnapshot
import harness.codegraff.android.core.installLogSink
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import java.io.File
import java.util.UUID

/**
 * Where and as whom the phone syncs (the iOS `AppConfig`). [bearer] supplies the token for every request; a dev edge
 * (`AUTH_MODE=dev`) takes `userId@orgId`.
 */
data class LiveConnection(
    val edgeUrl: String,
    val userId: String,
    val orgId: String,
    val bearer: () -> String?,
) {
    companion object {
        /** The dev-edge bearer (`AppModel.devBearer` on iOS). */
        fun dev(edgeUrl: String, userId: String, orgId: String): LiveConnection {
            val bearer = if (orgId.isEmpty()) userId else "$userId@$orgId"
            return LiveConnection(edgeUrl, userId, orgId) { bearer }
        }
    }
}

/**
 * Everything the native core has published, as flows. The core calls in on its own threads; a state flow is safe to
 * set from any of them.
 */
class LiveFeed : CoreListener {
    private val _workspace = MutableStateFlow<WorkspaceSnapshot?>(null)
    private val _sessions = MutableStateFlow<Map<String, SessionSnapshot>>(emptyMap())
    private val _connectivity = MutableStateFlow<ConnectivitySnapshot?>(null)

    val workspace: StateFlow<WorkspaceSnapshot?> get() = _workspace

    /** Each open chat's latest snapshot. A chat's entry is replaced only when that chat changes. */
    val sessions: StateFlow<Map<String, SessionSnapshot>> get() = _sessions

    override fun workspaceChanged(snapshot: WorkspaceSnapshot) {
        _workspace.value = snapshot
    }

    override fun sessionChanged(snapshot: SessionSnapshot) {
        _sessions.update { it + (snapshot.chatId to snapshot) }
    }

    /** The graced connectivity state, published only when it changes. */
    val connectivity: StateFlow<ConnectivitySnapshot?> get() = _connectivity

    override fun connectivityChanged(snapshot: ConnectivitySnapshot) {
        _connectivity.value = snapshot
    }
}

/** A running live sync: the core (behind its interface, so tests can stand one in) and what it publishes. */
class LiveSync(val core: MobileCoreInterface, val feed: LiveFeed) {
    companion object {
        private const val TAG = "HarnessSync"

        /**
         * Open the core for [connection]. Docs live under the app's files, one directory per signed-in identity, so
         * another account never reads this one's cache.
         */
        fun open(context: Context, connection: LiveConnection): LiveSync {
            installLogSink(object : LogSink {
                override fun log(level: String, target: String, message: String) {
                    when (level) {
                        "error" -> Log.e(TAG, "$target: $message")
                        "warn" -> Log.w(TAG, "$target: $message")
                        else -> Log.i(TAG, "$target: $message")
                    }
                }
            })
            val dir = File(context.filesDir, "sync/${safe(connection.userId)}-${safe(connection.orgId)}").apply { mkdirs() }
            val feed = LiveFeed()
            val core = MobileCore(
                CoreConfig(connection.edgeUrl, connection.orgId, connection.userId, deviceId(context), dir.path),
                object : TokenSource {
                    override fun bearer(): String? = connection.bearer()
                },
                feed,
            )
            NetworkMonitor.start(context, core)
            return LiveSync(core, feed)
        }

        /** This phone's id: minted once and kept, like iOS's `ios-` prefixed id. */
        fun deviceId(context: Context): String {
            val prefs = context.getSharedPreferences("harness", Context.MODE_PRIVATE)
            prefs.getString("deviceId", null)?.let { return it }
            val id = "android-" + UUID.randomUUID().toString().lowercase().take(8)
            prefs.edit().putString("deviceId", id).apply()
            return id
        }

        private fun safe(part: String): String = part.replace(Regex("[^A-Za-z0-9_.@-]"), "_")
    }
}
