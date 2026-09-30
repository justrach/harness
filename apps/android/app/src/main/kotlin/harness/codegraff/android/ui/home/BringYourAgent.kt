package harness.codegraff.android.ui.home

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import harness.codegraff.android.model.AgentReadiness
import harness.codegraff.android.model.AgentStatus
import harness.codegraff.android.model.ChatGPTComputer
import harness.codegraff.android.model.OnboardingState
import harness.codegraff.android.theme.Glyph
import harness.codegraff.android.theme.GlyphView
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.sans
import harness.codegraff.android.ui.components.pressWashClickable

/**
 * "Bring in your agent" (BringYourAgentView.swift): what Home shows while nothing has been started, until one of Graff,
 * Claude Code or OpenAI Codex is ready on a computer that is online. Harness runs the agent on the computer and this
 * app is the remote, so it says what each computer has, what is missing, and, with no computer at all, how to get the
 * download link onto one. The rules are in [AgentReadiness]; the copy is pinned in apps/parity/ux-contract.json.
 */
@Composable
fun BringYourAgent(
    readiness: AgentReadiness,
    deviceName: (String) -> String,
    modifier: Modifier = Modifier,
    /** The "Continue with ChatGPT" sign-in is available (demo only for now). */
    chatGPT: Boolean = false,
    onChatGPT: (List<ChatGPTComputer>) -> Unit = {},
) {
    val p = Theme.palette
    Column(modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp).testTag("onboarding-agents"), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Bring in your agent", style = sans(22f, FontWeight.SemiBold), color = p.text)
            Text(
                "Harness runs your agent on your computer, and this app is the remote. Add one of these there, then start a session from here.",
                style = sans(14f), color = p.textMuted,
            )
        }
        if (readiness.state == OnboardingState.NoComputer) GetHarness()
        Card {
            readiness.rows.forEachIndexed { index, row ->
                if (index > 0) Box(Modifier.fillMaxWidth().padding(start = 16.dp).heightIn(min = 1.dp).background(p.hairline(0.06f)).padding(top = 1.dp))
                AgentRow(
                    row, readiness.state == OnboardingState.NoComputer, deviceName,
                    // OpenAI Codex can run on a ChatGPT plan; the sign-in happens on the computer that has it.
                    showChatGPT = chatGPT && row.agent.id == "codex" && row.status >= AgentStatus.Off,
                ) { onChatGPT(row.deviceIds.map { ChatGPTComputer(it, deviceName(it)) }) }
            }
        }
    }
}

@Composable
private fun Card(content: @Composable () -> Unit) {
    val p = Theme.palette
    val shape = RoundedCornerShape(20.dp)
    Column(Modifier.fillMaxWidth().background(p.ink(0.045f), shape).border(1.dp, p.hairline(0.06f), shape).clip(shape)) { content() }
}

/** No computer online: the link that gets Harness onto one, ready to send to yourself. */
@Composable
private fun GetHarness() {
    val p = Theme.palette
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    Card {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Get Harness on your computer", style = sans(16f, FontWeight.SemiBold), color = p.text)
            Text(
                "Open the link on your computer, install Harness, and sign in with the same CodeGraff account. Your computer shows up here once it's online.",
                style = sans(13f), color = p.textMuted,
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(
                    Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp)).background(p.text)
                        .pressWashClickable(
                            onClick = {
                                val send = Intent(Intent.ACTION_SEND).apply {
                                    type = "text/plain"
                                    putExtra(Intent.EXTRA_TEXT, "Get Harness for your computer" + ": " + AgentReadiness.DOWNLOAD_URL)
                                }
                                context.startActivity(Intent.createChooser(send, "Send the link to your computer"))
                            },
                            cornerRadius = 24.dp,
                        )
                        .padding(horizontal = 16.dp).testTag("onboarding-share-link"),
                    contentAlignment = Alignment.Center,
                ) { Text("Send the link to your computer", style = sans(14f, FontWeight.SemiBold), color = p.bg) }
                Box(
                    Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp))
                        .pressWashClickable(onClick = { clipboard.setText(AnnotatedString(AgentReadiness.DOWNLOAD_URL)) }, cornerRadius = 24.dp)
                        .padding(horizontal = 12.dp).testTag("onboarding-copy-link"),
                    contentAlignment = Alignment.Center,
                ) { Text("Copy link", style = sans(14f, FontWeight.Medium), color = p.text) }
            }
        }
    }
}

@Composable
private fun AgentRow(row: AgentReadiness.Row, noComputer: Boolean, deviceName: (String) -> String, showChatGPT: Boolean, onChatGPT: () -> Unit) {
    val p = Theme.palette
    val ready = row.status == AgentStatus.Ready
    val names = row.deviceIds.joinToString(", ", transform = deviceName)
    fun on(prefix: String) = "$prefix $names"
    val (headline, hint) = when {
        noComputer -> "Needs a computer" to null
        row.status == AgentStatus.Ready -> on("Ready on") to null
        row.status == AgentStatus.Off -> on("Switched off on") to "Turn it on in Settings → Agents on that computer."
        row.status == AgentStatus.CanInstall -> on("Not installed on") to "Install it from Settings → Agents on that computer."
        else -> on("Not found on") to "Install it on that computer and it will appear here."
    }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp).semantics(mergeDescendants = true) {}.testTag("onboarding-agent-${row.agent.id}"),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            Modifier.padding(top = 1.dp).size(20.dp).clip(CircleShape).background(if (ready) p.text else p.ink(0f)).border(1.5.dp, if (ready) p.text else p.textFaint, CircleShape),
            contentAlignment = Alignment.Center,
        ) { if (ready) GlyphView(Glyph.Check, 12.dp, p.bg, strokeWidth = 2.6f) }
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(row.agent.name, style = sans(16f, FontWeight.SemiBold), color = p.text)
            Text(row.agent.blurb, style = sans(13f), color = p.textMuted)
            Text(headline, style = sans(12.5f, FontWeight.Medium), color = if (ready) p.text else p.textMuted, modifier = Modifier.padding(top = 2.dp))
            hint?.let { Text(it, style = sans(12f), color = p.textFaint.opacity(1f)) }
            if (showChatGPT) {
                Box(
                    Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp)).pressWashClickable(onChatGPT, cornerRadius = 24.dp).testTag("onboarding-chatgpt"),
                    contentAlignment = Alignment.CenterStart,
                ) { Text("Continue with ChatGPT", style = sans(14f, FontWeight.SemiBold), color = p.text) }
            }
        }
    }
}
