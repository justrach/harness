package harness.codegraff.android.ui.signin

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import harness.codegraff.android.model.ChatGPTAction
import harness.codegraff.android.model.ChatGPTComputer
import harness.codegraff.android.model.ChatGPTPhase
import harness.codegraff.android.model.ChatGPTSignIn
import harness.codegraff.android.model.ChatGPTSignInClient
import harness.codegraff.android.model.ChatGPTSignInFlow
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.sans
import harness.codegraff.android.ui.components.HarnessSheet
import harness.codegraff.android.ui.components.SheetBody
import harness.codegraff.android.ui.components.SheetCard
import harness.codegraff.android.ui.components.SheetPrimaryButton
import harness.codegraff.android.ui.components.SheetSelectRow
import harness.codegraff.android.ui.components.SheetSeparator
import harness.codegraff.android.ui.components.pressWashClickable

/**
 * "Use your ChatGPT plan" (ChatGPTSignInSheet.swift): sign in to Graff with a ChatGPT account so requests run on the
 * person's plan. The browser step happens on the computer, so this only picks the computer, starts it there, shows the
 * wait and shows the outcome, in the wording OpenAI's guidelines ask for. The rules are in [ChatGPTSignIn]; the copy is
 * pinned in apps/parity/ux-contract.json.
 */
@Composable
fun ChatGPTSignInSheet(computers: List<ChatGPTComputer>, client: ChatGPTSignInClient, onDismiss: () -> Unit) {
    HarnessSheet(title = "Use your ChatGPT plan", onDismiss = onDismiss) {
        ChatGPTSignInContent(computers, client, onDone = onDismiss)
    }
}

/** The sheet's body, also used as a page inside Settings. */
@Composable
fun ChatGPTSignInContent(computers: List<ChatGPTComputer>, client: ChatGPTSignInClient, onDone: () -> Unit) {
    val p = Theme.palette
    val scope = rememberCoroutineScope()
    val flow = remember(client) { ChatGPTSignInFlow(client, scope) }
    var selected by rememberSaveable { mutableStateOf(computers.firstOrNull()?.id ?: "") }
    val selectedName = computers.firstOrNull { it.id == selected }?.name ?: ""
    // Leaving mid-wait tells the computer to close its callback listener.
    DisposableEffect(flow) { onDispose { if (flow.phase == ChatGPTPhase.Waiting) flow.abandon(selected) else flow.stop() } }
    val uri = LocalUriHandler.current

    SheetBody {
        Text(
            "Graff can run on your ChatGPT plan. This doesn't give it access to your ChatGPT conversations.",
            style = sans(14f), color = p.textMuted,
        )
        SheetCard {
            Step(1, "Choose the computer") {
                computers.forEach { computer ->
                    SheetSelectRow(computer.name, selected = computer.id == selected, modifier = Modifier.testTag("chatgpt-computer-${computer.id}")) {
                        if (flow.phase == ChatGPTPhase.Idle) selected = computer.id
                    }
                }
            }
            SheetSeparator()
            Step(2, "Continue with ChatGPT") {
                Text("A browser window opens on that computer. Approve it there.", style = sans(13f), color = p.textMuted, modifier = Modifier.padding(horizontal = 16.dp))
                if (flow.phase == ChatGPTPhase.Idle) {
                    SheetPrimaryButton("Continue with ChatGPT", enabled = computers.isNotEmpty(), modifier = Modifier.padding(horizontal = 16.dp).testTag("chatgpt-continue")) {
                        flow.start(selected)
                    }
                }
            }
        }
        Terminal()
        if (flow.phase != ChatGPTPhase.Idle) {
            Column(
                Modifier.fillMaxWidth().testTag("chatgpt-status").semantics { stateDescription = flow.phase.wireName },
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (flow.phase == ChatGPTPhase.Waiting) {
                    fun on(prefix: String) = "$prefix $selectedName"
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = p.text)
                        Text(on("Waiting for approval on"), style = sans(15f, FontWeight.Medium), color = p.text)
                    }
                    Text("Keep this open until it finishes.", style = sans(13f), color = p.textMuted)
                } else {
                    val (title, body) = outcomeCopy(flow.phase)
                    Text(title, style = sans(17f, FontWeight.SemiBold), color = p.text)
                    if (body != null) Text(body, style = sans(14f), color = p.textMuted)
                    if (flow.phase == ChatGPTPhase.Connected) {
                        TextAction("Manage usage", "chatgpt-manage-usage") { uri.openUri(ChatGPTSignIn.MANAGE_USAGE_URL) }
                    }
                }
                when (ChatGPTSignIn.action(flow.phase)) {
                    ChatGPTAction.Start -> Unit
                    ChatGPTAction.Cancel -> TextAction("Cancel", "chatgpt-cancel") { flow.cancel(selected) }
                    ChatGPTAction.Done -> SheetPrimaryButton("Got it", modifier = Modifier.testTag("chatgpt-done")) { onDone() }
                    ChatGPTAction.Retry -> SheetPrimaryButton(
                        if (flow.phase == ChatGPTPhase.PlanUsageOff) "Sign in again" else "Try again",
                        modifier = Modifier.testTag("chatgpt-retry"),
                    ) { flow.start(selected) }
                }
            }
        }
    }
}

