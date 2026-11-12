// iPhone Duo chat: the pieces the folded (and unfolded) session uses on a foldable.
//
// Tool groups read as one line of chips, edits get a diff summary card, and a running turn is one small
// glass pill above the composer (status and elapsed; Stop behind a tap or a press and hold, never next to
// Send). The type scale here is two sizes (15 and 13) plus mono, in two weights (regular and medium).
//
// Only on a device that has reported a fold or its inner display (`DuoChat.foldableKey`); every other
// iPhone keeps the chat exactly as it was.

import Observation
import SwiftUI
import UIKit

enum DuoChat {
    /// UserDefaults: this device has reported a fold or its inner display, so it is an iPhone Duo.
    static let foldableKey = "foldableDevice"
    /// UserDefaults: the session list stands beside an open session on the inner display lying flat.
    static let flatListKey = "duoFlatListShown"

    /// A window that only an iPhone Duo has: an active fold, or a phone window regular both ways (the inner
    /// display lying flat).
    static func isFoldableWindow(phone: Bool, regularWidth: Bool, regularHeight: Bool, fold: FoldSplit) -> Bool {
        fold != .none || (phone && regularWidth && regularHeight)
    }

    /// The inner display lying flat: a phone window regular both ways with no fold. The session splits at
    /// the window's middle (where the fold is), chat on the left and Inspect on the right.
    static func isFlat(phone: Bool, regularWidth: Bool, regularHeight: Bool, fold: FoldSplit) -> Bool {
        fold == .none && phone && regularWidth && regularHeight
    }

    /// Lying flat, the session list stands beside an open session only once the person asks for it (the
    /// session bar's sidebar button), and never beside Inspect, which takes its place. Beside a 296pt list the
    /// chat was left a cramped column of the 669pt display.
    static func listBesideSession(flat: Bool, listShown: Bool, sessionOpen: Bool, inspectOpen: Bool) -> Bool {
        flat && listShown && sessionOpen && !inspectOpen
    }

    /// Pure state step for the flat Duo's sidebar button (`duo-flat-toggle-list`).
    /// If Inspect is open, tapping the sidebar button closes Inspect and reveals the session list;
    /// otherwise it flips `shown` (`true -> false -> true`).
    static func toggledFlatList(shown: Bool, inspectOpen: Bool) -> (shown: Bool, inspectOpen: Bool) {
        if inspectOpen { return (true, false) }
        return (!shown, false)
    }

    /// Keep the flat Duo's sidebar NavigationStack mounted while a session is open (and Inspect is closed) so
    /// tapping the sidebar toggle slides an already-warm list instead of cold-mounting UIKit controllers on frame 0.
    static func prewarmsFlatSidebar(flat: Bool, sessionOpen: Bool, inspectOpen: Bool) -> Bool {
        flat && sessionOpen && !inspectOpen
    }

    /// Selecting another session from a visible split sidebar swaps the detail route in place without a 350ms
    /// UINavigationController push slide.
    static func replacesSessionWithoutPush(splitLayout: Bool, flatSidebar: Bool,
                                           currentIsChat: Bool, nextIsChat: Bool) -> Bool {
        (splitLayout || flatSidebar) && currentIsChat && nextIsChat
    }

    /// Room the session bar keeps before its title. Folded on the cover display the back button is in the
    /// side bar, so the title starts at the edge. Lying flat the session is pushed onto the list's stack: its
    /// bar has the back button and the list's toggle, which the folded inset let the title slide under.
    static func headerInset(duoChat: Bool, compactWidth: Bool, flat: Bool, listToggle: Bool,
                            chrome: CGFloat, hitTarget: CGFloat) -> CGFloat {
        if flat { return chrome + (listToggle ? hitTarget + 8 : 0) }
        return duoChat && compactWidth ? 32 : chrome
    }

