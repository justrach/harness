// A prompt owns its native selection range. Measurement-only SwiftUI Text
// copies remain noninteractive, and assistant output owns separate storage.
import SwiftUI
import UIKit

struct SelectablePromptText: View {
    let text: String
    let expanded: Bool
    @ScaledMetric(relativeTo: .body) private var fontSize = MD.textSize

    var body: some View {
        let paragraph = NSMutableParagraphStyle()
        // Match UserBubble's existing prose metrics, including its last line.
        paragraph.lineSpacing = MD.lineHeight - MD.textSize - 4
        let attributed = NSAttributedString(string: text, attributes: [
            .font: Theme.sansUI(fontSize), .paragraphStyle: paragraph,
            .foregroundColor: UIColor(Theme.text),
        ])
        return SelectableText(text: attributed, lineHeight: MD.lineHeight * fontSize / MD.textSize,
                       maximumNumberOfLines: expanded ? 0 : 5, fitsContentWidth: true,
                       copyAllText: text)
            .accessibilityIdentifier("sent-prompt-text")
    }
}
