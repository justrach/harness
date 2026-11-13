import SwiftUI

/// Touch-sized catalog rows; keyboard arrows and Tab use the same selection.
struct ComposerCommandMenu: View {
    let commands: [ComposerCommand]
    let selected: Int
    let loading: Bool
    let error: String?
    let retry: () -> Void
    let accept: (ComposerCommand) -> Void
    @State private var contentHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if loading {
                ProgressView("Loading commands…")
                    .font(Theme.sans(13))
                    .padding(12)
            } else if let error {
                Button(action: retry) {
                    Label(error + " Retry", systemImage: "arrow.clockwise")
                        .font(Theme.sans(13))
                        .padding(12)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer-command-retry")
            }
            if commands.isEmpty && !loading && error == nil {
                Text("No matching commands")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textMuted)
                    .padding(12)
            }
            if !commands.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                                Button { accept(command) } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Image(systemName: "command")
                                            .font(.system(size: 16))
                                            .foregroundStyle(Theme.textMuted)
                                            .frame(width: 16)
                                            .accessibilityHidden(true)
                                        Text("/" + command.name)
                                            .font(Theme.sans(15, weight: .medium))
                                            .lineLimit(nil)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if let description = command.description, !description.isEmpty {
                                            Text(description)
                                                .font(Theme.sans(13))
                                                .foregroundStyle(Theme.textMuted)
                                                .lineLimit(nil)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        } else {
                                            Spacer(minLength: 0)
                                        }
                                    }
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .background(index == selected ? Theme.elementHover : .clear,
                                                in: RoundedRectangle(cornerRadius: 7))
                                    .padding(.horizontal, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(command.workspaceCommand?.isDesktopOnly == true)
                                .opacity(command.workspaceCommand?.isDesktopOnly == true ? 0.55 : 1)
                                .id(command.id)
                                .accessibilityIdentifier("composer-command-" + command.name)
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    }
                    // The viewport follows the actual rows, including wrapped
                    // descriptions and Dynamic Type, until scrolling is needed.
                    .frame(height: min(contentHeight ?? CGFloat(commands.count) * 44, 224))
                    .onChange(of: selected) { _, index in
                        if commands.indices.contains(index) { proxy.scrollTo(commands[index].id) }
                    }
                }
            }
        }
        .foregroundStyle(Theme.text)
        .background(Theme.surfaceDialog, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hairline(0.05), lineWidth: 1))
        .padding(.horizontal, 16)
        .accessibilityIdentifier("composer-command-menu")
    }
}