/** The same thing from a shell, for someone who would rather type it on the computer. */
@Composable
private fun Terminal() {
    val p = Theme.palette
    val clipboard = LocalClipboardManager.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Prefer the terminal? Run", style = sans(13f), color = p.textMuted)
        Text(
            "graff login chatgpt", style = sans(13f).copy(fontFamily = FontFamily.Monospace), color = p.text,
            modifier = Modifier.clip(RoundedCornerShape(8.dp)).background(p.ink(0.045f)).padding(horizontal = 8.dp, vertical = 5.dp),
        )
        Box(
            Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp)).pressWashClickable({ clipboard.setText(AnnotatedString("graff login chatgpt")) }, cornerRadius = 24.dp)
                .padding(horizontal = 10.dp).testTag("chatgpt-copy-command"),
            contentAlignment = Alignment.Center,
        ) { Text("Copy", style = sans(13f, FontWeight.Medium), color = p.textMuted) }
    }
}

private fun outcomeCopy(phase: ChatGPTPhase): Pair<String, String?> = when (phase) {
    ChatGPTPhase.Connected -> "You're using your ChatGPT plan" to null
    ChatGPTPhase.PlanUsageOff ->
        "Signed in, but plan usage is off" to "Graff can't use your ChatGPT plan yet. Sign in again and allow plan usage, or use an API key."
    ChatGPTPhase.Declined -> "You didn't approve the sign-in" to "Nothing was changed. Try again when you're ready."
    ChatGPTPhase.Failed -> "Sign-in didn't finish" to "Something went wrong on your computer. Try again."
    ChatGPTPhase.Idle, ChatGPTPhase.Waiting -> "" to null
}

/** A numbered step, like the sign-in dialogs people already know. */
@Composable
private fun Step(number: Int, title: String, content: @Composable ColumnScope.() -> Unit) {
    val p = Theme.palette
    Row(Modifier.fillMaxWidth().padding(vertical = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(
            Modifier.padding(start = 16.dp).size(26.dp).border(1.dp, p.textFaint, CircleShape),
            contentAlignment = Alignment.Center,
        ) { Text("$number", style = sans(13f, FontWeight.Medium), color = p.textMuted) }
        Column(Modifier.padding(end = 0.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, style = sans(16f, FontWeight.SemiBold), color = p.text, modifier = Modifier.padding(top = 2.dp))
            content()
        }
    }
}

@Composable
private fun TextAction(label: String, tag: String, onClick: () -> Unit) {
    Box(
        Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp)).pressWashClickable(onClick, cornerRadius = 24.dp).padding(horizontal = 4.dp).testTag(tag),
        contentAlignment = Alignment.CenterStart,
    ) { Text(label, style = sans(15f, FontWeight.Medium), color = Theme.palette.text) }
}
