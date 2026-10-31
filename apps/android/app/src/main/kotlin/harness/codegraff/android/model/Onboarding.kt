package harness.codegraff.android.model

import android.content.Context

/**
 * How much an agent may do without asking: the engine's device-wide `GetAutonomy` / `SetAutonomy` setting
 * (Onboarding.swift on iOS). The engine keeps full access until someone picks, so nothing changes for a
 * computer nobody set up.
 */
enum class Autonomy(val wire: String, val label: String, val blurb: String, val allows: List<Boolean>) {
    ReadOnly("read-only", "Read only", "Reads and plans. Asks before it changes anything.", listOf(true, false, false, false)),
    Workspace("workspace", "Workspace", "Edits this project. Asks before anything else.", listOf(true, true, false, false)),
    FullAccess("full-access", "Full access", "Runs anything without asking.", listOf(true, true, true, true));

    companion object {
        /** The four things the setting decides, in the order the setup shows them. */
        val capabilities = listOf(
            "Read files and run searches",
            "Edit files in this project",
            "Run commands outside it",
            "Approve its own requests",
        )

        fun fromWire(wire: String): Autonomy = entries.firstOrNull { it.wire == wire } ?: FullAccess
    }
}

/** The engine's answer to `GetAutonomy` / `SetAutonomy`; [chosen] is false until someone picked a level there. */
data class AutonomySetting(val autonomy: Autonomy, val chosen: Boolean)

/**
 * First-run setup: three questions and a ready screen, each answer setting a real default. Shown once after a
 * fresh sign-in; Settings replays it. Installs that never pass through sign-in keep every default they had.
 */
object Onboarding {
    private const val PREFS = "harness-ui"
    private const val DONE = "onboarding.v1.done"
    private const val PENDING = "onboarding.v1.pending"

    /** A fresh sign-in: show the setup once, unless it already ran here. */
    fun signedInFresh(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(DONE, false)) prefs.edit().putBoolean(PENDING, true).apply()
    }

    fun isPending(context: Context): Boolean {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return prefs.getBoolean(PENDING, false) && !prefs.getBoolean(DONE, false)
    }

    fun finish(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(DONE, true).putBoolean(PENDING, false).apply()
    }

    /** What the effort dial says about each step of the ladder. */
    fun effortBlurb(level: String): String = when (level) {
        "minimal", "none" -> "Answers straight away."
        "low" -> "Quick answers and light edits."
        "medium" -> "Balanced for everyday changes."
        "high" -> "Thinks before it edits. The default for real work."
        "xhigh" -> "Longer reasoning for tricky bugs."
        "max" -> "Its hardest thinking."
        "ultracode" -> "Maximum effort for big code changes."
        "ultrathink" -> "Deep thinking before every step."
        else -> "How long it reasons before acting."
    }

    /** The ladder the dial shows when the model reports none. */
    val fallbackLadder = listOf("low", "medium", "high", "xhigh", "max", "ultracode", "ultrathink")

    /** Starter prompts on the ready screen. */
    val starters = listOf(
        "Tour this project" to "Give me a tour of this project: what it does, how it is laid out, and where to start.",
        "Build something new" to "Let's build something new. Ask me what I have in mind first.",
    )
}