    /// Rig (DEBUG): `-demo-duo-flat` lays home and a session out as on a Duo lying flat (one stack, the list
    /// beside a session when asked for, chat and Inspect) on any wide simulator. The Duo simulator has no
    /// command to unfold, so its inner display can't be captured from a script.
    #if DEBUG
    static let demoFlat = ProcessInfo.processInfo.arguments.contains("-demo-duo-flat")
    #else
    static let demoFlat = false
    #endif
}

// MARK: - Cover display

/// The transcript beside a vertical bar. On the Duo's cover display (466 x 678 pt) the system puts the status
/// bar, the camera and the navigation bar (with the back button) in one column on the trailing side: an 84pt
/// safe-area inset, the system's, which content must stay out of (HIG, "Vertical controls"). Rows used to pad
/// 20pt on both sides inside what was left, so the text had 342pt of the 466. Beside the bar the column's own
/// empty edge already separates the text from the controls: the rows keep a smaller gap there, and the scroll
/// indicator moves into a gutter at the column's edge, short of the bar's controls, instead of over the text.
enum CoverLayout {
    /// Row padding on each side everywhere else.
    static let standardPadding: CGFloat = 20
    /// Row padding on the side away from the bar.
    static let openSidePadding: CGFloat = 16
    /// Text to the safe-area edge on the bar's side.
    static let barSideGap: CGFloat = 8
    /// How far the transcript reaches into the bar's inset, for its scroll indicator. The cover display's bar
    /// controls start 17pt into the column (back button at x 399, column at 382).
    static let gutter: CGFloat = 12
    /// An inset at least this wide on the bar's side is a bar column (status bar and controls).
    static let minimumBarInset: CGFloat = 44

    struct RowInsets: Hashable {
        /// Row padding, measured from the transcript's (possibly extended) edges.
        var leading: CGFloat
        var trailing: CGFloat
        /// How far the transcript extends past the safe area on each side.
        var bleedLeading: CGFloat = 0
        var bleedTrailing: CGFloat = 0

        static let standard = RowInsets(leading: CoverLayout.standardPadding, trailing: CoverLayout.standardPadding)

        /// The text column's width in a safe area this wide.
        func textWidth(safeWidth: CGFloat) -> CGFloat {
            safeWidth + bleedLeading + bleedTrailing - leading - trailing
        }
    }

    /// Which side a vertical bar stands on. The iOS 27.1 SDK reports it (`toolbarVerticalEdge`); builds on older
    /// SDKs read it from the insets: a Duo at compact width with a bar-wide inset on one side only.
    static func barEdge(reported: HorizontalEdge?, duo: Bool, compactWidth: Bool,
                        leadingInset: CGFloat, trailingInset: CGFloat) -> HorizontalEdge? {
        if let reported { return reported }
        guard duo, compactWidth else { return nil }
        if trailingInset >= minimumBarInset, leadingInset < 1 { return .trailing }
        if leadingInset >= minimumBarInset, trailingInset < 1 { return .leading }
        return nil
    }

    /// Row insets beside a vertical bar on `barEdge` whose safe-area inset is `barInset` wide; the standard
    /// 20pt either side when there is no bar column.
    static func rowInsets(barEdge: HorizontalEdge?, barInset: CGFloat) -> RowInsets {
        guard let barEdge, barInset >= minimumBarInset else { return .standard }
        let bleed = min(gutter, barInset / 4)
        switch barEdge {
        case .trailing:
            return RowInsets(leading: openSidePadding, trailing: bleed + barSideGap, bleedTrailing: bleed)
        case .leading:
            return RowInsets(leading: bleed + barSideGap, trailing: openSidePadding, bleedLeading: bleed)
        }
    }
}

extension EnvironmentValues {
    /// The session is on an iPhone Duo: chips, diff card and the status pill (DuoChat).
    @Entry var duoChat: Bool = false
    /// Flat Duo: show or hide the session list beside the open session (HomeView's `flatListShown`).
    @Entry var toggleFlatList: (() -> Void)? = nil
}

