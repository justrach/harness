// Session screen — transcript + status strip + composer (or question panel
// while input is requested, replacing the composer like the desktop). Reading
// marks the chat seen (the synced LWW marker behind the green dot everywhere).

import SwiftUI
import UniformTypeIdentifiers

struct SessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.pageSession) private var pageSession
    /// Open another session beside this one, or close this pane: set only on a Max-class iPhone (SplitScreen).
    @Environment(\.splitScreen) private var splitScreen
    /// Open a new session below this one, in the phone's stacked split (⌘D on the desktop).
    @Environment(\.stackedSplit) private var stackedSplit
    /// Close this pane of the stacked split, while two are shown.
    @Environment(\.stackedClose) private var stackedClose
    /// Above the fold in laptop pose: draw the header strip here, with a back button (FoldPaneHeader).
    @Environment(\.foldPaneHeader) private var foldPaneHeader
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// iPhone Duo lying flat: chat left of the fold, Inspect right (DuoInspect).
    @Environment(\.duoFlat) private var duoFlat
    @Environment(\.foldComposerFocus) private var foldComposerFocus
    /// iPhone Duo half open like a laptop: watch above the fold, act below it (DuoLaptop).
    @Environment(\.duoLaptop) private var duoLaptop
    /// Laptop pose: how far the keyboard reaches into this view, and the header strip's height.
    @State private var keyboardOverlap: CGFloat = 0
    @State private var paneHeaderHeight: CGFloat = 0
    /// Flat Duo: the composer has the keyboard, so Inspect folds to its one-line peek.
    @State private var keyboardUp = false
    /// Flat Duo: where the chat column starts and where the window's middle (the fold) is, in global space.
    @State private var columnMinX: CGFloat = 0
    @State private var windowMidX: CGFloat = 0
    /// This device is an iPhone Duo (DuoChat): chips, diff card, status pill, two-line title.
    @AppStorage(DuoChat.foldableKey) private var duoChat = false
    let chatId: String

    /// Reserve the back button and native bar margins. Anchor the rest to the
    /// trailing edge so the title can use the space before the controls.
    private static let headerChromeInset: CGFloat = 100
    private static let topFadeHeight: CGFloat = 28

    /// Room the stacked split's trailing buttons take from the title: the titled Split button (about 90pt),
    /// or the × (36pt), each plus the bar's 16pt gap before it. The header is a trailing item too, so any
    /// shortfall pushes the button into the bar's "More" menu instead of narrowing the title.
    private var stackedButtonsWidth: CGFloat {
        if stackedSplit != nil { return 112 }
        return stackedClose == nil ? 0 : 56
    }

    /// The view's own width, the only reliable basis for capping the principal
    /// toolbar item (its container proposes an unbounded width).
    @State private var viewWidth: CGFloat = 0
    @State private var headerWidth: CGFloat = 0

    /// Follow intent belongs to the session, independent of composer focus.
    @State private var scroll = ScrollState()
    @State private var attachmentDraft = AttachmentDraft()
    /// When the question panel last gave way to the composer (`StopGuard`).
    @State private var questionClosedAtMs: Int64?
    @State private var hostLink: HostLink?
    @State private var renamingSession = false
    @State private var renameChatId: String?
    @State private var renameTitle = ""


    /// On a Max (split screen available) every session draws its own compact header strip and the navigation
    /// bar is hidden. The bar's fixed-width header kept being evicted into the "…" menu in the narrow columns a
    /// Max uses (a session beside the list, or two panes of about 478pt), and on a landscape Max the bar is also
    /// a lot of lost height. Everywhere else the bar and its header are exactly as before.
    /// iPhone Duo in laptop pose draws the strip too: the bar shares its row with the status bar there and
    /// clipped the title under the back arrow.
    private var paneChrome: Bool { splitScreen != nil || foldPaneHeader != nil }

    /// Rename and paging are sibling controls: tapping an arrow must never rename.
    private func headerTitle(_ chat: Chat) -> some View {
        let _ = model.connectivity.pulse
        let entries = SessionPaging.entries(model: model, including: chat.id)
        let represented = pageSession == nil ? entries : SessionPaging.pageSet(of: chat.id, in: entries)
        let chats = represented.compactMap { model.chat(id: $0.id) }
        let available = headerWidth > 0 ? headerWidth : viewWidth - headerInset
        let limit = SessionStatusWindow.visibleLimit(availableWidth: available, total: chats.count,
                                                   hasPager: pageSession != nil && chats.count > 1)
        return headerControls(chat, chats: chats, maxVisible: limit)
    }

    private var headerInset: CGFloat {
        duoChat && horizontalSizeClass == .compact ? 32 : Self.headerChromeInset
    }

    /// A Duo shows a running turn as the pill above the composer, so the header's status dots step aside.
    private func pillShows(_ chat: Chat) -> Bool {
        duoChat && liveStatus(chat: chat) == .working && model.sendState(for: chat) == nil
            && model.connectivity.state == .connected
    }

    private func headerControls(_ chat: Chat, chats: [Chat], maxVisible: Int) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 3) {
                Button {
                    renameChatId = chat.id
                    renameTitle = chat.displayTitle
                    renamingSession = true
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(chat.displayTitle)
                            .font(Theme.sans(15, weight: .medium))
                            .foregroundStyle(Theme.text)
                            // A Duo wraps a long title to a second line instead of cutting it.
                            .lineLimit(duoChat ? 2 : 1)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: duoChat)
                        projectLocation(chat: chat, model: model)
                            .font(Theme.sans(duoChat ? DuoType.small : 12))
                            .foregroundStyle(Theme.textMuted.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Rename session")
                .accessibilityIdentifier("session-header")

                pagerControls(for: chat)
            }
            .pagerSwipe()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("session-navigation-controls")
            if !pillShows(chat) {
                SessionStatusIndicators(current: chat.id, chats: chats, maxVisible: maxVisible)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { headerWidth = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-header-controls")
    }

    /// A pane's header strip: the list toggle (one pane), title and project, and the split or close button.
    /// Swipe it to page to a neighbouring session.
    private func paneHeader(_ chat: Chat, controls: SplitScreenControls) -> some View {
        HStack(spacing: 8) {
            if foldPaneHeader != nil {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: Theme.hitTarget, height: Theme.hitTarget)
                        .contentShape(Rectangle())
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .accessibilityIdentifier("fold-back")
            }
            if let showList = foldPaneHeader?.showList {
                Button(action: showList) {
                    Image(systemName: "list.bullet")
                        .frame(width: Theme.hitTarget, height: Theme.hitTarget)
                        .contentShape(Rectangle())
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .buttonStyle(.plain)
                .accessibilityLabel("Show the session list")
                .accessibilityIdentifier("fold-show-list")
            }
            if let toggleList = controls.toggleList {
                Button(action: toggleList) {
                    Image(systemName: "sidebar.leading")
                        .frame(width: Theme.hitTarget, height: Theme.hitTarget)
                        .contentShape(Rectangle())
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .buttonStyle(.plain)
                .accessibilityLabel("Show or hide the session list")
                .accessibilityIdentifier("split-toggle-list")
            }
            headerTitle(chat)
            Spacer(minLength: 8)
            splitButtons(controls)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)  // the 44pt buttons set the strip's height
        .background(Theme.bg)
    }

    @ViewBuilder
    private func splitButtons(_ controls: SplitScreenControls) -> some View {
        HStack(spacing: 6) {
            if let openBeside = controls.openBeside {
                Button(action: openBeside) {
                    Image(systemName: "rectangle.split.2x1")
                        .frame(width: Theme.hitTarget, height: Theme.hitTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Open another session beside this one")
                .accessibilityIdentifier("split-open-beside")
            }
            if let close = controls.close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .frame(width: Theme.hitTarget, height: Theme.hitTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close this pane")
                .accessibilityIdentifier("split-close-pane")
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Theme.textMuted)
        .buttonStyle(.plain)
        .labelStyle(.iconOnly)
    }

    private var chat: Chat? { model.chat(id: chatId) }

    private var chatSpace: Space? {
        guard let spaceId = chat?.spaceId else { return nil }
        return model.spaces.first { $0.id == spaceId }
    }

    var body: some View {
        Group {
            if let chat, let store = model.sessionStore(for: chat) {
                // Max: the header strip sits above everything the content draws (its top fade, rows scrolling
                // under it), so it is neither dimmed nor overlapped, and the content is clipped to its own
                // rectangle.
                VStack(spacing: 0) {
                    if paneChrome {
                        paneHeader(chat, controls: splitScreen ?? SplitScreenControls())
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeaderHeight = $0 }
                        Group {
                            if let duoLaptop, splitScreen == nil {
                                laptopContent(chat: chat, store: store, layout: duoLaptop)
                            } else {
                                content(chat: chat, store: store)
                            }
                        }
                        .clipped()
                    } else {
                        // Not clipped: the content's background and header cover reach under the status bar.
                        content(chat: chat, store: store)
                    }
                }
                // The clip above also cuts off the content's own background, which reaches under the side and
                // bottom safe areas; without this the system's backing showed there (white, or black in dark
                // mode). Painted outside the clip, to the screen edges.
                .background { if paneChrome { Theme.bg.ignoresSafeArea() } }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewWidth = $0 }
            } else {
                VStack(spacing: 12) {
                    HarnessPulse()
                    Text("Opening session…")
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.textFaint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
            }
        }
        .navigationTitle(chat?.displayTitle ?? "Session")  // feeds the back menu
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)  // the leading header owns the bar
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(paneChrome ? .hidden : .automatic, for: .navigationBar)  // a Max draws its own header
        .toolbar {
            if let chat {
                // Tap the session header to rename — model/effort changes
                // moved into the composer's picker chips.
                ToolbarItem(placement: .topBarTrailing) {
                    headerTitle(chat)
                        // Claim the remaining bar width, less the stacked split's
                        // trailing buttons: the title expands before the
                        // fixed-size navigation and status marks. The title and
                        // pager carry their own swipe (headerControls).
                        // A folded Duo's back button is in the side bar, so the title can start at the edge.
                        .frame(width: max(140, viewWidth - headerInset - stackedButtonsWidth),
                               alignment: .leading)
                }
                // Bare text on the bar, not a glass capsule.
                .sharedBackgroundVisibility(.hidden)
            }
            if let stackedSplit {
                ToolbarItem(placement: .topBarTrailing) {
                    // Titled: the icon alone read as a plain box. A Label in the bar drops its title, so the
                    // icon and the word are laid out here.
                    Button(action: stackedSplit) {
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.split.1x2")
                                .fontWeight(.semibold)
                            Text("Split")
                                .font(Theme.sans(15, weight: .semibold))
                        }
                        .padding(.horizontal, 4)
                        .fixedSize()
                    }
                    .accessibilityLabel("Open another session below this one")
                    .accessibilityIdentifier("stacked-split-open")
                }
            }
            if let stackedClose {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: stackedClose) {
                        Label("Close this pane", systemImage: "xmark")
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("stacked-pane-close")
                }
            }
        }
        .alert("Rename session", isPresented: $renamingSession) {
            TextField("Session name", text: $renameTitle)
                .accessibilityIdentifier("session-rename-title")
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let renameChatId {
                    model.rename(chatId: renameChatId, title: renameTitle)
                }
            }
            .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("This name is shared across your devices.")
        }
        .onAppear {
            model.attachSessionView(chatId: chatId)
            model.markSeen(chatId: chatId)
        }
        .onDisappear {
            model.markSeen(chatId: chatId)
            model.releaseSessionStore(chatId: chatId)
        }
    }


    /// Use the same page set and action as swiping, with explicit, separate hit targets.
    @ViewBuilder
    private func pagerControls(for chat: Chat) -> some View {
        let _ = model.connectivity.pulse
        if let pageSession,
           let place = SessionPaging.position(of: chat.id, in: SessionPaging.entries(model: model, including: chat.id)) {
            HStack(spacing: 0) {
                pageButton(.previous, enabled: place.index > 1, action: pageSession)
                Text("\(place.index)/\(place.count)")
                    .monospacedDigit()
                    .foregroundStyle(Theme.textFaint)
                    .accessibilityLabel("Session \(place.index) of \(place.count)")
                    .accessibilityIdentifier("session-page-position")
                pageButton(.next, enabled: place.index < place.count, action: pageSession)
            }
            .font(.system(size: 10, weight: .semibold))
            .fixedSize()
        }
    }

    private func pageButton(_ direction: PageDirection, enabled: Bool,
                            action: @escaping (PageDirection) -> Void) -> some View {
        let previous = direction == .previous
        return Button { action(direction) } label: {
            Image(systemName: previous ? "chevron.left" : "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 28, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(previous ? "Previous session" : "Next session")
        .accessibilityIdentifier(previous ? "session-page-previous" : "session-page-next")
    }

    /// Laptop pose: the upper half watches (terminal or diff, read-only), the lower half acts (the newest
    /// messages, the quick actions, the composer). Typing, the keyboard covers the lower half: the actions and
    /// the composer sit right above it, the transcript steps aside and the watch pane takes what is left.
    private func laptopContent(chat: Chat, store: SessionStore, layout: DuoLaptopLayout) -> some View {
        let status = liveStatus(chat: chat)
        let running = status == .working
        let typing = keyboardOverlap > 0
        let inspect = InspectState.of(chat.id)
        let inspectModel = InspectModel.build(store.entries,
            source: model.demo != nil ? DemoInspectSource() as InspectDetailSource : LiveInspectSource())
        let approval = store.openInputRequest.flatMap { QuickActions.approval($0.questions) }
        let lastPrompt = QuickActions.lastPrompt(store.entries)
        return VStack(spacing: 0) {
            LaptopWatchPane(model: inspectModel, state: inspect, running: running)
                // Ends on the fold; typing, it gives the composer the room the keyboard took.
                .frame(height: typing ? nil : max(120, layout.top - paneHeaderHeight))
                .frame(maxHeight: typing ? .infinity : nil)
            Color.clear.frame(height: typing ? 0 : layout.gap)
            if !typing {
                TranscriptView(store: store, chatId: chat.id, scroll: scroll, cwd: chat.cwd,
                               onHostLink: { hostLink = $0 }, chat: chat, runLive: running,
                               hostName: model.deviceName(store.hostDeviceId ?? chat.deviceId),
                               duoChat: duoChat)
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
            }
            QuickActionsRow(enabled: { action in
                QuickActions.enabled(action, running: running, approvable: approval != nil,
                                     hasPrompt: lastPrompt != nil)
            }, perform: { action in
                switch action {
                case .approve:
                    if let request = store.openInputRequest, let approval {
                        store.respondInput(requestId: request.requestId, answers: approval)
                    }
                case .retry: if let lastPrompt { store.sendRun(prompt: lastPrompt, chat: chat) }
                case .stop: store.sendInterrupt()
                case .runTests: store.sendRun(prompt: QuickActions.runTestsPrompt, chat: chat)
                }
            })
            Group {
                if let request = store.openInputRequest {
                    QuestionPanel(requestId: request.requestId, questions: request.questions) { requestId, answers in
                        store.respondInput(requestId: requestId, answers: answers)
                    }
                } else {
                    ComposerView(store: store, chat: chat, runLive: running,
                                 attachmentDraft: attachmentDraft,
                                 questionClosedAtMs: questionClosedAtMs)
                        .id(chat.id)
                }
            }
            .padding(.bottom, 8)
        }
        .padding(.bottom, keyboardOverlap)
        .modifier(KeyboardOverlap(overlap: $keyboardOverlap))
        .background(Theme.bg.ignoresSafeArea())
        .accessibilityIdentifier("laptop-session")
    }

    private func content(chat: Chat, store: SessionStore) -> some View {
        let status = liveStatus(chat: chat)
        // The composer owns real layout space. The transcript's viewport ends
        // above it, so keyboard and glass morphs cannot cover the last row.
        let flat = duoFlat && splitScreen == nil
        let inspect = InspectState.of(chat.id)
        let inspectModel = flat
            ? InspectModel.build(store.entries,
                                 source: model.demo != nil ? DemoInspectSource() as InspectDetailSource : LiveInspectSource())
            : InspectModel()
        // Flat Duo: two equal halves meet at the fold. The chat column keeps its place in the tree whether or
        // not Inspect shows, so the transcript (and its scroll) survives the keyboard and the fold.
        return HStack(spacing: 0) {
        VStack(spacing: 0) {
            if flat, keyboardUp {
                InspectPeek(model: inspectModel, state: inspect) {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                // Above the transcript, whose rows draw past its top edge.
                .zIndex(1)
            }
            TranscriptView(store: store, chatId: chat.id, scroll: scroll, cwd: chat.cwd,
                           onHostLink: { hostLink = $0 }, chat: chat, runLive: status == .working,
                           hostName: model.deviceName(store.hostDeviceId ?? chat.deviceId),
                           duoChat: duoChat,
                           inspectDiff: flat ? { summary in
                               inspect.segment = .diff
                               inspect.selectedFile = summary.files.first
                           } : nil,
                           inspectTool: flat ? { inspect.show($0) } : nil)
                .sheet(item: $hostLink) { link in
                    let host = store.hostDeviceId ?? chat.deviceId
                    HostLinkSheet(link: link, deviceId: host, deviceName: model.deviceName(host))
                }
                .overlay {
                    if store.entries.isEmpty, store.pendingSends.isEmpty,
                       chat.lastMessageAt != nil {
                        TranscriptSkeleton().background(Theme.bg)
                    }
                }
                .motionAnimation(Motion.fadeQuick, value: store.entries.isEmpty)
                .overlay(alignment: .bottomLeading) {
                    if pillShows(chat) {
                        RunStatusPill(chatId: chat.id, startedAtMs: sessionStartedAt(chat: chat),
                                      onStop: { store.sendInterrupt() })
                            .padding(.leading, 16)
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .motionAnimation(Motion.fadeQuick, value: pillShows(chat))
                .overlay(alignment: .leading) {
                    // Swipe in from the edge to go back; the pager owns the rest of the width.
                    if duoChat, horizontalSizeClass == .compact { EdgeSwipeBack { dismiss() } }
                }
            VStack(spacing: 0) {
                // A Duo's running turn is the pill; the strip shows only sends and connection trouble there.
                if duoChat ? (status == .errored || model.sendState(for: chat) != nil
                              || model.connectivity.state != .connected)
                    : (verticalSizeClass != .compact || status == .working || status == .errored
                    || model.sendState(for: chat) != nil || model.connectivity.state != .connected) {
                    statusStrip(chat: chat, status: status, store: store)
                        .allowsHitTesting(model.sendState(for: chat).map { $0 == .failed || $0 == .waiting } ?? false)
                }
                Group {
                    if let request = store.openInputRequest {
                        QuestionPanel(requestId: request.requestId, questions: request.questions) { requestId, answers in
                            store.respondInput(requestId: requestId, answers: answers)
                        }
                    } else {
                        ComposerView(store: store, chat: chat, runLive: status == .working,
                                     attachmentDraft: attachmentDraft,
                                     questionClosedAtMs: questionClosedAtMs)
                            .id(chat.id)
                    }
                }
                .environment(\.foldComposerFocus, flat ? { up in
                    withAnimation(Motion.collapse) { keyboardUp = up }
                } : foldComposerFocus)
                .padding(.bottom, 8)
            }
            .background {
                LinearGradient(
                    stops: [
                        .init(color: Theme.bg.opacity(0), location: 0),
                        .init(color: Theme.bg.opacity(0.45), location: 0.25),
                        .init(color: Theme.bg.opacity(0.72), location: 0.6),
                        .init(color: Theme.bg, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .padding(.top, verticalSizeClass == .compact ? 0 : -24)
                .ignoresSafeArea(.container, edges: .bottom)
                .allowsHitTesting(false)
            }
        }
        // Flat: the chat column ends on the fold (the window's middle), not the middle of what the side bar leaves.
        .frame(width: flat && !keyboardUp && windowMidX - columnMinX > 240 ? windowMidX - columnMinX : nil)
        .frame(maxWidth: flat && !keyboardUp ? nil : .infinity)
            if flat, !keyboardUp {
                Rectangle().fill(Theme.border).frame(width: 1).ignoresSafeArea(.container, edges: .bottom)
                InspectPane(model: inspectModel, state: inspect)
                    .frame(maxWidth: .infinity)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            columnMinX = frame.minX
            // The fold is the window's middle; the side bar's column is outside this view's frame.
            let window = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
            windowMidX = window.map { $0.bounds.midX } ?? frame.midX
        }
        .overlay(alignment: .top) {
            #if DEBUG
            if model.demo != nil, ProcessInfo.processInfo.arguments.contains("-image-drop-fixture") {
                ImageDropFixture()
            }
            #endif
        }
        .onDrop(of: [UTType.image], isTargeted: Binding(
            get: { attachmentDraft.targeted },
            set: { attachmentDraft.targeted = $0 }
        )) { providers in
            guard store.openInputRequest == nil else { return false }
            return attachmentDraft.receive(providers)
        }
        .overlay {
            if attachmentDraft.targeted, attachmentDraft.canImport, store.openInputRequest == nil {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Theme.text.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .padding(8)
                    .overlay(alignment: .bottom) {
                        Text("Drop images to attach")
                            .font(Theme.sans(14, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .padding(12)
                            .background(Theme.bg, in: Capsule())
                            .padding(.bottom, 90)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            GeometryReader { geometry in
                // The bar stays opaque so the header never collides with rows
                // scrolling under it; the fade lives just below the bar.
                VStack(spacing: 0) {
                    Theme.bg.frame(height: geometry.safeAreaInsets.top)
                    LinearGradient(stops: [
                        .init(color: Theme.bg, location: 0),
                        .init(color: Theme.bg.opacity(0.85), location: 0.35),
                        .init(color: Theme.bg.opacity(0.45), location: 0.7),
                        .init(color: Theme.bg.opacity(0), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.topFadeHeight)
                }
                .offset(y: -geometry.safeAreaInsets.top)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onChange(of: chatId) { _, _ in
            attachmentDraft = AttachmentDraft()
            questionClosedAtMs = nil
        }
        .onChange(of: store.openInputRequest?.requestId) { old, new in
            if old != nil, new == nil { questionClosedAtMs = nowMs() }
        }
        .motionAnimation(Motion.fadeQuick, value: store.openInputRequest?.requestId)
    }

    private func liveStatus(chat: Chat) -> SessionStatus? {
        if let demo = model.demo {
            return effectiveStatus(demo.sessions[chat.id], now: nowMs())
        }
        return effectiveStatus(model.workspace?.sessions[chat.id], now: nowMs())
    }

    /// Reserved 24pt status strip (shell.rs render_status_strip) — Working
    /// shows the sunrise spinner + rotating flavour word + elapsed; Errored
    /// shows "Run failed"; the strip always reserves its height so the
    /// composer never shifts. An unadopted send's truth takes precedence:
    /// "Sending…" (healthy, within the 2-minute grace), "Queued — will send
    /// automatically" (degraded path — no fake progress), "Waiting for Mac to
    /// start it" (past the grace, still pending in the doc), or "Not
    /// delivered — tap to retry" once no command for it can run.
    private func statusStrip(chat: Chat, status: SessionStatus?, store: SessionStore) -> some View {
        // Ticks once a second only while something on the strip is timed: the Working elapsed counter, a
        // pending send's grace, or the reconnect countdown. An idle open chat repaints nothing.
        let timed = status == .working || model.sendState(for: chat) != nil
            || model.connectivity.state != .connected
        return TimelineView(.animation(minimumInterval: 1, paused: !timed)) { _ in
            HStack(spacing: 6) {
                switch model.sendState(for: chat) {
                case .failed?:
                    Button {
                        store.retryDelivery()
                    } label: {
                        Text("Not delivered — tap to retry")
                            .font(Theme.sans(11))
                            .foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.plain)
                case .waiting?:
                    // Still pending in the doc: the host can start it at any
                    // time (#413). Tapping re-checks delivery; it never sends
                    // a second copy of a command that can still run.
                    Button {
                        store.retryDelivery()
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Theme.warning)
                                .frame(width: 5, height: 5)
                            Text(waitingLabel(chat: chat, store: store))
                                .font(Theme.sans(11))
                                .foregroundStyle(Theme.textMuted)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                case .queued?:
                    Circle()
                        .fill(Theme.warning)
                        .frame(width: 5, height: 5)
                    Text("Queued — will send automatically")
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.warning.opacity(0.9))
                case .sending?:
                    // The percent tracks the REAL relay transfer (escort
                    // bytes committed to the host), not just local staging.
                    if let progress = store.transferProgress {
                        Text("Uploading… \(Int(progress * 100))%")
                            .font(Theme.sans(11))
                            .foregroundStyle(Theme.textMuted)
                            .monospacedDigit()
                    } else {
                        Text("Sending…")
                            .font(Theme.sans(11))
                            .foregroundStyle(Theme.textMuted)
                    }
                case nil:
                    switch model.connectivity.state {
                    case .offline:
                        Circle().fill(Theme.warning).frame(width: 5, height: 5)
                        Text("Offline — sends are saved")
                            .font(Theme.sans(11)).foregroundStyle(Theme.textFaint)
                    case .reconnecting:
                        ProgressView().controlSize(.mini).tint(Theme.textMuted)
                        Text(reconnectingLabel)
                            .font(Theme.sans(11)).foregroundStyle(Theme.textFaint).monospacedDigit()
                    case .connected:
                        normalStatus(chat: chat, status: status, store: store)
                    }
                }
            }
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 26)  // aligns with the composer's text start
        }
    }

    /// "Waiting for Mac to start it · sent 9m 57s ago". The age counts from the original
    /// submission, which a retry keeps; only the delivery grace restarts.
    private func waitingLabel(chat: Chat, store: SessionStore) -> String {
        let host = model.deviceName(store.hostDeviceId ?? chat.deviceId)
        let sent = store.pendingSends.map(\.at).min() ?? nowMs()
        let age = Motion.formatElapsed((nowMs() - sent) / 1000)
        let what = store.transferProgress != nil
            ? "Attachments still on their way to \(host)"
            : "Waiting for \(host) to start it"
        return "\(what) · sent \(age) ago"
    }

    private var reconnectingLabel: String {
        guard let retryAt = model.connectivity.retryAt else { return "Reconnecting…" }
        let secs = Int(retryAt.timeIntervalSinceNow.rounded(.up))
        return secs > 1 ? "Reconnecting in \(secs)s…" : "Reconnecting…"
    }

    @ViewBuilder
    private func normalStatus(chat: Chat, status: SessionStatus?, store: SessionStore) -> some View {
        Group {
                switch status {
                case .working:
                    WorkingSpinner()
                    let startedAt = sessionStartedAt(chat: chat)
                    let elapsed = (nowMs() - startedAt) / 1000
                    Text("\(Motion.flavourWord(seed: Motion.flavourSeed(chat.id), elapsedSecs: elapsed))…")
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.textMuted)
                    Text(Motion.formatElapsed(elapsed))
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.textFaint)
                        .monospacedDigit()
                    // The timer counts the run; a prompt that sat waiting
                    // for its host says how long, after it (#413).
                    if let waited = turnWaitSecs(entries: store.entries, turnStartedAt: turnStartedAt(chat: chat)) {
                        Text("· waited \(Motion.formatElapsed(waited)) to start")
                            .font(Theme.sans(11))
                            .foregroundStyle(Theme.textFaint)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                case .errored:
                    Text("Run failed")
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.danger)
                default:
                    EmptyView()
                }
        }
    }

    /// The host's start of this turn only, without the timer's fallbacks.
    private func turnStartedAt(chat: Chat) -> Int64? {
        (model.demo?.sessions[chat.id] ?? model.workspace?.sessions[chat.id])?.startedAt
    }

    private func sessionStartedAt(chat: Chat) -> Int64 {
        let row = model.demo?.sessions[chat.id] ?? model.workspace?.sessions[chat.id]
        return row?.startedAt ?? row?.updatedAt ?? nowMs()
    }
}
