package harness.codegraff.android.ui.signin

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import harness.codegraff.android.model.ChatGPTSignIn
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.sans
import harness.codegraff.android.ui.components.pressWashClickable

// The small pieces OpenAI's guidelines ask for around ChatGPT plan usage (ChatGPTPlanViews.swift): the "Using ChatGPT
// plan" line with a Manage usage link, the usage-limit card, the Settings card and the banner that invites someone who
// has not signed in with ChatGPT yet. Copy is pinned in apps/parity/ux-contract.json.

/** "Using ChatGPT plan · Manage usage": shown wherever requests run on the plan (near the composer, in Settings). */
@Composable
fun PlanUsageLine(modifier: Modifier = Modifier) {
    Row(modifier.testTag("plan-usage-line"), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Using ChatGPT plan", style = sans(12f, FontWeight.Medium), color = Theme.palette.textMuted)
        ManageUsageButton(small = true)
    }
}

/** The link OpenAI wants beside every usage summary: it opens the plan's usage settings. */
@Composable
fun ManageUsageButton(small: Boolean = false) {
    val uri = LocalUriHandler.current
    Box(
        Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp)).pressWashClickable({ uri.openUri(ChatGPTSignIn.MANAGE_USAGE_URL) }, cornerRadius = 24.dp)
            .padding(horizontal = 4.dp).testTag("chatgpt-manage-usage"),
        contentAlignment = Alignment.CenterStart,
    ) { Text("Manage usage", style = if (small) sans(12f, FontWeight.SemiBold) else sans(14f, FontWeight.Medium), color = Theme.palette.text) }
}

/** A usage-limit error: Manage usage is the one action. Harness has no credits of its own, so there is no second one. */
@Composable
fun UsageLimitCard(modifier: Modifier = Modifier) {
    val p = Theme.palette
    val shape = RoundedCornerShape(14.dp)
    Column(
        modifier.fillMaxWidth().background(p.ink(0.045f), shape).border(1.dp, p.hairline(0.06f), shape).padding(14.dp).testTag("usage-limit-card"),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text("Usage limit reached", style = sans(15f, FontWeight.SemiBold), color = p.text)
        Text("Review your plan or app limit in ChatGPT settings.", style = sans(13f), color = p.textMuted)
        ManageUsageButton()
    }
}

/** The dark pill that starts the sign-in. Text only: the approved logo asset is not bundled yet. */
@Composable
fun ContinueWithChatGPTButton(onClick: () -> Unit) {
    val p = Theme.palette
    Box(
        Modifier.heightIn(min = 48.dp).clip(CircleShape).background(p.text).pressWashClickable(onClick, cornerRadius = 24.dp)
            .padding(horizontal = 16.dp).testTag("continue-with-chatgpt"),
        contentAlignment = Alignment.Center,
    ) { Text("Continue with ChatGPT", style = sans(14f, FontWeight.SemiBold), color = p.bg) }
}

/** Settings: what the option is, and either the button that starts it or the confirmation that it is on. */
@Composable
fun ChatGPTPlanCard(connected: Boolean, onContinue: () -> Unit) {
    val p = Theme.palette
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(p.ink(0.045f)).padding(16.dp).testTag("chatgpt-plan-card"),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text("Use your ChatGPT plan", style = sans(16f, FontWeight.SemiBold), color = p.text)
        Text(
            "Complete eligible AI requests in this app with usage included in your ChatGPT plan or credits balance.",
            style = sans(13f), color = p.textMuted,
        )
        if (connected) PlanUsageLine() else ContinueWithChatGPTButton(onContinue)
    }
}

/** Home: an invitation for someone who is signed in another way and has not connected ChatGPT. */
@Composable
fun ChatGPTPlanBanner(onContinue: () -> Unit) {
    val p = Theme.palette
    val shape = RoundedCornerShape(16.dp)
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp).background(p.ink(0.045f), shape).border(1.dp, p.hairline(0.06f), shape)
            .padding(14.dp).testTag("chatgpt-plan-banner"),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                "New", style = sans(11f, FontWeight.SemiBold), color = p.bg,
                modifier = Modifier.clip(CircleShape).background(p.text).padding(horizontal = 7.dp, vertical = 2.dp),
            )
            Text("Use your ChatGPT plan in this app", style = sans(14f, FontWeight.SemiBold), color = p.text)
        }
        ContinueWithChatGPTButton(onContinue)
    }
}
