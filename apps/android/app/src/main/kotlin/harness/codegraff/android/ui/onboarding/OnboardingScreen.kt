package harness.codegraff.android.ui.onboarding

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import harness.codegraff.android.AppModel
import harness.codegraff.android.WorkspaceState
import harness.codegraff.android.model.AgentReadiness
import harness.codegraff.android.model.AgentStatus
import harness.codegraff.android.model.Autonomy
import harness.codegraff.android.model.HarnessCatalog
import harness.codegraff.android.model.ModelInfo
import harness.codegraff.android.model.Onboarding
import harness.codegraff.android.theme.Glyph
import harness.codegraff.android.theme.GlyphView
import harness.codegraff.android.theme.HarnessBadge
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.sans
import harness.codegraff.android.ui.components.pressWashClickable
import harness.codegraff.android.ui.rememberPref
import kotlinx.coroutines.launch
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

private enum class Step { Agent, Effort, Autonomy, Ready }

/** The optional extras under Graff, in the order the setup lists them. */
private val extrasOrder = listOf("claude-code" to "Claude Code", "codex" to "OpenAI Codex")

/**
 * First-run setup (OnboardingView.swift): which agent starts sessions (Graff first and preselected, connected
 * through the CodeGraff sign-in; Claude Code and Codex as optional extras), how hard it thinks, how much it may
 * do without asking, then a ready screen. Each answer sets the real default: the New session harness, model and
 * effort prefs, the computer's agents, and its autonomy level. Android has no push notifications yet, so the
 * notifications question the other apps ask is left out here.
 *
 * [onFinish] closes the setup; [onStart] opens New session on the computer with the starter as its draft.
 */
