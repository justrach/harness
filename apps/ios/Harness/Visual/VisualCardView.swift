import SwiftUI

struct VisualCardView: View {
    static let cardHeight: CGFloat = 470

    let partKey: String
    let title: String
    let script: String
    let cache: VisualCache

    private struct LoadKey: Equatable {
        var partKey: String
        var title: String
        var script: String
    }

    private var entry: VisualEntry? {
        cache.entry(for: partKey)
    }

    private var displayTitle: String {
        if let entry { return entry.title }
        let clean = VisualText.sanitizePlain(title, maxChars: VisualLimits.maxTitleChars)
        return clean.isEmpty ? "Native visual" : clean
    }

    private var statusText: String {
        guard let entry else { return "Preparing…" }
        if entry.busy { return "Updating…" }
        if case .failed = entry.state { return "Stopped" }
        return "Native · Interactive"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            ScrollView(.vertical) {
                bodyContent
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            divider
            footer
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.cardHeight)
        .background(Theme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native-visual-card")
        .task(id: LoadKey(partKey: partKey, title: title, script: script)) {
            cache.ensureLoaded(partKey: partKey, title: title, script: script)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(displayTitle)
                .font(Theme.sans(13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(statusText)
                .font(Theme.sans(11))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        Text("Isolated Luau · No network or filesystem")
            .font(Theme.sans(11))
            .foregroundStyle(Theme.textMuted)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(height: 1)
    }

    @ViewBuilder
    private var bodyContent: some View {
        if let entry {
            switch entry.state {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(Theme.textMuted)
                    Text("Preparing native visual…")
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.textMuted)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text("This visual could not run")
                        .font(Theme.sans(13, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                    Text(message)
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            case .ready(let root):
                VisualNodeView(
                    node: root,
                    depth: 1,
                    busy: entry.busy,
                    onDispatch: { handlerId, input in
                        cache.dispatch(partKey: partKey,
                                       revision: entry.revision,
                                       handlerId: handlerId,
                                       input: input)
                    }
                )
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(Theme.textMuted)
                Text("Preparing native visual…")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }
}

private struct VisualNodeView: View {
    let node: VisualNode
    let depth: Int
    let busy: Bool
    var inRow: Bool = false
    let onDispatch: (UInt64, VisualInput) -> Void

    var body: some View {
        if depth > VisualLimits.maxRenderDepth {
            Text("Visual display limit reached")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.danger)
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch node {
        case .column(let children):
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(children.prefix(VisualLimits.maxRenderNodes).enumerated()), id: \.offset) { _, child in
                    VisualNodeView(node: child, depth: depth + 1, busy: busy, inRow: false, onDispatch: onDispatch)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .row(let children):
            HStack(alignment: .center, spacing: 8) {
                ForEach(Array(children.prefix(VisualLimits.maxRenderNodes).enumerated()), id: \.offset) { _, child in
                    VisualNodeView(node: child, depth: depth + 1, busy: busy, inRow: true, onDispatch: onDispatch)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .text(let text):
            Text(text)
                .font(Theme.sans(13))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: inRow ? nil : .infinity, alignment: .leading)

        case .stat(let text):
            let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            VStack(alignment: .leading, spacing: 3) {
                if parts.count == 2 {
                    Text(String(parts[0]).trimmingCharacters(in: .whitespaces))
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                    Text(String(parts[1]).trimmingCharacters(in: .whitespaces))
                        .font(Theme.sans(16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                } else {
                    Text(text)
                        .font(Theme.sans(16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(11)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.border, lineWidth: 1)
            )

        case .rule:
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)

        case .chart(let label, let values, let labels):
            VisualChartView(label: label, values: values, labels: labels)

        case .button(let label, let handlerId):
            let active = !busy && handlerId != nil
            let title = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Run" : label
            Button {
                if let handlerId {
                    onDispatch(handlerId, .click)
                }
            } label: {
                Text(title)
                    .font(Theme.sans(13, weight: .medium))
                    .foregroundStyle(active ? Theme.onAccent : Theme.textMuted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(minHeight: 38)
                    .background(Theme.accentStrong, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.borderStrong, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!active)

        case .toggle(let label, let value, let handlerId):
            let active = !busy && handlerId != nil
            let title = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Toggle" : label
            Button {
                if let handlerId {
                    onDispatch(handlerId, .boolean(!value))
                }
            } label: {
                HStack(spacing: 10) {
                    ZStack(alignment: value ? .trailing : .leading) {
                        Capsule()
                            .fill(value ? Theme.accentStrong : Theme.borderStrong)
                            .frame(width: 30, height: 18)
                        Circle()
                            .fill(Theme.surfaceRaised)
                            .frame(width: 12, height: 12)
                            .padding(.horizontal, 3)
                    }
                    Text(title)
                        .font(Theme.sans(13, weight: .medium))
                        .foregroundStyle(active ? Theme.text : Theme.textMuted)
                    Text(value ? "On" : "Off")
                        .font(Theme.sans(13, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: 38)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.borderStrong, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(!active)

        case .slider(let label, let value, let minVal, let maxVal, let handlerId):
            VisualSliderView(
                label: label,
                value: value,
                minVal: minVal,
                maxVal: maxVal,
                active: !busy && handlerId != nil && minVal < maxVal,
                onChange: { nextValue in
                    if let handlerId {
                        onDispatch(handlerId, .number(nextValue))
                    }
                }
            )
        }
    }
}

private struct VisualChartView: View {
    let label: String
    let values: [Double]
    let labels: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label.isEmpty ? "Chart" : label)
                .font(Theme.sans(13, weight: .semibold))
                .foregroundStyle(Theme.text)

            if values.isEmpty {
                Text("No data yet")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textMuted)
            } else {
                let scale = max(values.map { abs($0) }.max() ?? 0, Double.leastNonzeroMagnitude)
                let norms = values.map { $0 / scale }
                let lo = min(0.0, norms.min() ?? 0.0)
                let hi = max(0.0, norms.max() ?? 0.0)
                let range = max(hi - lo, Double.leastNonzeroMagnitude)
                let zero = CGFloat(-lo / range)
                let shown = min(values.count, VisualLimits.maxChartBars)

                ForEach(0..<shown, id: \.self) { idx in
                    let val = values[idx]
                    let rowLabel = idx < labels.count && !labels[idx].isEmpty ? labels[idx] : "\(idx + 1)"
                    HStack(spacing: 10) {
                        Text(rowLabel)
                            .font(Theme.sans(12))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                            .frame(width: 72, alignment: .leading)

                        GeometryReader { geo in
                            let bw = max(1, geo.size.width)
                            let endF = CGFloat(((val / scale) - lo) / range)
                            let barLeft = min(zero, endF) * bw
                            let barWidth = max(0, abs(endF - zero) * bw)

                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Theme.surface)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Theme.accent)
                                    .frame(width: barWidth)
                                    .offset(x: barLeft)
                                Rectangle()
                                    .fill(Theme.textFaint)
                                    .frame(width: 1)
                                    .offset(x: zero * bw)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        .frame(height: 18)

                        Text(VisualText.formatNumber(val))
                            .font(Theme.sans(12))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .frame(width: 56, alignment: .trailing)
                    }
                    .frame(minHeight: 22)
                }

                if values.count > VisualLimits.maxChartBars {
                    Text("Showing the first \(VisualLimits.maxChartBars) of \(values.count) values")
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

private struct VisualSliderView: View {
    let label: String
    let value: Double
    let minVal: Double
    let maxVal: Double
    let active: Bool
    let onChange: (Double) -> Void

    @State private var draftValue: Double?

    private var shownValue: Double {
        min(max(draftValue ?? value, minVal), maxVal)
    }

    var body: some View {
        let title = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Slider" : label
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                Text(VisualText.formatNumber(shownValue))
                    .font(Theme.sans(13, weight: .medium))
                    .foregroundStyle(Theme.text)
            }

            if minVal < maxVal {
                Slider(
                    value: Binding(
                        get: { shownValue },
                        set: { next in
                            draftValue = next
                            onChange(next)
                        }
                    ),
                    in: minVal...maxVal
                )
                .tint(Theme.accent)
                .disabled(!active)
                .onChange(of: value) { _, newValue in
                    draftValue = newValue
                }
            }

            HStack {
                Text(VisualText.formatNumber(minVal))
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Text(VisualText.formatNumber(maxVal))
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}
