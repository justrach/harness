// The agent work chip and its card (desktop: crates/ui/src/agent_work.rs `footer_chip`, `work_card`).
//
// The chip sits beside the running indicator (the status strip, the Duo's status pill) while the turn has
// to-do steps or subagents: a dot per step, joined in the accent between done steps and dashed from the
// active one on; "3/9" past six steps; "2 agents" when there are agents and no steps. Tapping it opens the
// card: the step timeline (the active step's latest tool calls under it), the subagents with their latest
// status, and the tools the turn used. Neutral roles and the accent come from the theme; blue marks a step
// waiting on the person, red a failed agent, as on the desktop. Reduced motion stops the spinners on a
// static partial ring.

import SwiftUI

/// The chip, and the card it opens. Draws nothing while the turn has no steps and no agents.
struct AgentWorkChip: View {
    let store: SessionStore
    /// On the Duo's glass pill row: its own glass capsule, the pill's height.
    var glass = false
    @State private var showCard = Self.demoCardOpen

    /// Rig (DEBUG): `-demo-agent-work-card` opens the card on launch, for screenshots without a tap.
    #if DEBUG
    private static let demoCardOpen = ProcessInfo.processInfo.arguments.contains("-demo-agent-work-card")
    #else
    private static let demoCardOpen = false
    #endif

    var body: some View {
        let work = AgentWork.work(store.entries)
        if !work.isEmpty {
            Button {
                showCard = true
            } label: {
                AgentWorkChipLabel(work: work)
                    .padding(.horizontal, glass ? 12 : 6)
                    .frame(height: glass ? 36 : 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(ChipSurface(glass: glass))
            .popover(isPresented: $showCard) {
                AgentWorkCard(store: store)
                    .presentationCompactAdaptation(.popover)
            }
            .accessibilityLabel(Self.accessibilityLabel(work))
            .accessibilityHint("Shows the steps and agents")
            .accessibilityIdentifier("agent-work-chip")
        }
    }

    static func accessibilityLabel(_ work: AgentWork.Work) -> String {
        if !work.steps.isEmpty {
            let done = work.steps.filter { $0.state == .done }.count
            return "\(done) of \(work.steps.count) steps done"
        }
        return AgentWork.agentsHeader(work).count + " " + AgentWork.agentsHeader(work).word
    }
}

private struct ChipSurface: ViewModifier {
    let glass: Bool

    func body(content: Content) -> some View {
        if glass {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
        }
    }
}

private struct AgentWorkChipLabel: View {
    let work: AgentWork.Work

    var body: some View {
        Group {
            if let states = AgentWork.chipDots(work) {
                StepDots(states: states)
            } else if !work.steps.isEmpty {
                HStack(spacing: 5) {
                    if work.live { RingSpinner(diameter: 12, stroke: 1.5) } else { CheckDot(diameter: 12) }
                    Text("\(work.steps.filter { $0.state == .done }.count)/\(work.steps.count)")
                        .monospacedDigit()
                }
            } else {
                HStack(spacing: 5) {
                    if work.runningAgents > 0 { RingSpinner(diameter: 12, stroke: 1.5) } else { CheckDot(diameter: 12) }
                    Text(AgentWork.agentsHeader(work).count).monospacedDigit()
                }
            }
        }
        .font(Theme.sans(12))
        .foregroundStyle(Theme.textMuted)
    }
}

/// Step dots joined by links: accent after a done step, dashed gray from the active one on.
private struct StepDots: View {
    let states: [AgentWork.StepState]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(states.enumerated()), id: \.offset) { index, state in
                if index > 0 {
                    let accent = states[index - 1] == .done
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 6))
                        path.addLine(to: CGPoint(x: 6, y: 6))
                    }
                    .stroke(accent ? Theme.accent : AgentWorkPalette.line,
                            style: StrokeStyle(lineWidth: 1.5, dash: accent ? [] : [3, 3]))
                    .frame(width: 6, height: 12)
                }
                StepGlyph(state: state, diameter: 12)
            }
        }
    }
}

enum AgentWorkPalette {
    static var line: Color { Theme.textFaint.opacity(0.45) }
    /// A step waiting on the person (the desktop's blue, both appearances).
    static var blue: Color { Color(red: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255) }
    static var blueText: Color {
        ThemeStore.shared.palette.isDark ? Color(red: 0x60 / 255, green: 0xA5 / 255, blue: 0xFA / 255)
            : Color(red: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255)
    }
}

/// A step's state: an accent check when done, an accent spinner round an accent dot while active, a hollow
/// ring while pending, a blue lock when it waits on the person.
struct StepGlyph: View {
    let state: AgentWork.StepState
    let diameter: CGFloat

    var body: some View {
        switch state {
        case .done:
            CheckDot(diameter: diameter)
        case .active:
            ZStack {
                RingSpinner(diameter: diameter, stroke: 2)
                Circle().fill(Theme.accent).frame(width: diameter * 0.34, height: diameter * 0.34)
            }
        case .pending:
            Circle().strokeBorder(AgentWorkPalette.line, lineWidth: 1.5).frame(width: diameter, height: diameter)
        case .asksFirst:
            Circle().strokeBorder(AgentWorkPalette.blue, lineWidth: 1.5)
                .frame(width: diameter, height: diameter)
                .overlay {
                    Image(systemName: "lock.fill")
                        .font(.system(size: diameter * 0.42, weight: .semibold))
                        .foregroundStyle(AgentWorkPalette.blue)
                }
        }
    }
}