@Composable
fun OnboardingScreen(
    state: WorkspaceState,
    model: AppModel,
    onFinish: () -> Unit,
    onStart: (deviceId: String) -> Unit,
    initialStep: Int = 0,
) {
    val p = Theme.palette
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val harnessPref = rememberPref("newSessionHarness", "claude-code")
    val modelPref = rememberPref("newSessionModel", "")
    val reasoningPref = rememberPref("newSessionReasoning", "")
    val starterPref = rememberPref("onboarding.starterDraft", "")

    var step by rememberSaveable { mutableStateOf(Step.entries.getOrElse(initialStep) { Step.Agent }) }
    val hosts = state.executionDevices.sortedBy { !state.deviceOnline(it.id) }
    var hostId by rememberSaveable { mutableStateOf<String?>(null) }
    val host = hostId?.takeIf { id -> hosts.any { it.id == id } } ?: hosts.firstOrNull()?.id
    var extras by rememberSaveable { mutableStateOf(setOf<String>()) }
    var models by remember { mutableStateOf(listOf<ModelInfo>()) }
    var modelId by rememberSaveable { mutableStateOf<String?>(null) }
    var level by rememberSaveable { mutableStateOf("high") }
    var autonomy by rememberSaveable { mutableStateOf(Autonomy.Workspace) }
    var starter by rememberSaveable { mutableStateOf<Int?>(null) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val agents = host?.let { state.agents[it] }.orEmpty()

    LaunchedEffect(host) {
        val id = host ?: return@LaunchedEffect
        val list = runCatching { model.listModels(id, "graff").items }.getOrDefault(emptyList()).take(3)
        models = list
        if (modelId == null || list.none { it.id == modelId }) modelId = list.firstOrNull()?.id
        // A computer someone already set keeps its level; otherwise the setup suggests Workspace.
        runCatching { model.autonomy(id) }.getOrNull()?.let { if (it.chosen) autonomy = it.autonomy }
    }
    val ladder = models.firstOrNull { it.id == modelId }?.reasoningLevels?.takeIf { it.isNotEmpty() } ?: Onboarding.fallbackLadder
    LaunchedEffect(ladder) { if (level !in ladder) level = if ("high" in ladder) "high" else ladder.first() }

    fun describe(e: Throwable): String {
        val name = host?.let(state::deviceName) ?: "your computer"
        val message = e.message.orEmpty()
        return if (message.contains("unknown method", ignoreCase = true)) "Update Harness on $name to set this from your phone."
        else "Couldn't reach $name: ${message.ifEmpty { "no answer" }}"
    }

    fun finish() {
        Onboarding.finish(context)
        onFinish()
    }

    fun advance() {
        error = null
        when (step) {
            Step.Agent -> {
                harnessPref.set("graff")
                val id = host
                val off = extras.filter { AgentReadiness.statusOf(it, agents) == AgentStatus.Off }
                if (id == null || off.isEmpty()) { step = Step.Effort; return }
                saving = true
                scope.launch {
                    runCatching { off.forEach { model.setHarnessEnabled(id, it, true) } }
                        .onSuccess { step = Step.Effort }
                        .onFailure { error = describe(it) }
                    saving = false
                }
            }
            Step.Effort -> {
                modelId?.let(modelPref::set)
                reasoningPref.set(level)
                step = Step.Autonomy
            }
            Step.Autonomy -> {
                val id = host ?: run { step = Step.Ready; return }
                saving = true
                scope.launch {
                    runCatching { model.setAutonomy(id, autonomy) }
                        .onSuccess { step = Step.Ready }
                        .onFailure { error = describe(it) }
                    saving = false
                }
            }
            Step.Ready -> {
                val id = host
                starter?.let { starterPref.set(Onboarding.starters[it].second) }
                Onboarding.finish(context)
                onFinish()
                if (id != null) onStart(id)
            }
        }
    }

    BackHandler(enabled = step != Step.Agent) { step = Step.entries[step.ordinal - 1] }

    BoxWithConstraints(Modifier.fillMaxSize().background(p.bg).safeDrawingPadding().testTag("onboarding")) {
        val wide = maxWidth > 600.dp && maxWidth > maxHeight
        Column(Modifier.fillMaxSize().padding(horizontal = 24.dp)) {
            Header(step, onBack = { step = Step.entries[step.ordinal - 1] })
            if (wide) {
                Row(Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(32.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(0.9f)) { Question(step, host?.let(state::deviceName), alignStart = true) }
                    Column(Modifier.weight(1.1f).verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally) {
                        Body(step, state, hosts.map { it.id to it.name }, host, { hostId = it }, agents, extras, { extras = it }, models, modelId, { modelId = it }, ladder, level, { level = it }, autonomy, { autonomy = it }, starter, { starter = it })
                    }
                }
            } else {
                Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally) {
                    Spacer(Modifier.height(20.dp))
                    Question(step, host?.let(state::deviceName), alignStart = false)
                    Spacer(Modifier.height(22.dp))
                    Body(step, state, hosts.map { it.id to it.name }, host, { hostId = it }, agents, extras, { extras = it }, models, modelId, { modelId = it }, ladder, level, { level = it }, autonomy, { autonomy = it }, starter, { starter = it })
                }
            }
            Footer(
                cta = when (step) { Step.Ready -> "Start a session"; else -> "Next" },
                busy = saving,
                error = error,
                secondary = if (step == Step.Ready) "Change any of this in Settings" else "Skip setup",
                onPrimary = ::advance,
                onSecondary = if (step == Step.Ready) null else ({ finish() }),
            )
        }
    }
}

@Composable
private fun Header(step: Step, onBack: () -> Unit) {
    val p = Theme.palette
    Row(Modifier.fillMaxWidth().height(48.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.size(36.dp), contentAlignment = Alignment.Center) {
            if (step != Step.Agent) {
                Box(Modifier.size(36.dp).clip(CircleShape).background(p.ink(0.06f)).pressWashClickable(onBack, cornerRadius = 18.dp).semantics { contentDescription = "Back" }, contentAlignment = Alignment.Center) {
                    GlyphView(Glyph.ChevronLeft, 16.dp, p.text, strokeWidth = 2.4f)
                }
            }
        }
        val questions = Step.entries.size - 1
        if (step != Step.Ready) {
            Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                repeat(questions) { i ->
                    Box(Modifier.weight(1f).height(4.dp).clip(RoundedCornerShape(2.dp)).background(if (i <= step.ordinal) p.text else p.ink(0.12f)))
                }
            }
            Text("${step.ordinal + 1}/$questions", style = sans(13f), color = p.textMuted)
        } else {
            Spacer(Modifier.weight(1f))
        }
    }
}

