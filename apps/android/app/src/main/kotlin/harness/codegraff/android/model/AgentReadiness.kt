package harness.codegraff.android.model

/**
 * Whether someone has brought an agent in (AgentReadiness.swift on iOS). Harness runs the agent on a computer and
 * the phone is the remote, so "ready" means: some computer that is online reports Graff, Claude Code or Codex
 * (OpenAI) as found and switched on. The rules are pinned in `apps/parity/vectors/agent-readiness.json`.
 */

/**
 * One agent as a computer reports it in `ListHarnesses`. An absent `installed` or `enabled` reads as true, the way the
 * engine's `descriptor_enabled` does for the three default-on agents.
 */
data class AgentDescriptor(
    val id: String,
    val installed: Boolean = true,
    /** The computer can install this agent itself (Settings > Agents there). */
    val canInstall: Boolean = false,
    val enabled: Boolean? = null,
)

enum class AgentStatus(val wireName: String) {
    /** Not installed and not installable from that computer, or not reported at all. */
    Missing("missing"),
    CanInstall("canInstall"),

    /** Installed, but switched off in Settings > Agents. */
    Off("off"),
    Ready("ready"),
}

/** The three agents onboarding asks for. Everything else (Grok, Cursor and the rest) stays in Settings > Agents. */
data class OnboardingAgent(val id: String, val name: String, val blurb: String) {
    companion object {
        val ALL = listOf(
            OnboardingAgent("graff", "Graff", "CodeGraff's own agent, built into the Harness app."),
            OnboardingAgent("claude-code", "Claude Code", "Anthropic's coding agent. Install Claude Code and sign in on your computer."),
            OnboardingAgent("codex", "OpenAI Codex", "OpenAI's coding agent. Install Codex and sign in with ChatGPT on your computer."),
        )
    }
}

/** A computer and the agents it reports. */
data class DeviceAgents(val id: String, val name: String, val online: Boolean, val agents: List<AgentDescriptor>)

enum class OnboardingState { NoComputer, NoAgent, Ready }

data class AgentReadiness(val state: OnboardingState, val rows: List<Row>) {
    data class Row(
        val agent: OnboardingAgent,
        val status: AgentStatus,
        /** The online computers at this agent's best status, in the order given. */
        val deviceIds: List<String>,
    )

    companion object {
        /** The link that gets Harness onto a computer: the landing page picks the right download for the OS it is opened on. */
        const val DOWNLOAD_URL = "https://codegraff.com/"

        fun statusOf(agentId: String, agents: List<AgentDescriptor>): AgentStatus {
            val d = agents.firstOrNull { it.id == agentId } ?: return AgentStatus.Missing
            if (!d.installed) return if (d.canInstall) AgentStatus.CanInstall else AgentStatus.Missing
            return if (d.enabled ?: true) AgentStatus.Ready else AgentStatus.Off
        }

        fun evaluate(devices: List<DeviceAgents>): AgentReadiness {
            val online = devices.filter { it.online }
            if (online.isEmpty()) {
                return AgentReadiness(OnboardingState.NoComputer, OnboardingAgent.ALL.map { Row(it, AgentStatus.Missing, emptyList()) })
            }
            val rows = OnboardingAgent.ALL.map { agent ->
                val per = online.map { it.id to statusOf(agent.id, it.agents) }
                val best = per.maxOf { it.second }
                Row(agent, best, per.filter { it.second == best }.map { it.first })
            }
            return AgentReadiness(if (rows.any { it.status == AgentStatus.Ready }) OnboardingState.Ready else OnboardingState.NoAgent, rows)
        }
    }
}
