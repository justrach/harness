// Whether someone has brought an agent in (AgentReadiness.kt on Android). Harness runs the agent on a computer
// and the phone is the remote, so "ready" means: some computer that is online reports Graff, Claude Code or Codex
// (OpenAI) as found and switched on. The rules are pinned in `apps/parity/vectors/agent-readiness.json`.

import Foundation

/// One agent as a computer reports it in `ListHarnesses`. An absent `installed` or `enabled` reads as true, the way
/// the engine's `descriptor_enabled` does for the three default-on agents.
struct AgentDescriptor: Equatable {
    let id: String
    var installed = true
    /// The computer can install this agent itself (Settings → Agents there).
    var canInstall = false
    var enabled: Bool?
}

enum AgentStatus: Int, Comparable {
    /// Not installed and not installable from that computer, or not reported at all.
    case missing
    case canInstall
    /// Installed, but switched off in Settings → Agents.
    case off
    case ready

    static func < (a: AgentStatus, b: AgentStatus) -> Bool { a.rawValue < b.rawValue }

    /// The names the shared vector uses.
    var wireName: String {
        switch self {
        case .missing: "missing"
        case .canInstall: "canInstall"
        case .off: "off"
        case .ready: "ready"
        }
    }
}

/// The three agents onboarding asks for. Everything else (Grok, Cursor and the rest) stays in Settings → Agents.
struct OnboardingAgent: Identifiable, Equatable {
    let id: String
    let name: String
    let blurb: String

    static let all: [OnboardingAgent] = [
        OnboardingAgent(id: "graff", name: "Graff",
                        blurb: "CodeGraff's own agent, built into the Harness app."),
        OnboardingAgent(id: "claude-code", name: "Claude Code",
                        blurb: "Anthropic's coding agent. Install Claude Code and sign in on your computer."),
        OnboardingAgent(id: "codex", name: "OpenAI Codex",
                        blurb: "OpenAI's coding agent. Install Codex and sign in with ChatGPT on your computer."),
    ]
}

/// A computer and the agents it reports.
struct DeviceAgents: Equatable {
    let id: String
    let name: String
    let online: Bool
    let agents: [AgentDescriptor]
}

enum OnboardingState: String, Equatable {
    case noComputer
    case noAgent
    case ready
}

struct AgentReadiness: Equatable {
    struct Row: Equatable {
        let agent: OnboardingAgent
        let status: AgentStatus
        /// The online computers at this agent's best status, in the order given.
        let deviceIds: [String]
    }

    let state: OnboardingState
    let rows: [Row]

    /// The link that gets Harness onto a computer: the landing page picks the right download for the OS it is opened on.
    static let downloadURL = "https://harness.codegraff.com/#downloads"

    static func status(of agentId: String, in agents: [AgentDescriptor]) -> AgentStatus {
        guard let d = agents.first(where: { $0.id == agentId }) else { return .missing }
        guard d.installed else { return d.canInstall ? .canInstall : .missing }
        return (d.enabled ?? true) ? .ready : .off
    }

    static func evaluate(_ devices: [DeviceAgents]) -> AgentReadiness {
        let online = devices.filter(\.online)
        guard !online.isEmpty else {
            return AgentReadiness(state: .noComputer,
                                  rows: OnboardingAgent.all.map { Row(agent: $0, status: .missing, deviceIds: []) })
        }
        let rows = OnboardingAgent.all.map { agent -> Row in
            let per = online.map { ($0.id, status(of: agent.id, in: $0.agents)) }
            let best = per.map(\.1).max() ?? .missing
            return Row(agent: agent, status: best, deviceIds: per.filter { $0.1 == best }.map(\.0))
        }
        return AgentReadiness(state: rows.contains { $0.status == .ready } ? .ready : .noAgent, rows: rows)
    }
}