@Composable
private fun Question(step: Step, hostName: String?, alignStart: Boolean) {
    val p = Theme.palette
    val (title, subtitle) = when (step) {
        Step.Agent -> "Which agent starts your sessions?" to "Graff is already connected through your CodeGraff sign-in. Add Claude Code or Codex too if you use them."
        Step.Effort -> "How hard should it think?" to "Your default for new Graff sessions. Change it per message from the composer."
        Step.Autonomy -> "How much can it do without asking?" to "Applies to every agent on ${hostName ?: "this computer"}. Change it any time in Settings."
        Step.Ready -> "Your first agent is ready" to "Graff is live on ${hostName ?: "your computer"}."
    }
    val align = if (alignStart) TextAlign.Start else TextAlign.Center
    Column(Modifier.fillMaxWidth(), horizontalAlignment = if (alignStart) Alignment.Start else Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(title, style = sans(28f, FontWeight.SemiBold, lineHeight = 34f), color = p.text, textAlign = align)
        Text(subtitle, style = sans(15f, lineHeight = 21f), color = p.textMuted, textAlign = align)
    }
}

@Composable
private fun Body(
    step: Step,
    state: WorkspaceState,
    hosts: List<Pair<String, String>>,
    host: String?,
    onHost: (String) -> Unit,
    agents: List<harness.codegraff.android.model.AgentDescriptor>,
    extras: Set<String>,
    onExtras: (Set<String>) -> Unit,
    models: List<ModelInfo>,
    modelId: String?,
    onModel: (String) -> Unit,
    ladder: List<String>,
    level: String,
    onLevel: (String) -> Unit,
    autonomy: Autonomy,
    onAutonomy: (Autonomy) -> Unit,
    starter: Int?,
    onStarter: (Int?) -> Unit,
) {
    when (step) {
        Step.Agent -> AgentStep(state, hosts, host, onHost, agents, extras, onExtras)
        Step.Effort -> EffortStep(models, modelId, onModel, ladder, level, onLevel)
        Step.Autonomy -> AutonomyStep(autonomy, onAutonomy)
        Step.Ready -> ReadyStep(host?.let(state::deviceName), models.firstOrNull { it.id == modelId }?.label, level, autonomy, starter, onStarter)
    }
}