/// Observable reference state for the flat Duo's session list (`duo-flat-toggle-list`).
/// Seeds initial visibility from `UserDefaults` once and mutates `shown` in memory on every tap so neither
/// `NSArgumentDomain` launch arguments (`-duoFlatListShown YES`) nor cached `UINavigationBar` button closures
/// can prevent repeated `open <-> closed <-> open` toggling.
@MainActor
@Observable
final class FlatSidebarState {
    var shown: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.shown = defaults.bool(forKey: DuoChat.flatListKey)
    }

    @discardableResult
    func toggle(inspectOpen: Bool = false) -> (shown: Bool, inspectOpen: Bool) {
        let next = DuoChat.toggledFlatList(shown: shown, inspectOpen: inspectOpen)
        shown = next.shown
        defaults.set(next.shown, forKey: DuoChat.flatListKey)
        return next
    }
}

/// UIKit clipping container that keeps the flat Duo's 296pt `NavigationStack` warm in memory at constant width
/// while guaranteeing `hitTest` and `point(inside:)` return `nil`/`false` whenever `shown == false`.
final class FlatSidebarClipView: UIView {
    var shown: Bool = false {
        didSet {
            isUserInteractionEnabled = shown
            borderView.isHidden = !shown
            setNeedsLayout()
        }
    }
    var sidebarWidth: CGFloat = 296 {
        didSet {
            if oldValue != sidebarWidth { setNeedsLayout() }
        }
    }
    weak var hostedView: UIView?
    private let borderView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .clear
        isUserInteractionEnabled = false
        borderView.backgroundColor = UIColor(Theme.border)
        borderView.isHidden = true
        borderView.isUserInteractionEnabled = false
        addSubview(borderView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard shown, bounds.width > 1 else { return false }
        return bounds.contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard shown, bounds.width > 1 else { return nil }
        return super.hitTest(point, with: event)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let fullWidth = sidebarWidth + 1
        let leadX = bounds.width - fullWidth
        hostedView?.frame = CGRect(x: leadX, y: 0, width: sidebarWidth, height: bounds.height)
        borderView.frame = CGRect(x: leadX + sidebarWidth, y: 0, width: 1, height: bounds.height)
    }
}

private final class FlatSidebarViewController<Content: View>: UIViewController {
    let clipView = FlatSidebarClipView()
    let hosting: UIHostingController<Content>

    init(rootView: Content, shown: Bool, width: CGFloat) {
        self.hosting = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
        clipView.sidebarWidth = width
        clipView.shown = shown
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = clipView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(hosting)
        hosting.view.backgroundColor = .clear
        clipView.insertSubview(hosting.view, at: 0)
        clipView.hostedView = hosting.view
        hosting.didMove(toParent: self)
    }
}

private struct FlatSidebarHost<Content: View>: UIViewControllerRepresentable {
    let shown: Bool
    let width: CGFloat
    let content: Content

    func makeUIViewController(context: Context) -> FlatSidebarViewController<Content> {
        FlatSidebarViewController(rootView: content, shown: shown, width: width)
    }

    func updateUIViewController(_ controller: FlatSidebarViewController<Content>, context: Context) {
        controller.hosting.rootView = content
        controller.clipView.sidebarWidth = width
        controller.clipView.shown = shown
    }
}

/// Keeps the flat Duo's 296pt sidebar warm in memory while a session is open, revealing it by sliding a
/// fixed-width column inside a UIKit-clipped container instead of cold-instantiating NavigationStack + List on tap.
struct PrewarmedFlatSidebar<Content: View>: View {
    let shown: Bool
    let width: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        FlatSidebarHost(shown: shown, width: width, content: content().accessibilityIdentifier("wide-sidebar"))
            .frame(width: shown ? width + 1 : 0)
            .layoutPriority(1)
            .ignoresSafeArea(edges: .vertical)
            .accessibilityHidden(!shown)
    }
}

