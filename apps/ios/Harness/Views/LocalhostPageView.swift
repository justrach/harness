// A page one of your computers serves on its own localhost, used from the
// phone: the computer renders it in a headless browser and streams frames
// over the relay; taps, scrolls and typing go back to it. Opened from a
// localhost link in a chat (the host-link sheet).

import SwiftUI
import UIKit

struct LocalhostPageView: View {
    let target: LocalhostPageTarget

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var url: String
    @State private var image: UIImage?
    @State private var frame: LocalhostFrame?
    @State private var status: String? = "Opening…"
    @State private var stopped = false
    @State private var attempt = 0
    @State private var pageSize: CGSize = .zero
    @State private var address = ""
    @FocusState private var addressFocused: Bool
    @State private var typing = false
    @State private var draft = ""
    @State private var sentDraft = ""
    @FocusState private var draftFocused: Bool
    @State private var hiddenNotice: String?
    @State private var refusal: String?
    @State private var input = LocalhostInputQueue()
    @State private var drag: DragState?

    init(target: LocalhostPageTarget) {
        self.target = target
        _url = State(initialValue: target.url)
    }

    private struct DragState {
        var last: CGPoint
        var scrolling: Bool
    }

    private struct WatchKey: Equatable {
        var attempt: Int
        var url: String
        var ready: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            page
            if typing { keyboardBar }
            bottomBar
        }
        .background(Theme.bg.ignoresSafeArea())
        .task(id: WatchKey(attempt: attempt, url: url, ready: pageSize != .zero)) {
            guard pageSize != .zero else { return }
            await watch()
        }
        .onChange(of: pageSize) { _, size in
            guard size != .zero, input.viewId != nil else { return }
            input.enqueue(.resize(width: size.width, height: size.height,
                                  scale: LocalhostPages.renderScale(screenScale: displayScale)))
        }
        .onChange(of: draft) { _, text in
            for edit in LocalhostPages.typingEdits(from: sentDraft, to: text) { input.enqueue(edit) }
            sentDraft = text
        }
        .harnessAppearance()
    }

    // MARK: Bars

    private var topBar: some View {
        HStack(spacing: 10) {
            Button("Done") { dismiss() }
                .font(Theme.sans(16, weight: .semibold))
                .accessibilityIdentifier("localhost-done")
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                TextField("localhost:3000", text: $address)
                    .font(Theme.sans(15))
                    .foregroundStyle(Theme.text)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit(openAddress)
                    .accessibilityIdentifier("localhost-address")
                if frame?.loading == true {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityIdentifier("localhost-loading")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(ink(0.06), in: Capsule())
            .onChange(of: addressFocused) { _, focused in
                if focused { address = frame?.url ?? url }
                else { address = LocalhostPages.displayAddress(frame?.url ?? url) }
            }
            barButton("arrow.clockwise", label: "Reload", id: "localhost-reload", action: reload)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .onAppear { address = LocalhostPages.displayAddress(url) }
    }

    private var bottomBar: some View {
        HStack(spacing: 18) {
            barButton("chevron.left", label: "Back", id: "localhost-back") { input.enqueue(.back) }
                .disabled(frame?.canGoBack != true)
            barButton("chevron.right", label: "Forward", id: "localhost-forward") { input.enqueue(.forward) }
                .disabled(frame?.canGoForward != true)
            Spacer(minLength: 0)
            Text("On \(target.deviceName)")
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)
                .accessibilityIdentifier("localhost-device")
            Spacer(minLength: 0)
            barButton(typing ? "keyboard.chevron.compact.down" : "keyboard",
                      label: typing ? "Hide keyboard" : "Type", id: "localhost-keyboard") {
                typing.toggle()
                draftFocused = typing
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }

    private var keyboardBar: some View {
        HStack(spacing: 8) {
            TextField("Type into the page", text: $draft)
                .font(Theme.sans(15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($draftFocused)
                .submitLabel(.return)
                .onSubmit {
                    input.enqueue(.key("enter"))
                    sentDraft = ""
                    draft = ""
                    draftFocused = true
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(ink(0.06), in: Capsule())
                .accessibilityIdentifier("localhost-type-field")
            barButton("delete.left", label: "Delete", id: "localhost-delete") { input.enqueue(.key("backspace")) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func barButton(_ symbol: String, label: String, id: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 36, height: 36)
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    // MARK: Page

    private var page: some View {
        ZStack {
            Color.white.opacity(image == nil ? 0 : 1)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay { touchSurface }
                    .accessibilityLabel(frame?.title.isEmpty == false ? frame!.title : "Page")
                    .accessibilityIdentifier("localhost-page")
            }
            if let status {
                VStack(spacing: 10) {
                    if image == nil, !stopped { ProgressView() }
                    Text(status)
                        .font(Theme.sans(14))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("localhost-status")
                    if stopped {
                        Button("Try again", action: reload)
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("localhost-retry")
                    }
                }
                .padding(16)
                .frame(maxWidth: 320)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            pageSize = CGSize(width: size.width.rounded(), height: size.height.rounded())
        }
        .overlay(alignment: .bottom) { noticeBanner }
    }

    @ViewBuilder private var noticeBanner: some View {
        if let notice = refusal ?? frame?.notice, notice != hiddenNotice {
            Button {
                hiddenNotice = notice
                refusal = nil
            } label: {
                Text(notice)
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .padding(12)
            .accessibilityIdentifier("localhost-notice")
        }
    }

    /// Sits exactly over the fitted frame: a short touch is a tap, a longer
    /// one scrolls the page under the finger.
    private var touchSurface: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            var state = drag ?? DragState(last: value.startLocation, scrolling: false)
                            if !state.scrolling, LocalhostPages.isTap(value.translation) {
                                drag = state
                                return
                            }
                            state.scrolling = true
                            let moved = CGSize(width: value.location.x - state.last.x,
                                               height: value.location.y - state.last.y)
                            state.last = value.location
                            drag = state
                            let delta = LocalhostPages.scrollDelta(moved, viewSize: geo.size, page: pageCSS)
                            let at = LocalhostPages.pagePoint(value.startLocation, viewSize: geo.size, page: pageCSS)
                            input.enqueue(.scroll(x: at.x, y: at.y, dx: delta.width, dy: delta.height))
                        }
                        .onEnded { value in
                            defer { drag = nil }
                            guard drag?.scrolling != true, LocalhostPages.isTap(value.translation) else { return }
                            let at = LocalhostPages.pagePoint(value.location, viewSize: geo.size, page: pageCSS)
                            input.enqueue(.tap(x: at.x, y: at.y))
                        }
                )
        }
    }

    private var pageCSS: CGSize {
        CGSize(width: frame?.width ?? pageSize.width, height: frame?.height ?? pageSize.height)
    }

    // MARK: Actions

    private func openAddress() {
        guard let next = LocalhostPages.pageURL(address) else {
            refusal = "Only pages on \(target.deviceName) open here, like localhost:3000."
            return
        }
        refusal = nil
        if input.viewId != nil, !stopped {
            input.enqueue(.navigate(next))
        } else {
            open(next)
        }
    }

    private func reload() {
        if input.viewId != nil, !stopped {
            input.enqueue(.reload)
        } else {
            attempt += 1
        }
    }

    private func open(_ next: String) {
        input.viewId = nil
        url = next
        attempt += 1
    }

    /// Stream the page until the view goes away, reconnecting through relay
    /// gaps (rejoining the same page). The engine's own refusals and a page
    /// that ended stop here and offer Try again.
    private func watch() async {
        stopped = false
        status = image == nil ? "Opening \(LocalhostPages.displayAddress(url)) on \(target.deviceName)…" : nil
        var retry: UInt64 = 500_000_000
        while !Task.isCancelled {
            do {
                let host = try model.localhostPageHost()
                input.send = { [deviceId = target.deviceId, model] viewId, event in
                    try await model.localhostPageHost().localhostPageInput(deviceId: deviceId, viewId: viewId,
                                                                           input: event)
                }
                let fps = await SimulatorStreamRate.current()
                let request = LocalhostWatch(url: url, viewId: input.viewId,
                                             width: pageSize.width, height: pageSize.height,
                                             scale: LocalhostPages.renderScale(screenScale: displayScale),
                                             fps: fps)
                let stream = try await host.watchLocalhostPage(deviceId: target.deviceId, watch: request)
                for try await event in stream {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .frame(let next):
                        input.viewId = next.viewId
                        if let jpeg = next.jpeg {
                            let decoded = await Task.detached(priority: .userInitiated) {
                                Data(base64Encoded: jpeg).flatMap(UIImage.init(data:))
                            }.value
                            if let decoded { image = decoded }
                        }
                        frame = next
                        if !addressFocused { address = LocalhostPages.displayAddress(next.url) }
                        if image != nil { status = nil }
                        retry = 500_000_000
                    case .ended(let message):
                        input.viewId = nil
                        status = message
                        stopped = true
                        return
                    }
                }
                status = "Reconnecting…"
            } catch {
                guard !Task.isCancelled else { return }
                status = LocalhostPages.failure(error, deviceName: target.deviceName)
                if case RelayError.rpc(_) = error {
                    stopped = true
                    return
                }
            }
            try? await Task.sleep(nanoseconds: retry)
            retry = min(retry * 2, 5_000_000_000)
        }
    }
}

/// Sends a page's input in order, one call at a time, without holding up the
/// gesture. Waiting scrolls add up into one; a waiting resize is replaced by
/// the newer one.
@MainActor
final class LocalhostInputQueue {
    var send: ((String, LocalhostPageInput) async throws -> Void)?
    /// The page the input goes to (from the latest frame).
    var viewId: String?
    private(set) var pending: [LocalhostPageInput] = []
    private var draining = false

    func enqueue(_ event: LocalhostPageInput) {
        switch (event, pending.last) {
        case (.scroll(let x, let y, let dx, let dy), .scroll(_, _, let waitingDx, let waitingDy)?):
            pending[pending.count - 1] = .scroll(x: x, y: y, dx: dx + waitingDx, dy: dy + waitingDy)
        case (.resize, .resize?):
            pending[pending.count - 1] = event
        default:
            pending.append(event)
        }
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        while !pending.isEmpty {
            let event = pending.removeFirst()
            guard let viewId else { continue }
            try? await send?(viewId, event)
        }
        draining = false
    }
}