@Composable
private fun AgentStep(
    state: WorkspaceState,
    hosts: List<Pair<String, String>>,
    host: String?,
    onHost: (String) -> Unit,
    agents: List<harness.codegraff.android.model.AgentDescriptor>,
    extras: Set<String>,
    onExtras: (Set<String>) -> Unit,
) {
    val p = Theme.palette
    Column(Modifier.fillMaxWidth().widthIn(max = 520.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (hosts.isNotEmpty()) {
            Row(Modifier.align(Alignment.CenterHorizontally), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                hosts.forEach { (id, name) ->
                    val on = id == host
                    Row(
                        Modifier.clip(RoundedCornerShape(16.dp)).background(if (on) p.ink(0.08f) else p.ink(0.0f))
                            .border(1.dp, p.hairline(if (on) 0.18f else 0.1f), RoundedCornerShape(16.dp))
                            .pressWashClickable({ onHost(id) }, cornerRadius = 16.dp).padding(horizontal = 12.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        GlyphView(Glyph.Laptop, 14.dp, p.text, strokeWidth = 2f)
                        Text(name, style = sans(13f, FontWeight.Medium), color = p.text)
                    }
                }
            }
        }
        AgentCard(
            harness = "graff", name = "Graff",
            status = "Connected with your CodeGraff account", statusOk = true,
            badge = "Recommended", selected = true, strong = true, onClick = null,
        )
        Text("OPTIONAL EXTRAS", style = sans(12f, FontWeight.Medium), color = p.textMuted.opacity(0.7f), modifier = Modifier.padding(start = 4.dp, top = 6.dp))
        extrasOrder.forEach { (id, name) ->
            val status = AgentReadiness.statusOf(id, agents)
            val hostName = host?.let(state::deviceName) ?: "your computer"
            val (line, ok) = when (status) {
                AgentStatus.Ready -> "Ready on $hostName" to true
                AgentStatus.Off -> "Installed, switched off. Picking it turns it on." to false
                AgentStatus.CanInstall -> "Install it from Settings > Agents on $hostName" to false
                AgentStatus.Missing -> "Not found on $hostName" to false
            }
            val pickable = status == AgentStatus.Ready || status == AgentStatus.Off
            AgentCard(
                harness = id, name = name, status = line, statusOk = ok, badge = null,
                selected = id in extras, strong = false,
                onClick = if (pickable) ({ onExtras(if (id in extras) extras - id else extras + id) }) else null,
            )
        }
        Text("No extras are fine: Graff does everything here. Add more later in Settings.", style = sans(12.5f), color = p.textFaint, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth().padding(top = 4.dp))
    }
}

@Composable
private fun AgentCard(harness: String, name: String, status: String, statusOk: Boolean, badge: String?, selected: Boolean, strong: Boolean, onClick: (() -> Unit)?) {
    val p = Theme.palette
    val shape = RoundedCornerShape(18.dp)
    Row(
        Modifier.fillMaxWidth().clip(shape).background(if (strong) p.surfaceRaised else p.ink(0.03f))
            .border(if (strong) 1.5.dp else 1.dp, if (strong) p.text else p.hairline(0.1f), shape)
            .then(if (onClick != null) Modifier.pressWashClickable(onClick, cornerRadius = 18.dp, role = Role.Checkbox) else Modifier)
            .padding(14.dp)
            .semantics { stateDescription = if (selected) "Selected" else "Not selected" },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.size(44.dp).clip(RoundedCornerShape(12.dp)).background(p.ink(0.06f)), contentAlignment = Alignment.Center) {
            HarnessBadge(harness, size = 22.dp)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(name, style = sans(16f, FontWeight.SemiBold), color = p.text)
                if (badge != null) {
                    Text(badge, style = sans(11f, FontWeight.SemiBold), color = p.bg, modifier = Modifier.clip(RoundedCornerShape(6.dp)).background(p.text).padding(horizontal = 6.dp, vertical = 2.dp))
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Box(Modifier.size(6.dp).clip(CircleShape).background(if (statusOk) p.statusCompleted else p.textFaint))
                Text(status, style = sans(13f), color = p.textMuted)
            }
        }
        Box(
            Modifier.size(24.dp).clip(CircleShape).background(if (selected) p.text else p.ink(0f)).border(1.5.dp, if (selected) p.text else p.hairline(0.3f), CircleShape),
            contentAlignment = Alignment.Center,
        ) { if (selected) GlyphView(Glyph.Check, 14.dp, p.bg, strokeWidth = 3f) }
    }
}

@Composable
private fun EffortStep(models: List<ModelInfo>, modelId: String?, onModel: (String) -> Unit, ladder: List<String>, level: String, onLevel: (String) -> Unit) {
    val p = Theme.palette
    Column(Modifier.fillMaxWidth().widthIn(max = 520.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (models.isNotEmpty()) {
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(p.ink(0.05f)).padding(4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                models.forEach { m ->
                    val on = m.id == modelId
                    Box(
                        Modifier.weight(1f).clip(RoundedCornerShape(10.dp)).background(if (on) p.surfaceRaised else p.ink(0f))
                            .pressWashClickable({ onModel(m.id) }, cornerRadius = 10.dp).padding(vertical = 9.dp),
                        contentAlignment = Alignment.Center,
                    ) { Text(m.label, style = sans(13f, if (on) FontWeight.SemiBold else FontWeight.Normal), color = if (on) p.text else p.textMuted, maxLines = 1) }
                }
            }
            Text("Graff models from your CodeGraff account", style = sans(12f), color = p.textFaint)
        }
        EffortDial(ladder, level, onLevel)
        val index = ladder.indexOf(level)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(18.dp)) {
            RoundButton("-", "Less effort", enabled = index > 0) { onLevel(ladder[index - 1]) }
            Text(Onboarding.effortBlurb(level), style = sans(14f), color = p.textMuted, textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = 200.dp))
            RoundButton("+", "More effort", enabled = index < ladder.size - 1) { onLevel(ladder[index + 1]) }
        }
    }
}

@Composable
private fun RoundButton(label: String, description: String, enabled: Boolean, onClick: () -> Unit) {
    val p = Theme.palette
    Box(
        Modifier.size(44.dp).clip(CircleShape).border(1.dp, p.hairline(0.2f), CircleShape)
            .pressWashClickable(onClick, cornerRadius = 22.dp, enabled = enabled).semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) { Text(label, style = sans(20f), color = p.text.opacity(if (enabled) 1f else 0.3f)) }
}

