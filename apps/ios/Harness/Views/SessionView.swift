// Session screen — transcript + status strip + composer (or question panel
// while input is requested, replacing the composer like the desktop). Reading
// marks the chat seen (the synced LWW marker behind the green dot everywhere).

import SwiftUI

struct SessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// Open another session beside this one, or close this pane: set only on a Max-class iPhone (SplitScreen).
    @Environment(\.splitScreen) private var splitScreen
    let chatId: String

    /// Width the nav bar's own controls need around a LEADING title — the
    /// back button ahead of it, bar margins, and slack. Generous on purpose:
    /// a fixed-width item that does NOT fit gets evicted into a trailing "…"
    /// overflow menu (where a custom text stack renders as nothing) — seen on
    /// iPhone Air at 110.
    private static let headerChromeInset: CGFloat = 170
    private static let topFadeHeight: CGFloat = 28

    /// The view's own width, the only reliable basis for capping the principal
    /// toolbar item (its container proposes an unbounded width).
    @State private var viewWidth: CGFloat = 0

    /// Follow intent belongs to the session, independent of composer focus.
    @State private var scroll = ScrollState()


    /// On a Max (split screen available) every session draws its own compact header strip and the navigation
    /// bar is hidden. The bar's fixed-width header kept being evicted into the "…" menu in the narrow columns a
    /// Max uses (a session beside the list, or two panes of about 478pt), and on a landscape Max the bar is also
    /// a lot of lost height. Everywhere else the bar and its header are exactly as before.
    private var paneChrome: Bool { splitScreen != nil }

    /// Title, project and the pager hint; one element for accessibility.
    private func headerTitle(_ chat: Chat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(chat.displayTitle)
                    .font(Theme.sans(15, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                pagerHint(for: chat)
            }
            projectLocation(chat: chat, model: model)
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textMuted.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session-header")
    }

    /// A pane's header strip: the list toggle (one pane), title and project, and the split or close button.
    /// Swipe it to page to a neighbouring session.
    private func paneHeader(_ chat: Chat, controls: SplitScreenControls) -> some View {
        HStack(spacing: 8) {
            if let toggleList = controls.toggleList {
                Button(action: toggleList) {
                    Image(systemName: "sidebar.leading")
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .buttonStyle(.plain)
                .accessibilityLabel("Show or hide the session list")
                .accessibilityIdentifier("split-toggle-list")
            }
            headerTitle(chat)
            Spacer(minLength: 8)
            splitButtons(controls)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Theme.bg)
        .pagerSwipe()
    }

    @ViewBuilder
    private func splitButtons(_ controls: SplitScreenControls) -> some View {
        HStack(spacing: 14) {
            if let openBeside = controls.openBeside {
                Button(action: openBeside) {
                    Image(systemName: "rectangle.split.2x1")
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Open another session beside this one")
                .accessibilityIdentifier("split-open-beside")
            }
            if let close = controls.close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close this pane")
                .accessibilityIdentifier("split-close-pane")
            }
        }
        .font(.system(size: 15, weight: .medium))
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
                    if paneChrome, let splitScreen {
                        paneHeader(chat, controls: splitScreen)
                        content(chat: chat, store: store).clipped()
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
                // Static, left-aligned session header — model/effort changes
                // moved into the composer's picker chips.
                ToolbarItem(placement: .topBarLeading) {
                    headerTitle(chat)
                        // A FIXED width, not a max: iOS 26 proposes leading items
                        // almost nothing next to the back button, so a flexible
                        // frame collapses to its minimum ("S…"). Claiming the
                        // remainder of the bar outright lays the texts out with
                        // real room and truncates them properly.
                        .frame(width: max(140, viewWidth - Self.headerChromeInset), alignment: .leading)
                        // Swipe the header to page to the neighbouring session.
                        .pagerSwipe()
                }
                // Bare text on the bar, not a glass capsule.
                .sharedBackgroundVisibility(.hidden)
            }
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


    /// "‹ 2/3 ›": where this session sits among the ones the header swipe pages
    /// through, so the swipe is discoverable. Hidden when there's nowhere to go.
    @ViewBuilder
    private func pagerHint(for chat: Chat) -> some View {
        let _ = model.connectivity.pulse
        if let place = SessionPaging.position(of: chat.id, in: SessionPaging.entries(model: model)) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left").opacity(place.index > 1 ? 1 : 0.3)
                Text("\(place.index)/\(place.count)").monospacedDigit()
                Image(systemName: "chevron.right").opacity(place.index < place.count ? 1 : 0.3)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textFaint)
            .fixedSize()
            .accessibilityHidden(true)
        }
    }

    private func content(chat: Chat, store: SessionStore) -> some View {
        let status = liveStatus(chat: chat)
        // The composer owns real layout space. The transcript's viewport ends
        // above it, so keyboard and glass morphs cannot cover the last row.
        return VStack(spacing: 0) {
            TranscriptView(store: store, chatId: chat.id, scroll: scroll)
                .overlay {
                    if store.entries.isEmpty, store.pendingSends.isEmpty,
                       chat.lastMessageAt != nil {
                        TranscriptSkeleton().background(Theme.bg)
                    }
                }
                .motionAnimation(Motion.fadeQuick, value: store.entries.isEmpty)
                // Bottom-right, clear of the centered jump-to-latest button.
                .overlay(alignment: .bottomTrailing) {
                    SessionSwitcherPill(current: chat.id, compact: true)
                        .padding(12)
                }
            VStack(spacing: 0) {
                if verticalSizeClass != .compact || status == .working || status == .errored
                    || model.sendState(for: chat) != nil || model.connectivity.state != .connected {
                    statusStrip(chat: chat, status: status, store: store)
                        .allowsHitTesting(model.sendState(for: chat) == .failed)
                }
                Group {
                    if let request = store.openInputRequest {
                        QuestionPanel(requestId: request.requestId, questions: request.questions) { requestId, answers in
                            store.respondInput(requestId: requestId, answers: answers)
                        }
                    } else {
                        ComposerView(store: store, chat: chat, runLive: status == .working)
                            .id(chat.id)
                    }
                }
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
        .background(Theme.bg.ignoresSafeArea())
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
    /// automatically" (degraded path — no fake progress), or the explicit
    /// "Not delivered — tap to retry" (transcript.rs retry_send).
    private func statusStrip(chat: Chat, status: SessionStatus?, store: SessionStore) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
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
                        normalStatus(chat: chat, status: status)
                    }
                }
            }
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 26)  // aligns with the composer's text start
        }
    }

    private var reconnectingLabel: String {
        guard let retryAt = model.connectivity.retryAt else { return "Reconnecting…" }
        let secs = Int(retryAt.timeIntervalSinceNow.rounded(.up))
        return secs > 1 ? "Reconnecting in \(secs)s…" : "Reconnecting…"
    }

    @ViewBuilder
    private func normalStatus(chat: Chat, status: SessionStatus?) -> some View {
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
                case .errored:
                    Text("Run failed")
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.danger)
                default:
                    EmptyView()
                }
        }
    }

    private func sessionStartedAt(chat: Chat) -> Int64 {
        let row = model.demo?.sessions[chat.id] ?? model.workspace?.sessions[chat.id]
        return row?.startedAt ?? row?.updatedAt ?? nowMs()
    }
}
