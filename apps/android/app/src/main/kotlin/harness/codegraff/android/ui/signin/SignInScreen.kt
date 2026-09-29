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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import harness.codegraff.android.theme.HarnessMark
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.sans

/**
 * Sign-in gate: the harness mark on the theme's background and one high-contrast button, the old
 * mobile app's Gate (SignInView.swift). CodeGraff sign-in is not wired on Android yet, so the
 * button says so and the demo is one tap away.
 */
@Composable
fun SignInScreen(onDemo: () -> Unit, modifier: Modifier = Modifier) {
    val p = Theme.palette
    var notice by remember { mutableStateOf<String?>(null) }
    Box(modifier.fillMaxSize().background(p.bg), contentAlignment = Alignment.Center) {
        Column(
            Modifier.widthIn(max = 480.dp).fillMaxWidth().padding(horizontal = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(32.dp),
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(24.dp)) {
                HarnessMark(72.dp)
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("Harness", style = sans(28f, FontWeight.SemiBold).copy(letterSpacing = (-0.5).sp), color = p.text)
                    Text("Your coding agents, from anywhere", style = sans(15f), color = p.textMuted)
                }
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(
                    Modifier.fillMaxWidth().heightIn(min = 50.dp).clip(RoundedCornerShape(16.dp)).background(p.text, RoundedCornerShape(16.dp))
                        .clickable(role = Role.Button) { notice = "Signing in with CodeGraff is coming to Android. Explore the demo for now." },
                    contentAlignment = Alignment.Center,
                ) { Text("Log in to Harness", style = sans(15f, FontWeight.SemiBold), color = p.bg) }
                Box(Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp)).clickable(role = Role.Button, onClick = onDemo).padding(horizontal = 16.dp), contentAlignment = Alignment.Center) {
                    Text("Explore the demo", style = sans(14f, FontWeight.Medium), color = p.textMuted)
                }
                notice?.let { Text(it, style = sans(13f), color = p.danger, textAlign = TextAlign.Center) }
            }
        }
    }
}
