// First-run setup: which agent, how hard it thinks, how much it may do
// without asking, and whether to ping you, then a ready screen. Every step
// sets the real default it shows (the new-session agent, model and effort;
// the computer's autonomy; the notification kinds). Notification permission
// is asked only after Yes. Narrow windows stack each step; wide ones (iPhone
// Duo opened flat, iPad) put the question beside its control.

import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    /// Called once the setup is done or skipped.
    let onFinish: () -> Void

    @AppStorage("newSessionHarness") private var storedHarness = "claude-code"
    @AppStorage("newSessionModel") private var storedModel = ""
    @AppStorage("newSessionReasoning") private var storedReasoning = ""

    enum Step: Int, CaseIterable { case agent, effort, autonomy, notify, ready }

    /// Screenshot rig: `-setup-step N` opens on step N (0 to 4) in demo mode.
    @State private var step: Step = {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-demo"), let ix = args.firstIndex(of: "-setup-step"), ix + 1 < args.count,
              let n = Int(args[ix + 1]), let step = Step(rawValue: n) else { return .agent }
        return step
    }()
    @State private var hostId: String?
    @State private var agents: [AgentDescriptor] = []
    @State private var agentsLoaded = false
    @State private var extras: Set<String> = []
    @State private var models: [ModelInfo] = []
    @State private var modelId: String?
    @State private var level = "high"
    @State private var autonomy: Autonomy = .workspace
    @State private var notify = true
    @State private var kinds = Set(PushNotifications.Kind.allCases)
    @State private var starter: Int?
    @State private var saving = false
    @State private var error: String?

    private static let optionalAgents: [(id: String, name: String, mark: String)] = [
        ("claude-code", "Claude Code", "asterisk"),
        ("codex", "OpenAI Codex", "circle.circle"),
    ]

    private var hosts: [DeviceRow] {
        let candidates = model.executionDevices
        return candidates.filter { model.deviceOnline($0.id) } + candidates.filter { !model.deviceOnline($0.id) }
    }

    private var host: DeviceRow? {
        hosts.first { $0.id == hostId } ?? hosts.first
    }

    private var selectedModel: ModelInfo? {
        models.first { $0.id == modelId } ?? models.first
    }

    private var ladder: [String] {
        let levels = selectedModel?.reasoningLevels ?? []
        return levels.isEmpty ? Onboarding.fallbackLadder : levels
    }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 700 && geo.size.width > geo.size.height
            VStack(spacing: 0) {
                if wide {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            if step != .ready { header }
                            Spacer(minLength: 16)
                            titleBlock(alignment: .leading)
                            if step == .effort { modelToggle.padding(.top, 24) }
                            Spacer(minLength: 16)
                        }
                        .padding(.horizontal, 28)
                        .frame(width: geo.size.width / 2)
                        Rectangle().fill(Theme.border).frame(width: 1)
                        VStack(spacing: 0) {
                            ScrollView { control(wide: true).padding(.top, 40) }
                                .scrollBounceBehavior(.basedOnSize)
                            footer
                        }
                        .padding(.horizontal, 28)
                    }
                } else {
                    if step != .ready { header.padding(.horizontal, 20) }
                    ScrollView {
                        VStack(spacing: 0) {
                            titleBlock(alignment: .center).padding(.top, 20)
                            if step == .effort { modelToggle.padding(.top, 24) }
                            control(wide: false).padding(.top, 24)
                        }
                        .padding(.horizontal, 20)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    footer.padding(.horizontal, 20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await loadHost() }
        .task(id: host?.id) { await loadHost() }
        .accessibilityIdentifier("setup-\(stepName)")
    }

    private var stepName: String {
        switch step {
        case .agent: "agent"
        case .effort: "effort"
        case .autonomy: "autonomy"
        case .notify: "notify"
        case .ready: "ready"
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                if let back = Step(rawValue: step.rawValue - 1) { withAnimation(.snappy) { step = back } }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44)
                    .background(Theme.bg, in: Circle())
                    .overlay(Circle().stroke(Theme.border))
            }
            .opacity(step == .agent ? 0 : 1)
            .disabled(step == .agent)
            .accessibilityLabel("Back")
            .accessibilityIdentifier("setup-back")
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(i <= step.rawValue ? Theme.text : Theme.border)
                        .frame(height: 3)
                }
            }
            Text("\(min(step.rawValue + 1, 4))/4")
                .font(Theme.sans(14))
                .foregroundStyle(Theme.textMuted)
                .monospacedDigit()
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func titleBlock(alignment: HorizontalAlignment) -> some View {
        let textAlign: TextAlignment = alignment == .center ? .center : .leading
        VStack(alignment: alignment, spacing: 10) {
            if step == .ready {
                Image(systemName: "macmini.fill")
                    .font(.system(size: 88, weight: .thin))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.vertical, 12)
                    .frame(maxWidth: alignment == .center ? .infinity : nil)
            }
            Text(title)
                .font(Theme.sans(alignment == .center ? 28 : 34, weight: .semibold))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(textAlign)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.sans(14.5))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(textAlign)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }

    private var title: String {
        switch step {
        case .agent: "Which agent starts your sessions?"
        case .effort: "How hard should it think?"
        case .autonomy: "How much can it do without asking?"
        case .notify: "Ping you when it needs you?"
        case .ready: "Your first agent is ready"
        }
    }

    private var subtitle: String? {
        switch step {
        case .agent: "Graff is already connected through your CodeGraff sign-in. Add Claude Code or Codex too if you use them."
        case .effort: "Your default for new Graff sessions. Change it per message from the composer."
        case .autonomy: nil
        case .notify: nil
        case .ready: host.map { "Graff is live on \($0.name)." } ?? "Graff is ready."
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let error {
                Text(error)
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await advance() }
            } label: {
                HStack(spacing: 6) {
                    if saving { ProgressView().tint(Theme.bg) }
                    Text(cta)
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
                }
                .font(Theme.sans(17, weight: .semibold))
                .foregroundStyle(Theme.bg)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Theme.text, in: Capsule())
            }
            .disabled(saving)
            .accessibilityIdentifier("setup-next")
            if step == .ready {
                Text("Change any of this in Settings")
                    .font(Theme.sans(13.5))
                    .foregroundStyle(Theme.textMuted)
            } else {
                Button("Skip setup") { finish() }
                    .font(Theme.sans(13.5))
                    .foregroundStyle(Theme.textMuted)
                    .accessibilityIdentifier("setup-skip")
            }
        }
        .padding(.vertical, 12)
    }

    private var cta: String {
        switch step {
        case .notify: notify ? "Turn on" : "Next"
        case .ready: "Start a session"
        default: "Next"
        }
    }

    // MARK: Steps

    @ViewBuilder
    private func control(wide: Bool) -> some View {
        switch step {
        case .agent: agentStep
        case .effort: effortStep
        case .autonomy: autonomyStep
        case .notify: notifyStep
        case .ready: readyStep
        }
    }

    private var agentStep: some View {
        VStack(spacing: 14) {
            if hosts.count > 1 {
                Menu {
                    ForEach(hosts) { h in
                        Button(model.deviceOnline(h.id) ? h.name : "\(h.name) (offline)") { hostId = h.id }
                    }
                } label: { hostChip }
                .accessibilityIdentifier("setup-host")
            } else if host != nil {
                hostChip
            }
            agentCard(name: "Graff", mark: nil, detail: "Connected with your CodeGraff account",
                      ok: true, selected: true, recommended: true)
                .accessibilityIdentifier("setup-agent-graff")
            Text("OPTIONAL EXTRAS")
                .font(Theme.sans(12, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            ForEach(Self.optionalAgents, id: \.id) { agent in
                let status = extraStatus(agent.id)
                Button {
                    guard status == .ready || status == .off else { return }
                    if extras.contains(agent.id) { extras.remove(agent.id) } else { extras.insert(agent.id) }
                } label: {
                    agentCard(name: agent.name, mark: agent.mark, detail: extraDetail(status),
                              ok: status == .ready, selected: extras.contains(agent.id), recommended: false)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("setup-agent-\(agent.id)")
                .accessibilityAddTraits(extras.contains(agent.id) ? .isSelected : [])
            }
            Text("No extra setup for Graff. Add others any time in Settings.")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
    }

    private var hostChip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(host.map { model.deviceOnline($0.id) } == true ? Theme.statusCompleted : Theme.textFaint)
                .frame(width: 7, height: 7)
            Text(host?.name ?? "")
                .font(Theme.sans(14.5, weight: .medium))
                .foregroundStyle(Theme.text)
            if hosts.count > 1 {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .overlay(Capsule().stroke(Theme.border))
    }

    private func agentCard(name: String, mark: String?, detail: String, ok: Bool,
                           selected: Bool, recommended: Bool) -> some View {
        HStack(spacing: 14) {
            Group {
                if let mark {
                    Image(systemName: mark).font(.system(size: 20, weight: .medium))
                        .foregroundStyle(mark == "asterisk" ? Theme.claudeBrand : Theme.text)
                } else {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
            }
            .frame(width: 46, height: 46)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(name).font(Theme.sans(17, weight: .semibold)).foregroundStyle(Theme.text)
                    if recommended {
                        Text("Recommended")
                            .font(Theme.sans(12, weight: .medium))
                            .foregroundStyle(Theme.bg)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Theme.text, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(ok ? Theme.statusCompleted : Theme.textFaint).frame(width: 6, height: 6)
                    Text(detail).font(Theme.sans(13.5)).foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(selected ? Theme.text : Theme.textFaint)
        }
        .padding(16)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? Theme.text : Theme.border,
                                                          lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
    }

    private func extraStatus(_ id: String) -> AgentStatus {
        guard let agent = agents.first(where: { $0.id == id }) else { return agentsLoaded ? .missing : .ready }
        if !agent.installed { return agent.canInstall ? .canInstall : .missing }
        return agent.enabled == false ? .off : .ready
    }

    private func extraDetail(_ status: AgentStatus) -> String {
        let name = host?.name ?? "your computer"
        switch status {
        case .ready: return "Ready on \(name)"
        case .off: return "Installed, switched off. Pick it to turn it on."
        case .canInstall: return "Install it from Settings on \(name)"
        case .missing: return "Not found on \(name)"
        }
    }

    private var modelToggle: some View {
        VStack(spacing: 8) {
            if models.count > 1 {
                HStack(spacing: 4) {
                    ForEach(models.prefix(3)) { m in
                        Button {
                            modelId = m.id
                            if !ladder.contains(level) { level = ladder.contains("high") ? "high" : ladder[ladder.count / 2] }
                        } label: {
                            Text(m.label)
                                .font(Theme.sans(14.5, weight: .medium))
                                .foregroundStyle(m.id == selectedModel?.id ? Theme.text : Theme.textMuted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(m.id == selectedModel?.id ? Theme.bg : .clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("setup-model-\(m.id)")
                    }
                }
                .padding(4)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
            } else if let only = models.first {
                Text(only.label).font(Theme.sans(15, weight: .medium)).foregroundStyle(Theme.text)
            }
            Text("Graff models from your CodeGraff account")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.textMuted)
        }
    }

    private var effortStep: some View {
        let index = ladder.firstIndex(of: level) ?? 0
        return VStack(spacing: 18) {
            EffortDial(count: ladder.count, index: Binding(
                get: { index },
                set: { level = ladder[max(0, min(ladder.count - 1, $0))] }
            ), label: HarnessCatalog.reasoningLabel(level))
            .frame(width: 300, height: 290)
            HStack(spacing: 16) {
                stepButton("minus", enabled: index > 0) { level = ladder[index - 1] }
                    .accessibilityIdentifier("setup-effort-down")
                Text(Onboarding.effortBlurb(level))
                    .font(Theme.sans(14.5))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                stepButton("plus", enabled: index < ladder.count - 1) { level = ladder[index + 1] }
                    .accessibilityIdentifier("setup-effort-up")
            }
        }
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(enabled ? Theme.text : Theme.textFaint)
                .frame(width: 60, height: 60)
                .overlay(Circle().stroke(Theme.border))
        }
        .disabled(!enabled)
    }

    private var autonomyStep: some View {
        let all = Autonomy.allCases
        let index = all.firstIndex(of: autonomy) ?? 1
        return VStack(spacing: 16) {
            Text(autonomy.label)
                .font(Theme.sans(52, weight: .bold))
                .foregroundStyle(Theme.text)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .contentTransition(.numericText())
            Text(autonomy.blurb)
                .font(Theme.sans(14.5))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
            AutonomyRuler(index: Binding(get: { index }, set: { autonomy = all[$0] }), count: all.count)
                .frame(height: 74)
                .padding(.top, 6)
            HStack {
                ForEach(all) { level in
                    Button { withAnimation(.snappy) { autonomy = level } } label: {
                        Text(level.label)
                            .font(Theme.sans(14, weight: level == autonomy ? .semibold : .regular))
                            .foregroundStyle(level == autonomy ? Theme.text : Theme.textFaint)
                            .frame(maxWidth: .infinity,
                                   alignment: level == .readOnly ? .leading : level == .fullAccess ? .trailing : .center)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("setup-autonomy-\(level.rawValue)")
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(Autonomy.capabilities.enumerated()), id: \.offset) { i, text in
                    if i > 0 { Divider().overlay(Theme.border) }
                    let on = autonomy.allows[i]
                    HStack(spacing: 14) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(on ? Theme.text : Theme.textFaint)
                        Text(text).font(Theme.sans(15.5)).foregroundStyle(on ? Theme.text : Theme.textFaint)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 13)
                }
            }
            .padding(.horizontal, 18)
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.border))
            .padding(.top, 10)
        }
    }

    private var notifyStep: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "apple.terminal.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.bg)
                    .frame(width: 44, height: 44)
                    .background(Theme.text, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Waiting on your input").font(Theme.sans(15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("Graff wants to run npm test").font(Theme.sans(14)).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Text("now").font(Theme.sans(13)).foregroundStyle(Theme.textMuted)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
            .accessibilityHidden(true)
            HStack(spacing: 14) {
                choiceCard("No", symbol: "xmark.circle", selected: !notify) { notify = false }
                    .accessibilityIdentifier("setup-notify-no")
                choiceCard("Yes", symbol: "checkmark.circle.fill", selected: notify) { notify = true }
                    .accessibilityIdentifier("setup-notify-yes")
            }
            if notify {
                VStack(spacing: 0) {
                    ForEach(Array(kindOrder.enumerated()), id: \.element) { i, kind in
                        if i > 0 { Divider().overlay(Theme.border) }
                        Toggle(kind.title, isOn: Binding(
                            get: { kinds.contains(kind) },
                            set: { on in if on { kinds.insert(kind) } else { kinds.remove(kind) } }
                        ))
                        .font(Theme.sans(15.5))
                        .foregroundStyle(Theme.text)
                        .tint(Theme.text)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("setup-notify-\(kind.rawValue)")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.border))
            }
            Text("iOS asks for permission only after you tap Yes.")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.textMuted)
                .padding(.top, 2)
        }
    }

    private let kindOrder: [PushNotifications.Kind] = [.input, .done, .failed]

    private func choiceCard(_ label: String, symbol: String, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 26, weight: .regular))
                Text(label).font(Theme.sans(17, weight: .semibold))
            }
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, minHeight: 130)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? Theme.text : Theme.border,
                                                              lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var readyStep: some View {
        VStack(spacing: 16) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    summary("Agent", "Graff")
                    summary("Model", selectedModel?.label ?? "Graff default")
                }
                Divider().overlay(Theme.border)
                GridRow {
                    summary("Thinking", HarnessCatalog.reasoningLabel(level))
                    summary("Access", autonomy.label)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .accessibilityIdentifier("setup-summary")
            HStack(spacing: 10) {
                ForEach(Array(Onboarding.starters.enumerated()), id: \.offset) { i, item in
                    Button { starter = starter == i ? nil : i } label: {
                        Text(item.0)
                            .font(Theme.sans(14.5, weight: .medium))
                            .foregroundStyle(starter == i ? Theme.bg : Theme.text)
                            .padding(.horizontal, 14)
                            .frame(height: 38)
                            .background(starter == i ? Theme.text : Theme.bg, in: Capsule())
                            .overlay(Capsule().stroke(Theme.border))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("setup-starter-\(i)")
                }
            }
        }
    }

    private func summary(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.sans(13)).foregroundStyle(Theme.textMuted)
            Text(value).font(Theme.sans(17, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    // MARK: Loading and saving

    private func loadHost() async {
        if hostId == nil { hostId = hosts.first?.id }
        guard let deviceId = host?.id else { return }
        if let demo = model.demo {
            agents = demo.agents[deviceId] ?? []
        } else {
            agents = await model.workspace?.agentDescriptors(deviceId: deviceId) ?? []
        }
        agentsLoaded = true
        let catalog = await model.listModels(deviceId: deviceId, harness: "graff")
        models = Array(catalog.items.filter { !$0.id.isEmpty }.prefix(3))
        if modelId == nil || !models.contains(where: { $0.id == modelId }) { modelId = models.first?.id }
        if let current = try? await model.autonomy(deviceId: deviceId) {
            // A level someone picked stays; otherwise fresh setups start at Workspace.
            if current.chosen { autonomy = current.autonomy }
        }
    }

    private func advance() async {
        error = nil
        switch step {
        case .agent:
            // Graff is the default agent for new sessions; picked extras get switched on there.
            storedHarness = "graff"
            if let deviceId = host?.id {
                for id in extras where extraStatus(id) == .off {
                    try? await model.setHarnessEnabled(deviceId: deviceId, harness: id, enabled: true)
                }
            }
        case .effort:
            if let selectedModel { storedModel = selectedModel.id }
            storedReasoning = level
        case .autonomy:
            if let deviceId = host?.id {
                saving = true
                defer { saving = false }
                do {
                    autonomy = try await model.setAutonomy(deviceId: deviceId, autonomy).autonomy
                } catch {
                    let name = model.deviceName(deviceId)
                    if case RelayError.rpc(let message) = error, message.contains("unknown method") {
                        self.error = "Update Harness on \(name) to set this from your phone."
                    } else {
                        self.error = "Couldn't reach \(name). Try again, or skip and set it in Settings."
                    }
                    return
                }
            }
        case .notify:
            let push = PushNotifications.shared
            for kind in PushNotifications.Kind.allCases { push.set(kind, kinds.contains(kind)) }
            push.enabled = notify
            // The system prompt comes only after Yes, never at launch.
            if notify { _ = await push.requestPermission() }
        case .ready:
            if let deviceId = host?.id {
                let destination = NewSessionDestination.projectless(deviceId: deviceId)
                if let starter {
                    DraftStore.save(Onboarding.starters[starter].1, for: DraftStore.newSessionKey(destination))
                }
                finish()
                model.launchRoute = .newSession(destination)
            } else {
                finish()
            }
            return
        }
        if let next = Step(rawValue: step.rawValue + 1) { withAnimation(.snappy) { step = next } }
    }

    private func finish() {
        Onboarding.finish()
        onFinish()
    }
}

/// The effort dial: stops on a 270 degree arc, filled up to the pick.
struct EffortDial: View {
    let count: Int
    @Binding var index: Int
    let label: String

    private func angle(_ i: Int) -> Angle {
        .degrees(135 + Double(i) * (270 / Double(max(count - 1, 1))))
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = size / 2 - 34
            let point = { (i: Int, r: CGFloat) -> CGPoint in
                let a = angle(i).radians
                return CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
            }
            ZStack {
                Path { p in
                    p.addArc(center: center, radius: radius, startAngle: angle(0), endAngle: angle(count - 1), clockwise: false)
                }
                .stroke(Theme.surfaceRaised, style: StrokeStyle(lineWidth: 26, lineCap: .round))
                Path { p in
                    p.addArc(center: center, radius: radius, startAngle: angle(0), endAngle: angle(index), clockwise: false)
                }
                .stroke(Theme.text, style: StrokeStyle(lineWidth: 26, lineCap: .round))
                Circle()
                    .fill(Theme.surface)
                    .frame(width: radius * 1.3, height: radius * 1.3)
                    .position(center)
                VStack(spacing: 4) {
                    Text(label).font(Theme.sans(34, weight: .bold)).foregroundStyle(Theme.text)
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Text("Level \(index + 1) of \(count)").font(Theme.sans(14)).foregroundStyle(Theme.textMuted)
                }
                .frame(width: radius * 1.2)
                .position(center)
                ForEach(0..<count, id: \.self) { i in
                    let selected = i == index
                    Circle()
                        .fill(Theme.bg)
                        .overlay(Circle().stroke(i <= index ? Theme.text : Theme.border, lineWidth: selected ? 3 : 1.5))
                        .frame(width: selected ? 34 : 20, height: selected ? 34 : 20)
                        .position(point(i, radius))
                    Text("\(i + 1)")
                        .font(Theme.sans(13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.text : Theme.textFaint)
                        .position(point(i, radius + 30))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                var a = atan2(value.location.y - center.y, value.location.x - center.x) * 180 / .pi
                if a < 135 - 45 { a += 360 }
                let step = 270 / Double(max(count - 1, 1))
                let i = Int(((a - 135) / step).rounded())
                let clamped = max(0, min(count - 1, i))
                if clamped != index { index = clamped }
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Thinking effort")
        .accessibilityValue(label)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: index = min(count - 1, index + 1)
            case .decrement: index = max(0, index - 1)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("setup-effort-dial")
    }
}

/// The autonomy ruler: ticks across three levels, solid up to the pick.
struct AutonomyRuler: View {
    @Binding var index: Int
    let count: Int
    private let ticks = 41

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let pickX = width * CGFloat(index) / CGFloat(max(count - 1, 1))
            ZStack(alignment: .topLeading) {
                ForEach(0..<ticks, id: \.self) { t in
                    let x = width * CGFloat(t) / CGFloat(ticks - 1)
                    let major = t % ((ticks - 1) / max(count - 1, 1)) == 0
                    Rectangle()
                        .fill(x <= pickX + 0.5 ? Theme.text : Theme.border)
                        .frame(width: major ? 2 : 1.2, height: major ? 52 : (t % 2 == 0 ? 36 : 28))
                        .position(x: x, y: 44 - (major ? 0 : (t % 2 == 0 ? 8 : 12)))
                }
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text)
                    .position(x: pickX, y: 8)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let i = Int((value.location.x / max(width, 1) * CGFloat(count - 1)).rounded())
                let clamped = max(0, min(count - 1, i))
                if clamped != index { withAnimation(.snappy) { index = clamped } }
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Autonomy")
        .accessibilityValue(Autonomy.allCases[index].label)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: index = min(count - 1, index + 1)
            case .decrement: index = max(0, index - 1)
            @unknown default: break
            }
        }
    }
}
