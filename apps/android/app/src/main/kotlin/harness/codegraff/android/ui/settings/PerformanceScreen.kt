package harness.codegraff.android.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import harness.codegraff.android.perf.FrameStage
import harness.codegraff.android.perf.Perf
import harness.codegraff.android.perf.PerfSpan
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.mono
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.sans
import kotlinx.coroutines.delay

/**
 * Settings > Performance. Shows what the on-device monitor has seen this run: startup, frame cost by
 * stage, main-thread stalls, and each measured operation against its budget. Nothing leaves the device;
 * "Copy report" puts numbers on the clipboard so they can be pasted into an issue.
 */
@Composable
internal fun PerformanceContent(version: String) {
    val p = Theme.palette
    // Re-read the counters once a second while the page is open.
    var tick by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) { while (true) { delay(1000); tick++ } }
    @Suppress("UNUSED_EXPRESSION") tick
    val frames = Perf.frames.snapshot()
    val memory = Perf.memory()
    val stats = Perf.recorder.stats()
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current

    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
        Section("Startup") {
            ValueRow("First frame", Perf.startupMs?.let { "$it ms" } ?: "Not measured this run")
        }
        Section("Frames") {
            ValueRow("Drawn", frames.frames.toString())
            Divider()
            ValueRow("Slow", "${frames.slow} (${"%.1f".format(frames.slowPercent)}%)")
            Divider()
            ValueRow("Frozen", frames.frozen.toString())
            Divider()
            ValueRow("Median · 95th", "${"%.1f".format(frames.p50)} · ${"%.1f".format(frames.p95)} ms")
            Divider()
            ValueRow("Worst", "${"%.0f".format(frames.worst)} ms")
        }
        if (frames.slowFramesBlamedOn.isNotEmpty()) {
            Section("Slow frames spend longest in") {
                frames.slowFramesBlamedOn.forEachIndexed { i, (stage: FrameStage, n) ->
                    if (i > 0) Divider()
                    ValueRow(stage.label, n.toString())
                }
            }
        }
        Section("Operations") {
            if (stats.isEmpty()) ValueRow("Nothing measured yet", "")
            stats.forEachIndexed { i, s ->
                if (i > 0) Divider()
                OperationRow(s.name, "×${s.count}", "${"%.1f".format(s.p50)} / ${"%.1f".format(s.p95)} / ${"%.1f".format(s.max)} ms", s.overBudget > 0, PerfSpan.budgetsMs[s.name])
            }
        }
        Section("Memory") {
            ValueRow("Java heap", "${memory.javaUsedMb} of ${memory.javaMaxMb} MB")
            Divider()
            ValueRow("Native heap", "${memory.nativeMb} MB")
            Divider()
            ValueRow("Garbage collections", "${memory.gcCount} · ${memory.gcTimeMs} ms")
        }
        Section("Device") {
            ValueRow("Thermal state", Perf.thermalLabel(context))
            Divider()
            ValueRow("Battery Saver", if (Perf.batterySaver(context)) "On" else "Off")
        }
        Section("Report") {
            ActionRow("Copy report", destructive = false) { clipboard.setText(AnnotatedString(Perf.report(context, version))) }
            Divider()
            ActionRow("Reset", destructive = true) { Perf.reset(); tick++ }
        }
        Text(
            "Measured on this device only and never sent anywhere. Operation columns are median, 95th and worst.",
            style = sans(12f), color = p.textMuted.opacity(0.7f), modifier = Modifier.padding(horizontal = 16.dp),
        )
    }
}

@Composable
private fun OperationRow(name: String, count: String, timings: String, overBudget: Boolean, budgetMs: Double?) {
    val p = Theme.palette
    Column(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(name, style = mono(14f, FontWeight.Medium), color = if (overBudget) p.danger else p.text, modifier = Modifier.weight(1f))
            Text(count, style = sans(13f), color = p.textMuted)
        }
        Text(
            timings + (budgetMs?.let { " · budget ${it.toLong()} ms" } ?: ""),
            style = sans(13f), color = p.textMuted,
        )
    }
}
