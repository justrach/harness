package harness.codegraff.android.ui

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import harness.codegraff.android.model.NewSessionDestination

/** Where the navigation stack is (Home's `Route`). Home itself is the empty stack. */
sealed interface Route {
    data class Chat(val id: String) : Route
    data class Space(val id: String) : Route
    data class NewSession(val destination: NewSessionDestination) : Route

    /** A string form that survives process death and configuration changes. */
    fun encode(): String = when (this) {
        is Chat -> "chat:$id"
        is Space -> "space:$id"
        is NewSession -> when (val d = destination) {
            is NewSessionDestination.Project -> "new:project:${d.spaceId}"
            is NewSessionDestination.Projectless -> "new:host:${d.deviceId}"
        }
    }

    companion object {
        fun decode(s: String): Route? = when {
            s.startsWith("chat:") -> Chat(s.removePrefix("chat:"))
            s.startsWith("space:") -> Space(s.removePrefix("space:"))
            s.startsWith("new:project:") -> NewSession(NewSessionDestination.Project(s.removePrefix("new:project:")))
            s.startsWith("new:host:") -> NewSession(NewSessionDestination.Projectless(s.removePrefix("new:host:")))
            else -> null
        }

        val PathSaver: Saver<List<Route>, List<String>> = Saver(
            save = { path -> path.map { it.encode() } },
            restore = { saved -> saved.mapNotNull(::decode) },
        )
    }
}

/** Open a session from anywhere under Home; from inside a session it replaces that session rather than stacking another. */
val LocalSwitchToSession = compositionLocalOf<((String) -> Unit)?> { null }

/** A string preference that recomposes readers and persists on write (SwiftUI `@AppStorage`). */
class PrefState(private val prefs: SharedPreferences, private val key: String, default: String) {
    var value by mutableStateOf(prefs.getString(key, default) ?: default)
        private set

    fun set(new: String) {
        value = new
        prefs.edit().putString(key, new).apply()
    }
}

@Composable
fun rememberPref(key: String, default: String): PrefState {
    val context = LocalContext.current
    return remember(key) {
        PrefState(context.getSharedPreferences("harness-ui", Context.MODE_PRIVATE), key, default)
    }
}