/** A 270 degree dial over the effort ladder: drag the knob or tap a tick. */
@Composable
private fun EffortDial(ladder: List<String>, level: String, onLevel: (String) -> Unit) {
    val p = Theme.palette
    val index = ladder.indexOf(level).coerceAtLeast(0)
    val start = 135f
    val sweep = 270f
    fun pick(offset: Offset, size: Size) {
        val c = Offset(size.width / 2, size.height / 2)
        var deg = Math.toDegrees(atan2((offset.y - c.y).toDouble(), (offset.x - c.x).toDouble())).toFloat()
        deg = (deg - start + 360f) % 360f
        if (deg > sweep) deg = if (deg > sweep + 45f) 0f else sweep
        val i = (deg / sweep * (ladder.size - 1)).roundToInt().coerceIn(0, ladder.size - 1)
        if (ladder[i] != level) onLevel(ladder[i])
    }
    Box(
        Modifier.size(230.dp)
            .pointerInput(ladder) { detectTapGestures { pick(it, Size(size.width.toFloat(), size.height.toFloat())) } }
            .pointerInput(ladder, level) { detectDragGestures { change, _ -> pick(change.position, Size(size.width.toFloat(), size.height.toFloat())) } }
            .semantics { contentDescription = "Effort"; stateDescription = HarnessCatalog.reasoningLabel(level) },
        contentAlignment = Alignment.Center,
    ) {
        val track = p.ink(0.08f)
        val fill = p.text
        val tick = p.textFaint
        val knobFill = p.bg
        Canvas(Modifier.fillMaxSize().padding(14.dp)) {
            val stroke = 22.dp.toPx()
            val inset = stroke / 2
            val arcSize = Size(size.width - stroke, size.height - stroke)
            drawArc(track, start, sweep, false, Offset(inset, inset), arcSize, style = Stroke(stroke, cap = StrokeCap.Round))
            val frac = if (ladder.size > 1) index.toFloat() / (ladder.size - 1) else 1f
            drawArc(fill, start, sweep * frac, false, Offset(inset, inset), arcSize, style = Stroke(stroke, cap = StrokeCap.Round))
            val r = arcSize.width / 2
            val c = Offset(size.width / 2, size.height / 2)
            ladder.indices.forEach { i ->
                val a = Math.toRadians((start + sweep * i / (ladder.size - 1).coerceAtLeast(1)).toDouble())
                val pt = Offset(c.x + (r + stroke) * cos(a).toFloat(), c.y + (r + stroke) * sin(a).toFloat())
                drawCircle(tick, 2.dp.toPx(), pt)
            }
            val a = Math.toRadians((start + sweep * frac).toDouble())
            val knob = Offset(c.x + r * cos(a).toFloat(), c.y + r * sin(a).toFloat())
            drawCircle(knobFill, stroke / 2 + 3.dp.toPx(), knob)
            drawCircle(fill, stroke / 2 + 3.dp.toPx(), knob, style = Stroke(3.dp.toPx()))
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(HarnessCatalog.reasoningLabel(level), style = sans(34f, FontWeight.SemiBold), color = p.text)
            Text("Level ${index + 1} of ${ladder.size}", style = sans(13f), color = p.textMuted)
        }
    }
}

@Composable
private fun AutonomyStep(autonomy: Autonomy, onAutonomy: (Autonomy) -> Unit) {
    val p = Theme.palette
    Column(Modifier.fillMaxWidth().widthIn(max = 520.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text(autonomy.label, style = sans(44f, FontWeight.Bold), color = p.text)
        Text(autonomy.blurb, style = sans(14f), color = p.textMuted, textAlign = TextAlign.Center)
        val levels = Autonomy.entries
        Box(
            Modifier.fillMaxWidth().height(56.dp).pointerInput(Unit) {
                detectTapGestures { o -> onAutonomy(levels[((o.x / size.width) * levels.size).toInt().coerceIn(0, levels.size - 1)]) }
            }.pointerInput(Unit) {
                detectDragGestures { change, _ -> onAutonomy(levels[((change.position.x / size.width) * levels.size).toInt().coerceIn(0, levels.size - 1)]) }
            },
        ) {
            val ink = p.text
            val faint = p.textFaint
            Canvas(Modifier.fillMaxSize()) {
                val n = 41
                for (i in 0 until n) {
                    val x = size.width * i / (n - 1)
                    val major = i % 20 == 0
                    val h = if (major) size.height * 0.7f else size.height * 0.4f
                    drawLine(if (major) ink else faint, Offset(x, size.height - h), Offset(x, size.height), strokeWidth = if (major) 2.dp.toPx() else 1.dp.toPx())
                }
                val x = size.width * autonomy.ordinal / (levels.size - 1)
                drawLine(ink, Offset(x, 0f), Offset(x, size.height), strokeWidth = 3.dp.toPx(), cap = StrokeCap.Round)
                drawCircle(ink, 5.dp.toPx(), Offset(x, 4.dp.toPx()))
            }
        }
        Row(Modifier.fillMaxWidth()) {
            levels.forEachIndexed { i, level ->
                Text(
                    level.label,
                    style = sans(13f, if (level == autonomy) FontWeight.SemiBold else FontWeight.Normal),
                    color = if (level == autonomy) p.text else p.textMuted,
                    textAlign = when (i) { 0 -> TextAlign.Start; levels.size - 1 -> TextAlign.End; else -> TextAlign.Center },
                    modifier = Modifier.weight(1f).pressWashClickable({ onAutonomy(level) }, cornerRadius = 8.dp).padding(vertical = 6.dp)
                        .semantics { stateDescription = if (level == autonomy) "Selected" else "Not selected" },
                )
            }
        }
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(p.ink(0.04f)).padding(vertical = 6.dp)) {
            Autonomy.capabilities.forEachIndexed { i, line ->
                val ok = autonomy.allows[i]
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Box(Modifier.size(22.dp).clip(CircleShape).background(if (ok) p.text else p.ink(0f)).border(1.5.dp, if (ok) p.text else p.hairline(0.25f), CircleShape), contentAlignment = Alignment.Center) {
                        if (ok) GlyphView(Glyph.Check, 12.dp, p.bg, strokeWidth = 3f)
                    }
                    Text(line, style = sans(15f), color = if (ok) p.text else p.textFaint)
                }
            }
        }
    }
}

