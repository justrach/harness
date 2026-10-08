package harness.codegraff.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import harness.codegraff.android.model.Connection
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.sans

/**
 * Home's connection state, in the bar beside the space menu (HomeView's toolbar item): degraded states are graced
 * and quiet (a dot or a mini spinner with a faint caption, no surface), and while the first server state has not
 * arrived a bare spinner says the app is connecting.
 */
@Composable
fun ConnectionIndicator(state: Connection, synced: Boolean, modifier: Modifier = Modifier) {
    val p = Theme.palette
    when (state) {
        Connection.Offline -> Row(modifier.testTag("connection-offline"), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            Box(Modifier.size(5.dp).background(p.warning, CircleShape))
            Text("Offline — sends are saved", style = sans(13f), color = p.textFaint, maxLines = 1)
        }
        Connection.Reconnecting -> Row(modifier.testTag("connection-reconnecting"), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            MiniSpinner()
            Text("Reconnecting…", style = sans(13f), color = p.textFaint, maxLines = 1)
        }
        Connection.Connected -> if (!synced) {
            MiniSpinner(modifier = modifier.semantics { contentDescription = "Connecting" })
        }
    }
}