/// The folded chat's type scale: two sizes plus mono, two weights.
enum DuoType {
    static let body: CGFloat = 15
    static let small: CGFloat = 13
    static func sans(small: Bool = false, medium: Bool = false) -> Font {
        Theme.sans(small ? Self.small : body, weight: medium ? .medium : .regular)
    }
    static var mono: Font { Theme.mono(small) }
}

// MARK: - Tool chips

/// One tool group as a line of chips: what ran, by kind, and what failed.
enum ToolChips {
    struct Chip: Equatable, Identifiable {
        var id: String { symbol }
        let symbol: String
        let count: Int
        let label: String
        var failed = false
    }

    static func chips(_ tools: [ToolItem]) -> [Chip] {
        func count(_ tags: Set<String>) -> Int { tools.filter { tags.contains($0.call.tag) }.count }
        let runs = count(["exec"])
        let edits = count(["editFile", "writeFile", "applyPatch"])
        let reads = count(["readFile"])
        let searches = count(["search", "glob", "webSearch", "webFetch"])
        let thoughts = count([RenderToolCall.thoughtTag])
        let other = tools.count - runs - edits - reads - searches - thoughts
        let failed = tools.filter(\.isError).count
        var chips: [Chip] = []
        if thoughts > 0 {
            chips.append(Chip(symbol: "text.bubble", count: thoughts,
                              label: thoughts == 1 ? "Thought" : "\(thoughts) thoughts"))
        }
        if runs > 0 { chips.append(Chip(symbol: "terminal", count: runs, label: runs == 1 ? "1 run" : "\(runs) runs")) }
        if edits > 0 { chips.append(Chip(symbol: "pencil", count: edits, label: edits == 1 ? "1 edit" : "\(edits) edits")) }
        if reads > 0 { chips.append(Chip(symbol: "doc.text", count: reads, label: reads == 1 ? "1 read" : "\(reads) reads")) }
        if searches > 0 {
            chips.append(Chip(symbol: "magnifyingglass", count: searches,
                              label: searches == 1 ? "1 search" : "\(searches) searches"))
        }
        if other > 0 { chips.append(Chip(symbol: "square.grid.2x2", count: other, label: other == 1 ? "1 tool" : "\(other) tools")) }
        if failed > 0 {
            chips.append(Chip(symbol: "exclamationmark.triangle", count: failed, label: "\(failed) failed", failed: true))
        }
        return chips
    }
}

/// The tool group's header on a Duo: the disclosure chevron and one line of chips. Short of room, the chips
/// drop their words and keep the symbol and count, so the line never wraps.
struct ToolChipStrip: View {
    let tools: [ToolItem]
    let open: Bool

    var body: some View {
        let chips = ToolChips.chips(tools)
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: 26)
            ViewThatFits(in: .horizontal) {
                row(chips, words: true)
                row(chips, words: false)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.textMuted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(toolGroupSummary(tools))
    }

    private func row(_ chips: [ToolChips.Chip], words: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(chips) { chip in
                HStack(spacing: 4) {
                    Image(systemName: chip.symbol).font(.system(size: 11, weight: .medium))
                    Text(words ? chip.label : "\(chip.count)")
                        .font(DuoType.sans(small: true))
                        .monospacedDigit()
                }
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 24)
                .foregroundStyle(chip.failed ? Theme.danger : Theme.textMuted)
                .background(chip.failed ? Theme.danger.opacity(0.12) : Theme.text.opacity(0.06), in: Capsule())
            }
        }
    }
}

// MARK: - Diff summary

/// What a tool group changed: the files it edited and, when the host sent them, the line counts.
/// The session doc keeps only each edit's path (the render-parts policy strips old and new text), so live
/// groups show the files alone; `additions` and `deletions` fields fill in the counts when present.
struct DiffSummary: Equatable {
    var files: [String]
    var additions: Int?
    var deletions: Int?

    static let editTags: Set<String> = ["editFile", "writeFile", "applyPatch"]