@Composable
private fun ReadyStep(hostName: String?, modelLabel: String?, level: String, autonomy: Autonomy, starter: Int?, onStarter: (Int?) -> Unit) {
    val p = Theme.palette
    Column(Modifier.fillMaxWidth().widthIn(max = 520.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(p.ink(0.04f)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(Modifier.fillMaxWidth()) {
                Summary("Agent", "Graff", Modifier.weight(1f))
                Summary("Model", modelLabel ?: "Graff default", Modifier.weight(1f))
            }
            Row(Modifier.fillMaxWidth()) {
                Summary("Thinking", HarnessCatalog.reasoningLabel(level), Modifier.weight(1f))
                Summary("Access", autonomy.label, Modifier.weight(1f))
            }
            if (hostName != null) Summary("Computer", hostName, Modifier.fillMaxWidth())
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Onboarding.starters.forEachIndexed { i, (label, _) ->
                val on = starter == i
                Text(
                    label, style = sans(13f, FontWeight.Medium), color = if (on) p.bg else p.text,
                    modifier = Modifier.clip(RoundedCornerShape(16.dp)).background(if (on) p.text else p.ink(0.06f))
                        .pressWashClickable({ onStarter(if (on) null else i) }, cornerRadius = 16.dp).padding(horizontal = 12.dp, vertical = 8.dp),
                )
            }
        }
    }
}

@Composable
private fun Summary(label: String, value: String, modifier: Modifier) {
    val p = Theme.palette
    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(label, style = sans(12f), color = p.textMuted)
        Text(value, style = sans(16f, FontWeight.SemiBold), color = p.text, maxLines = 1)
    }
}

@Composable
private fun Footer(cta: String, busy: Boolean, error: String?, secondary: String, onPrimary: () -> Unit, onSecondary: (() -> Unit)?) {
    val p = Theme.palette
    Column(Modifier.fillMaxWidth().padding(vertical = 12.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (error != null) Text(error, style = sans(13f), color = p.danger, textAlign = TextAlign.Center)
        Box(
            Modifier.fillMaxWidth().widthIn(max = 520.dp).heightIn(min = 54.dp).clip(RoundedCornerShape(27.dp)).background(p.text.opacity(if (busy) 0.5f else 1f))
                .pressWashClickable(onPrimary, cornerRadius = 27.dp, enabled = !busy).testTag("onboarding-next"),
            contentAlignment = Alignment.Center,
        ) { Text(if (busy) "Saving..." else cta, style = sans(17f, FontWeight.SemiBold), color = p.bg) }
        Text(
            secondary, style = sans(14f), color = p.textMuted,
            modifier = if (onSecondary != null) Modifier.pressWashClickable(onSecondary, cornerRadius = 8.dp).padding(horizontal = 10.dp, vertical = 4.dp) else Modifier.padding(4.dp),
        )
    }
}
