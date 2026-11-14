// Compact companion strip shown above the composer or in the session header:
// summarizes active subagents, side chats, and live host terminals for a chat.
// Pure state resolution (`CompanionStripState.resolve`) is decoupled from UI so
// unit tests can exercise it directly.

import SwiftUI

enum CompanionSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case subagents
    case sideChats
    case terminals

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subagents: return "Subagents"
        case .sideChats: return "Side Chats"
        case .terminals: return "Terminals"
        }
    }

    var systemImage: String {
        switch self {
        case .subagents: return "person.2"
        case .sideChats: return "bubble.left.and.bubble.right"
        case .terminals: return "terminal"
        }
    }
}

struct CompanionSubagentItem: Identifiable, Equatable, Hashable, Sendable {
    enum Status: String, Equatable, Hashable, Sendable {
        case running
        case done
        case failed
        case stopped

        var isRunning: Bool { self == .running }

        var label: String {
            switch self {
            case .running: return "Running"
            case .done: return "Done"
            case .failed: return "Failed"
            case .stopped: return "Stopped"
            }
        }
    }

    let id: String
    let title: String
    let status: Status
    let detail: String
    let outputSummary: String?
    let outputBytes: Int64?
    let createdAt: Int64
}

enum CompanionSubagentExtractor {
    static func extract(from entries: [MessageEntry]) -> [CompanionSubagentItem] {
        var items: [CompanionSubagentItem] = []
        for entry in entries {
            for part in entry.parts {
                guard case .tool(let id, let call, let isError, let resolved) = part,
                      call.isSubagentSpawn else { continue }
                let status = resolveStatus(call: call, isError: isError, resolved: resolved)
                let title = AgentWork.subagentTitle(call) ?? "Subagent"
                let tail = call.subagentTail.map { AgentWork.firstLine($0, max: 120) }
                let summary = firstNonEmpty(
                    call.string("summary"),
                    call.string("output"),
                    call.string("result"),
                    tail
                )
                let detail: String
                switch status {
                case .running:
                    detail = (tail?.isEmpty == false ? tail : nil) ?? "Working"
                case .done:
                    detail = (summary?.isEmpty == false ? summary : nil) ?? "Ready to review"
                case .failed:
                    detail = (summary?.isEmpty == false ? summary : nil) ?? "Failed"
                case .stopped:
                    detail = "Stopped"
                }
                let outputBytes = (call.fields[RenderToolCall.outputBytesKey] as? Int64)
                    ?? (call.fields[RenderToolCall.outputBytesKey] as? Int).map(Int64.init)
                items.append(CompanionSubagentItem(
                    id: id,
                    title: title,
                    status: status,
                    detail: detail,
                    outputSummary: summary,
                    outputBytes: outputBytes,
                    createdAt: entry.createdAt
                ))
            }
        }
        return items
    }

    private static func resolveStatus(
        call: RenderToolCall,
        isError: Bool,
        resolved: Bool
    ) -> CompanionSubagentItem.Status {
        if let raw = call.subagentStatus {
            switch raw {
            case "running": return .running
            case "done": return .done
            case "cancelled": return .stopped
            default: return .failed
            }
        }
        if !resolved { return .running }
        return isError ? .failed : .done
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}

struct CompanionStripState: Equatable, Sendable {
    var subagents: Int
    var runningSubagents: Int
    var sideChats: Int
    var terminals: Int
    var liveTerminals: Int

    var isEmpty: Bool {
        subagents == 0 && sideChats == 0 && terminals == 0
    }

    static func resolve(
        chat: Chat,
        allChats: [Chat],
        entries: [MessageEntry],
        terminals: [HostTerminalSessionInfo]
    ) -> CompanionStripState {
        let extractedSubagents = CompanionSubagentExtractor.extract(from: entries)
        let runningCount = extractedSubagents.filter { $0.status.isRunning }.count
        let childChats = allChats.filter { !$0.archived && $0.parentChatId == chat.id }
        let chatTerminals = terminals.filter { $0.chatId == chat.id }
        let liveTerminalCount = chatTerminals.filter(\.isLive).count

        return CompanionStripState(
            subagents: extractedSubagents.count,
            runningSubagents: runningCount,
            sideChats: childChats.count,
            terminals: chatTerminals.count,
            liveTerminals: liveTerminalCount
        )
    }
}

struct CompanionStripView: View {
    let state: CompanionStripState
    var showNewTerminalButton: Bool = false
    let onSelect: (CompanionSection) -> Void
    var onNewTerminal: (() -> Void)? = nil

    init(
        state: CompanionStripState,
        showNewTerminalButton: Bool = false,
        onSelect: @escaping (CompanionSection) -> Void,
        onNewTerminal: (() -> Void)? = nil
    ) {
        self.state = state
        self.showNewTerminalButton = showNewTerminalButton
        self.onSelect = onSelect
        self.onNewTerminal = onNewTerminal
    }

    var body: some View {
        if state.isEmpty && !showNewTerminalButton {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if state.subagents > 0 {
                        agentsChip
                    }
                    if state.sideChats > 0 {
                        sideChatsChip
                    }
                    if state.terminals > 0 {
                        terminalsChip
                    }
                    if showNewTerminalButton {
                        newTerminalChip
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("companion-strip")
        }
    }

    private var agentsChip: some View {
        Button {
            onSelect(.subagents)
        } label: {
            HStack(spacing: 6) {
                if state.runningSubagents > 0 {
                    RingSpinner(diameter: 12, stroke: 1.5)
                    Text("\(state.runningSubagents) working")
                        .monospacedDigit()
                } else {
                    Image(systemName: "person.2")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                    Text(state.subagents == 1 ? "1 agent" : "\(state.subagents) agents")
                        .monospacedDigit()
                }
            }
            .modifier(CompanionChipSurface())
        }
        .buttonStyle(ChipPressButtonStyle())
        .accessibilityIdentifier("chip-agents")
    }

    private var sideChatsChip: some View {
        Button {
            onSelect(.sideChats)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                Text(state.sideChats == 1 ? "1 side chat" : "\(state.sideChats) side chats")
                    .monospacedDigit()
            }
            .modifier(CompanionChipSurface())
        }
        .buttonStyle(ChipPressButtonStyle())
        .accessibilityIdentifier("chip-side-chats")
    }

    private var terminalsChip: some View {
        Button {
            onSelect(.terminals)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(state.liveTerminals > 0 ? Theme.statusCompleted : Theme.textFaint.opacity(0.5))
                    .frame(width: 6, height: 6)
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                Text(state.terminals == 1 ? "1 terminal" : "\(state.terminals) terminals")
                    .monospacedDigit()
            }
            .modifier(CompanionChipSurface())
        }
        .buttonStyle(ChipPressButtonStyle())
        .accessibilityIdentifier("chip-terminals")
    }

    private var newTerminalChip: some View {
        Button {
            if let onNewTerminal {
                onNewTerminal()
            } else {
                onSelect(.terminals)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("Terminal")
            }
            .modifier(CompanionChipSurface(muted: true))
        }
        .buttonStyle(ChipPressButtonStyle())
        .accessibilityIdentifier("chip-new-terminal")
    }
}

private struct CompanionChipSurface: ViewModifier {
    var muted: Bool = false

    func body(content: Content) -> some View {
        content
            .font(Theme.sans(12, weight: .medium))
            .foregroundStyle(muted ? Theme.textMuted : Theme.text)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Theme.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(hairline(0.1), lineWidth: 1))
    }
}
