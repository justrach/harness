// Harness commands are local workspace actions, never provider invocations.
import SwiftUI

enum ComposerWorkspaceCommand: String, CaseIterable {
    case model, new, resume, settings, diff, files, terminal, rename, stop, help

    /// Match the desktop catalog, including the actions unavailable on iOS.
    var needsChat: Bool {
        switch self {
        case .diff, .files, .terminal, .rename, .stop: return true
        default: return false
        }
    }

    var isDesktopOnly: Bool {
        switch self {
        case .diff, .files, .terminal: return true
        default: return false
        }
    }

    var description: String {
        switch self {
        case .model: return "Harness: choose agent, model, and reasoning"
        case .new: return "Harness: start a new conversation"
        case .resume: return "Harness: search and open conversations"
        case .settings: return "Harness: open settings"
        case .diff: return "Harness: open changes (desktop only)"
        case .files: return "Harness: open project files (desktop only)"
        case .terminal: return "Harness: open a terminal (desktop only)"
        case .rename: return "Harness: rename this conversation"
        case .stop: return "Harness: stop the active run"
        case .help: return "Harness: show available commands"
        }
    }

    /// Provider names always win. Repeated prefixes also preserve providers
    /// which already own a name such as `harness:model`, exactly as on desktop.
    static func merging(providerCommands: [ComposerCommand], inChat: Bool) -> [ComposerCommand] {
        var rows = providerCommands.filter { $0.workspaceCommand == nil }
        var names = Set(rows.map(\.name))
        for command in allCases where inChat || !command.needsChat {
            var name = command.rawValue
            while names.contains(name) { name = "harness:\(name)" }
            names.insert(name)
            var row = ComposerCommand(name: name, description: command.description)
            row.workspaceCommand = command
            rows.append(row)
        }
        return rows
    }
}

private struct ComposerWorkspaceCommandActionKey: EnvironmentKey {
    static let defaultValue: ((ComposerWorkspaceCommand, ComposerCommandContext) -> Void)? = nil
}

extension EnvironmentValues {
    var composerWorkspaceCommandAction: ((ComposerWorkspaceCommand, ComposerCommandContext) -> Void)? {
        get { self[ComposerWorkspaceCommandActionKey.self] }
        set { self[ComposerWorkspaceCommandActionKey.self] = newValue }
    }
}

/// A read-only catalog: opening Help lists commands, but never invokes one or
/// inserts an invocation link into the draft. Provider rows are not truncated.
struct ComposerWorkspaceCommandHelp: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let context: ComposerCommandContext
    @State private var providerCommands: [ComposerCommand] = []
    @State private var loading = true
    @State private var failed = false
    @State private var retry = 0

    private var rows: [ComposerCommand] {
        ComposerWorkspaceCommand.merging(providerCommands: providerCommands, inChat: context.chatId != nil)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Harness actions") {
                    ForEach(rows.filter { $0.workspaceCommand != nil }) { command in
                        commandRow(command)
                    }
                }
                Section("Agent commands") {
                    if loading {
                        ProgressView("Loading commands…")
                    } else if failed {
                        Text("Couldn't load agent commands.")
                            .foregroundStyle(Theme.textMuted)
                        Button("Retry") { retry += 1 }
                    } else if providerCommands.isEmpty {
                        Text("This agent offers no commands.")
                            .foregroundStyle(Theme.textMuted)
                    } else {
                        ForEach(rows.filter { $0.workspaceCommand == nil }) { command in
                            commandRow(command)
                        }
                    }
                }
            }
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: retry) {
                loading = true
                failed = false
                do {
                    let catalog = try await model.listCommands(context)
                    guard !Task.isCancelled else { return }
                    var names: Set<String> = []
                    providerCommands = catalog.filter { names.insert($0.name).inserted }
                } catch {
                    guard !Task.isCancelled else { return }
                    failed = true
                }
                loading = false
            }
        }
    }

    private func commandRow(_ command: ComposerCommand) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("/\(command.name)").font(Theme.sans(15, weight: .medium))
                if command.workspaceCommand?.isDesktopOnly == true {
                    Text("Desktop only")
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            if let description = command.description, !description.isEmpty {
                Text(description).font(Theme.sans(12)).foregroundStyle(Theme.textMuted)
            }
            if let hint = command.inputHint, !hint.isEmpty {
                Text(hint).font(Theme.sans(12)).foregroundStyle(Theme.textFaint)
            }
        }
        .opacity(command.workspaceCommand?.isDesktopOnly == true ? 0.55 : 1)
    }
}
