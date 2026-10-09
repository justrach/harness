package harness.codegraff.android.ui.signin

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import harness.codegraff.android.auth.AuthOrg
import harness.codegraff.android.theme.HarnessMark
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.sans

/** What the sign-in gate shows while a CodeGraff sign-in runs. */
data class SignInUi(
    val busy: Boolean = false,
    val error: String? = null,
    /** More than one workspace came back: the person picks one. */
    val orgs: List<AuthOrg> = emptyList(),
)

/**
 * Sign-in gate: the harness mark on the theme's background and one high-contrast button, the old
 * mobile app's Gate (SignInView.swift). The button opens CodeGraff's sign-in in the browser, which
 * comes back through `harness://callback`; the demo stays one tap away.
 */
@Composable
fun SignInScreen(
    ui: SignInUi,
    onSignIn: () -> Unit,
    onPickOrg: (AuthOrg) -> Unit,
    onDemo: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val p = Theme.palette
    Box(modifier.fillMaxSize().background(p.bg), contentAlignment = Alignment.Center) {
        Column(
            Modifier.widthIn(max = 480.dp).fillMaxWidth().padding(horizontal = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(32.dp),
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(24.dp)) {
                HarnessMark(72.dp)
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("Harness", style = sans(28f, FontWeight.SemiBold).copy(letterSpacing = (-0.5).sp), color = p.text)
                    Text(
                        if (ui.orgs.isEmpty()) "Your coding agents, from anywhere" else "Choose a workspace",
                        style = sans(15f), color = p.textMuted,
                    )
                }
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (ui.orgs.isNotEmpty()) {
                    ui.orgs.forEach { org ->
                        Box(
                            Modifier.fillMaxWidth().heightIn(min = 50.dp).clip(RoundedCornerShape(16.dp))
                                .background(p.text.copy(alpha = 0.08f), RoundedCornerShape(16.dp))
                                .clickable(enabled = !ui.busy, role = Role.Button) { onPickOrg(org) },
                            contentAlignment = Alignment.Center,
                        ) { Text(org.name, style = sans(15f, FontWeight.Medium), color = p.text) }
                    }
                } else {
                    Box(
                        Modifier.fillMaxWidth().heightIn(min = 50.dp).clip(RoundedCornerShape(16.dp))
                            .background(p.text.copy(alpha = if (ui.busy) 0.5f else 1f), RoundedCornerShape(16.dp))
                            .clickable(enabled = !ui.busy, role = Role.Button, onClick = onSignIn),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            if (ui.busy) "Signing in…" else "Log in to Harness",
                            style = sans(15f, FontWeight.SemiBold), color = p.bg,
                        )
                    }
                }
                Box(Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp)).clickable(role = Role.Button, onClick = onDemo).padding(horizontal = 16.dp), contentAlignment = Alignment.Center) {
                    Text("Explore the demo", style = sans(14f, FontWeight.Medium), color = p.textMuted)
                }
                ui.error?.let { Text(it, style = sans(13f), color = p.danger, textAlign = TextAlign.Center) }
            }
        }
    }
}
