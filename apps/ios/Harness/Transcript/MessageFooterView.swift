import SwiftUI

/// Always visible on touch devices; desktop reveals the same strip on hover.
struct MessageFooterView: View {
    let timestamp: Int64
    let copyText: String?
    let entryID: String
    var trailing = false
    @State private var copied = false

    /// Desktop's absolute timestamp shape, in the reader's local time zone.
    static func timestampLabel(_ milliseconds: Int64, locale: Locale = .current,
                               timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(Self.timestampLabel(timestamp))
                .font(Theme.sans(12))
                .accessibilityIdentifier("message-timestamp-\(entryID)")
            if let copyText {
                Button {
                    UIPasteboard.general.string = copyText
                    copied = true
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Image(systemName: copied ? "checkmark" : "square.on.square")
                        .font(.system(size: 14))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied" : "Copy message")
                .accessibilityIdentifier("message-copy-\(entryID)")
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    copied = false
                }
            }
        }
        .foregroundStyle(Theme.textMuted)
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
        .accessibilityElement(children: .contain)
    }
}