struct CheckDot: View {
    let diameter: CGFloat

    var body: some View {
        Circle().fill(Theme.accent)
            .frame(width: diameter, height: diameter)
            .overlay {
                Image(systemName: "checkmark")
                    .font(.system(size: diameter * 0.5, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
            }
    }
}

/// An accent arc turning once a second over a faint track; still under reduced motion.
struct RingSpinner: View {
    let diameter: CGFloat
    let stroke: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(AgentWorkPalette.line, lineWidth: stroke)
            Circle().trim(from: 0, to: 0.85)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
        }
        .padding(stroke / 2)
        .frame(width: diameter, height: diameter)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { turning = true }
        }
    }
}

/// The card: the timeline, the agents and the tools, whichever exist.
struct AgentWorkCard: View {
    let store: SessionStore

    var body: some View {
        let work = AgentWork.work(store.entries)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !work.steps.isEmpty { timeline(work.steps) }
                if !work.agents.isEmpty {
                    if !work.steps.isEmpty { Rectangle().fill(Theme.border).frame(height: 1) }
                    agents(work)
                }
                if !work.tools.isEmpty { tools(work.tools) }
                if work.isEmpty {
                    Text("Nothing running")
                        .font(Theme.sans(14))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .padding(16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 320)
        .frame(maxHeight: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.surfaceDialog)
        .accessibilityIdentifier("agent-work-card")
    }

    private func timeline(_ steps: [AgentWork.Step]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: 0) {
                    StepGlyph(state: step.state, diameter: 18).frame(width: 40, alignment: .leading)
                    Text(step.title)
                        .font(Theme.sans(14))
                        .foregroundStyle(titleColor(step.state))
                        .lineLimit(1)
                    Spacer(minLength: 10)
                    trail(step)
                }
                .frame(height: 34)
                ForEach(step.substeps) { sub in
                    HStack(spacing: 0) {
                        Group {
                            if sub.done {
                                Circle().fill(Theme.textFaint).frame(width: 5, height: 5)
                            } else {
                                RingSpinner(diameter: 10, stroke: 1.5)
                            }
                        }
                        .frame(width: 10)
                        .padding(.leading, 4)
                        .frame(width: 40, alignment: .leading)
                        Text(sub.title)
                            .font(Theme.sans(12))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                    .frame(height: 28)
                }
            }
        }
    }

    private func titleColor(_ state: AgentWork.StepState) -> Color {
        switch state {
        case .done: Theme.textMuted
        case .active, .asksFirst: Theme.text
        case .pending: Theme.textFaint
        }
    }

    @ViewBuilder
    private func trail(_ step: AgentWork.Step) -> some View {
        switch step.state {
        case .done:
            if let ms = step.durationMs {
                Text(AgentWork.durationLabel(ms: ms))
                    .font(Theme.sans(12)).foregroundStyle(Theme.textFaint).monospacedDigit()
            }
        case .active:
            if let status = step.status {
                Text(status).font(Theme.sans(12)).foregroundStyle(AgentWorkPalette.blueText)
            }
        case .asksFirst:
            Text("Asks first")
                .font(Theme.sans(12))
                .padding(.horizontal, 9).padding(.vertical, 2)
                .tintedChip(Theme.warning)
        case .pending:
            EmptyView()
        }
    }

    private func agents(_ work: AgentWork.Work) -> some View {
        let header = AgentWork.agentsHeader(work)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 5) {
                Text(header.count).foregroundStyle(Theme.text)
                Text(header.word).foregroundStyle(Theme.textMuted)
            }
            .font(Theme.sans(14))
            .monospacedDigit()
            ForEach(work.agents) { agent in
                HStack(alignment: .top, spacing: 12) {
                    Group {
                        switch agent.state {
                        case .running: RingSpinner(diameter: 18, stroke: 2)
                        case .done: CheckDot(diameter: 18)
                        case .failed, .stopped:
                            Circle().strokeBorder(Theme.textFaint, lineWidth: 1.5).frame(width: 18, height: 18)
                        }
                    }
                    .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.title).font(Theme.sans(14)).foregroundStyle(Theme.text)
                        Text(agent.detail).font(Theme.sans(12)).foregroundStyle(detailColor(agent.state))
                    }
                    .lineLimit(1)
                }
            }
        }
    }

    private func detailColor(_ state: AgentWork.AgentState) -> Color {
        switch state {
        case .done: Theme.accent
        case .failed: Theme.danger
        case .running, .stopped: Theme.textMuted
        }
    }

    private func tools(_ chips: [AgentWork.ToolChip]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chips, id: \.label) { chip in
                    Label(chip.label, systemImage: chip.symbol)
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.border))
                }
            }
        }
    }
}
