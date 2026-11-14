// Segmented companion sheet for a session: Subagents, Side Chats, and Live Host Terminals.
// Follows Harness's SheetUI grouped-card design language and Theme tokens.

import SwiftUI

struct SessionCompanionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let chat: Chat
    var initialSection: CompanionSection
    var onOpenChat: (String) -> Void

    @State private var section: CompanionSection
    @State private var expandedSubagentIds: Set<String> = []
    @State private var sideChatTitle = ""
    @State private var creatingSideChat = false
    @State private var sideChatError: String?
    @State private var terminalStore = HostTerminalStore.shared

    init(
        chat: Chat,
        initialSection: CompanionSection = .subagents,
        onOpenChat: @escaping (String) -> Void
    ) {
        self.chat = chat
        self.initialSection = initialSection
        self.onOpenChat = onOpenChat
        _section = State(initialValue: initialSection)
    }

    private var allChats: [Chat] {
        model.demo?.chats ?? model.workspace?.chats ?? []
    }

    private var sideChats: [Chat] {
        sortActive(allChats.filter { !$0.archived && $0.parentChatId == chat.id })
    }

    private var subagents: [CompanionSubagentItem] {
        let entries = model.sessionStore(for: chat)?.entries ?? []
        return CompanionSubagentExtractor.extract(from: entries)
    }

    private var inheritedSpaceName: String? {
        model.space(for: chat)?.displayName
    }

    private var inheritedHarnessLabel: String {
        HarnessCatalog.label(for: chat.config?.harness ?? "claude-code")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Companions", selection: $section) {
                    ForEach(CompanionSection.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 12)
                .accessibilityIdentifier("companions-segment-picker")

                Group {
                    switch section {
                    case .subagents:
                        subagentsView
                    case .sideChats:
                        sideChatsView
                    case .terminals:
                        terminalsView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Companions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("companions-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .harnessAppearance()
    }

    // MARK: - Subagents

    private var subagentsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if subagents.isEmpty {
                    emptyStateCard(
                        systemImage: "person.2",
                        title: "No subagents yet",
                        message: "Subagent tool calls spawned during this session appear here with live status and output."
                    )
                } else {
                    SheetLabel("\(subagents.count) \(subagents.count == 1 ? "subagent" : "subagents")")
                    SheetCard {
                        ForEach(Array(subagents.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { SheetSeparator() }
                            subagentRow(item)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func subagentRow(_ item: CompanionSubagentItem) -> some View {
        let expanded = expandedSubagentIds.contains(item.id)
        return Button {
            withAnimation(Motion.collapse) {
                if expanded {
                    expandedSubagentIds.remove(item.id)
                } else {
                    expandedSubagentIds.insert(item.id)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    subagentGlyph(item.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(Theme.sans(15, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text(item.detail)
                            .font(Theme.sans(12.5))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(expanded ? 6 : 1)
                    }
                    Spacer(minLength: 8)
                    StatusChip(label: item.status.label, hue: subagentHue(item.status))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 4) {
                        if let summary = item.outputSummary, !summary.isEmpty {
                            Text(summary)
                                .font(Theme.mono(12))
                                .foregroundStyle(Theme.textMuted)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let bytes = item.outputBytes, bytes > 0 {
                            Text("Output: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                                .font(Theme.sans(11.5))
                                .foregroundStyle(Theme.textFaint)
                        }
                    }
                    .padding(10)
                    .background(ink(0.035), in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(SheetRowButtonStyle())
        .accessibilityIdentifier("subagent-row-\(item.id)")
    }

    @ViewBuilder
    private func subagentGlyph(_ status: CompanionSubagentItem.Status) -> some View {
        switch status {
        case .running:
            RingSpinner(diameter: 18, stroke: 2)
        case .done:
            CheckDot(diameter: 18)
        case .failed:
            Circle()
                .fill(Theme.danger.opacity(0.16))
                .frame(width: 18, height: 18)
                .overlay {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.danger)
                }
        case .stopped:
            Circle()
                .strokeBorder(Theme.textFaint, lineWidth: 1.5)
                .frame(width: 18, height: 18)
        }
    }

    private func subagentHue(_ status: CompanionSubagentItem.Status) -> Color {
        switch status {
        case .running: return Theme.statusWorking
        case .done: return Theme.statusCompleted
        case .failed: return Theme.danger
        case .stopped: return Theme.textMuted
        }
    }

    // MARK: - Side Chats

    private var sideChatsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    SheetLabel("New Side Chat")
                    SheetCard {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Title (optional)", text: $sideChatTitle)
                                .font(Theme.sans(15))
                                .foregroundStyle(Theme.text)
                                .submitLabel(.done)
                                .accessibilityIdentifier("side-chat-title-field")

                            HStack(spacing: 6) {
                                if let space = inheritedSpaceName {
                                    Label(space, systemImage: "folder")
                                } else if let cwd = chat.cwd, !cwd.isEmpty {
                                    Label((cwd as NSString).lastPathComponent, systemImage: "folder")
                                }
                                Text("·")
                                Text(inheritedHarnessLabel)
                                if let branch = chat.branch, !branch.isEmpty {
                                    Text("·")
                                    Label(branch, systemImage: "arrow.triangle.branch")
                                }
                            }
                            .font(Theme.sans(12))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)

                            if let sideChatError {
                                Text(sideChatError)
                                    .font(Theme.sans(12.5))
                                    .foregroundStyle(Theme.danger)
                            }

                            Button {
                                Task { await createSideChat() }
                            } label: {
                                HStack(spacing: 8) {
                                    if creatingSideChat {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "plus.bubble")
                                            .font(.system(size: 14, weight: .semibold))
                                    }
                                    Text(creatingSideChat ? "Creating…" : "Create Side Chat")
                                        .font(Theme.sans(14, weight: .semibold))
                                }
                                .foregroundStyle(Theme.onAccent)
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                                .background(Theme.accent, in: Capsule())
                            }
                            .buttonStyle(PressScaleButtonStyle())
                            .disabled(creatingSideChat)
                            .accessibilityIdentifier("create-side-chat-button")
                        }
                        .padding(16)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    SheetLabel("Existing Side Chats")
                    if sideChats.isEmpty {
                        emptyStateCard(
                            systemImage: "bubble.left.and.bubble.right",
                            title: "No side chats",
                            message: "Spin up a parallel thread in the same workspace without leaving this session."
                        )
                    } else {
                        SheetCard {
                            ForEach(Array(sideChats.enumerated()), id: \.element.id) { index, child in
                                if index > 0 { SheetSeparator() }
                                sideChatRow(child)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func sideChatRow(_ child: Chat) -> some View {
        let indicator = model.indicator(for: child)
        return Button {
            dismiss()
            onOpenChat(child.id)
        } label: {
            HStack(spacing: 12) {
                HarnessBadge(harness: child.config?.harness ?? "claude-code", size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(child.displayTitle)
                        .font(Theme.sans(15, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if let preview = child.lastMessagePreview, !preview.isEmpty {
                        Text(preview)
                            .font(Theme.sans(12.5))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                StatusCorner(indicator: indicator)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(SheetRowButtonStyle())
        .accessibilityIdentifier("side-chat-row-\(child.id)")
    }

    private func createSideChat() async {
        guard !creatingSideChat else { return }
        creatingSideChat = true
        sideChatError = nil
        defer { creatingSideChat = false }

        let trimmedTitle = sideChatTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
        let inheritedConfig = chat.config ?? ChatConfig(harness: "claude-code")
        let newChatId = UUID().uuidString.lowercased()

        if let demo = model.demo {
            let now = nowMs()
            let newChat = Chat(
                id: newChatId,
                deviceId: chat.deviceId,
                title: resolvedTitle,
                archived: false,
                cwd: chat.cwd ?? model.space(for: chat)?.path ?? "~",
                branch: chat.branch,
                checkoutId: chat.checkoutId,
                config: inheritedConfig,
                lastMessagePreview: nil,
                lastMessageAt: nil,
                createdAt: now,
                spaceId: chat.spaceId,
                lastSeenAt: now,
                roomGen: 2,
                lastPromptAt: nil,
                parentChatId: chat.id
            )
            demo.chats.append(newChat)
            sideChatTitle = ""
            dismiss()
            onOpenChat(newChatId)
            return
        }

        guard let workspace = model.workspace else {
            sideChatError = RelayError.notConnected.errorDescription
            return
        }

        var params: [String: Any] = [
            "op": "createChat",
            "chatId": newChatId,
            "deviceId": chat.deviceId,
            "parentChatId": chat.id,
        ]
        if let spaceId = chat.spaceId { params["spaceId"] = spaceId }
        if let cwd = chat.cwd { params["cwd"] = cwd }
        if let branch = chat.branch { params["branch"] = branch }
        if let encodedConfig = try? JSONEncoder().encode(inheritedConfig),
           let configObj = try? JSONSerialization.jsonObject(with: encodedConfig) {
            params["config"] = configObj
        }

        struct OkReply: Decodable { var ok: Bool? }
        do {
            let _: OkReply = try await workspace.relay(for: chat.deviceId)
                .call(method: "Mutate", params: params, timeoutSeconds: 15, retry: false)
            if let resolvedTitle {
                let _: OkReply? = try? await workspace.relay(for: chat.deviceId)
                    .call(method: "Mutate",
                          params: ["op": "renameChat", "chatId": newChatId, "title": resolvedTitle],
                          timeoutSeconds: 10,
                          retry: true)
            }
            sideChatTitle = ""
            dismiss()
            onOpenChat(newChatId)
        } catch {
            sideChatError = describeUserFacingError(error)
        }
    }

    // MARK: - Terminals

    private var terminalsView: some View {
        let sessions = terminalStore.sessions(for: chat.id)
        let activeId = terminalStore.activeTerminalId(for: chat.id)
        let isOpening = terminalStore.openingChatIds.contains(chat.id)

        return VStack(spacing: 0) {
            if !sessions.isEmpty {
                terminalTabBar(sessions: sessions, activeId: activeId, isOpening: isOpening)
            }

            if let activeId {
                HostTerminalView(store: terminalStore, terminalId: activeId, chat: chat)
                    .id(activeId)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        SheetCard {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 10) {
                                    Image(systemName: "terminal")
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundStyle(Theme.text)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Host Terminal")
                                            .font(Theme.sans(15, weight: .semibold))
                                            .foregroundStyle(Theme.text)
                                        Text("\(model.deviceName(chat.deviceId)) · \(chat.cwd ?? "~")")
                                            .font(Theme.mono(12))
                                            .foregroundStyle(Theme.textMuted)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                    }
                                }

                                if let err = terminalStore.lastErrorByChat[chat.id] {
                                    Text(err)
                                        .font(Theme.sans(12.5))
                                        .foregroundStyle(Theme.danger)
                                }

                                Button {
                                    Task { _ = await terminalStore.openTerminal(chat: chat, model: model) }
                                } label: {
                                    HStack(spacing: 8) {
                                        if isOpening {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Image(systemName: "plus")
                                                .font(.system(size: 13, weight: .semibold))
                                        }
                                        Text(isOpening ? "Opening shell…" : "Open Host Terminal")
                                            .font(Theme.sans(14, weight: .semibold))
                                    }
                                    .foregroundStyle(Theme.onAccent)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 42)
                                    .background(Theme.accent, in: Capsule())
                                }
                                .buttonStyle(PressScaleButtonStyle())
                                .disabled(isOpening)
                                .accessibilityIdentifier("open-host-terminal-button")
                            }
                            .padding(16)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func terminalTabBar(
        sessions: [HostTerminalSessionInfo],
        activeId: String?,
        isOpening: Bool
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sessions) { session in
                    let selected = session.id == activeId
                    HStack(spacing: 6) {
                        Button {
                            terminalStore.setActiveTerminal(session.id, for: chat.id)
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(session.isLive ? Theme.statusCompleted : Theme.textFaint.opacity(0.5))
                                    .frame(width: 6, height: 6)
                                Text(session.shell)
                                    .font(Theme.mono(12).weight(selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? Theme.text : Theme.textMuted)
                            }
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task {
                                await terminalStore.closeTerminal(id: session.id, for: chat.id, model: model)
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.textFaint)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close terminal")
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(selected ? Theme.surfaceRaised : ink(0.03), in: Capsule())
                    .overlay(Capsule().strokeBorder(selected ? Theme.borderStrong : Theme.border, lineWidth: 1))
                }

                Button {
                    Task { _ = await terminalStore.openTerminal(chat: chat, model: model) }
                } label: {
                    Group {
                        if isOpening {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                    .frame(width: 30, height: 30)
                    .background(ink(0.04), in: Circle())
                }
                .buttonStyle(PressScaleButtonStyle())
                .disabled(isOpening)
                .accessibilityIdentifier("new-terminal-tab-button")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    // MARK: - Shared Helpers

    private func emptyStateCard(systemImage: String, title: String, message: String) -> some View {
        SheetCard {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.textFaint)
                Text(title)
                    .font(Theme.sans(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(message)
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }
}