    static func from(_ tools: [ToolItem]) -> DiffSummary? {
        var files: [String] = []
        var additions: Int?
        var deletions: Int?
        for tool in tools where editTags.contains(tool.call.tag) && !tool.isError {
            if let path = tool.call.string("path"), !path.isEmpty, !files.contains(path) { files.append(path) }
            if let added = int(tool.call.fields["additions"]) { additions = (additions ?? 0) + added }
            if let removed = int(tool.call.fields["deletions"]) { deletions = (deletions ?? 0) + removed }
        }
        guard !files.isEmpty else { return nil }
        return DiffSummary(files: files, additions: additions, deletions: deletions)
    }

    private static func int(_ value: AnyHashable?) -> Int? {
        if let value = value as? Int64 { return Int(value) }
        return value as? Int
    }

    var title: String { files.count == 1 ? "1 file changed" : "\(files.count) files changed" }

    /// The files by name, for the card's second line.
    var names: String {
        files.map { $0.split(separator: "/").last.map(String.init) ?? $0 }.joined(separator: ", ")
    }
}

extension EnvironmentValues {
    /// Open a tool group's changes in the Inspect pane; nil where there is no pane.
    @Entry var inspectDiff: ((DiffSummary) -> Void)? = nil
}

/// "+N -M, K files" under a tool group that edited files.
struct DiffSummaryCard: View {
    let summary: DiffSummary
    var onTap: (() -> Void)?

    var body: some View {
        Button { onTap?() } label: {
            HStack(spacing: 10) {
                Image(systemName: "plusminus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title)
                        .font(DuoType.sans(medium: true))
                        .foregroundStyle(Theme.text)
                    Text(summary.names)
                        .font(DuoType.sans(small: true))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let additions = summary.additions {
                    Text("+\(additions)").font(DuoType.mono).foregroundStyle(Theme.statusCompleted)
                }
                if let deletions = summary.deletions {
                    Text("-\(deletions)").font(DuoType.mono).foregroundStyle(Theme.danger)
                }
                if onTap != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(Theme.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("diff-summary-card")
    }
}

// MARK: - Status pill

/// A running turn on a Duo: one small glass pill above the composer, in place of the status strip. Tap it
/// for Stop; press and hold it to stop at once. Stop never sits next to Send.
struct RunStatusPill: View {
    let chatId: String
    let startedAtMs: Int64
    let onStop: () -> Void
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let elapsed = max(0, (nowMs() - startedAtMs) / 1000)
            HStack(spacing: 8) {
                WorkingSpinner()
                Text("\(Motion.flavourWord(seed: Motion.flavourSeed(chatId), elapsedSecs: elapsed))…")
                    .font(DuoType.sans(small: true))
                    .foregroundStyle(Theme.textMuted)
                Text(Motion.formatElapsed(elapsed))
                    .font(DuoType.mono)
                    .foregroundStyle(Theme.textFaint)
                    .monospacedDigit()
                if expanded {
                    Rectangle().fill(Theme.border).frame(width: 0.5, height: 16)
                    Button {
                        stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(DuoType.sans(small: true, medium: true))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("pill-stop")
                    .transition(.opacity)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .glassEffect(.regular.interactive(), in: Capsule())
            .contentShape(Capsule())
        }
        .fixedSize()
        .onTapGesture { withAnimation(reduceMotion ? nil : Motion.resize) { expanded.toggle() } }
        .onLongPressGesture(minimumDuration: 0.6) { stop() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Working")
        .accessibilityHint("Tap for Stop, or press and hold to stop")
        .accessibilityAction(named: "Stop") { stop() }
        .accessibilityIdentifier("run-status-pill")
    }

    private func stop() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onStop()
        withAnimation(reduceMotion ? nil : Motion.resize) { expanded = false }
    }
}

// MARK: - Edge swipe

/// Swipe in from the leading edge to go back. The session's pager owns horizontal swipes elsewhere.
struct EdgeSwipeBack: View {
    let back: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 18)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .global)
                    .onEnded { value in
                        if value.translation.width > 70, abs(value.translation.height) < 80 { back() }
                    }
            )
            .accessibilityHidden(true)
    }
}
