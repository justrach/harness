// A simulator on your Mac, live: its screen streams in over the relay and
// your touches, typing, and hardware buttons go back to it. Opened from
// Settings > Simulators.

import SwiftUI
import UIKit

struct SimulatorScreenView: View {
    let deviceId: String
    let simulator: SimulatorDevice

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var status: String? = "Connecting…"
    @State private var typing = false
    @State private var draft = ""
    @State private var input = InputQueue()
    @FocusState private var draftFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            header
            screen
            if typing { keyboardBar }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await watch() }
        .onAppear {
            input.send = { [deviceId, simulator, model] event in
                try await model.simulatorHost().simulatorInput(deviceId: deviceId,
                                                               simulatorId: simulator.id,
                                                               input: event)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            circleButton("xmark", label: "Close") { dismiss() }
            Spacer()
            Text(simulator.name)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            Menu {
                Button {
                    typing.toggle()
                    draftFocused = typing
                } label: {
                    Label(typing ? "Hide keyboard" : "Type", systemImage: "keyboard")
                }
                Button { input.enqueue(.button(.lock)) } label: {
                    Label("Lock", systemImage: "lock")
                }
                Button { input.enqueue(.button(.volumeUp)) } label: {
                    Label("Volume up", systemImage: "speaker.plus")
                }
                Button { input.enqueue(.button(.volumeDown)) } label: {
                    Label("Volume down", systemImage: "speaker.minus")
                }
                Divider()
                Button(role: .destructive) {
                    Task {
                        try? await model.simulatorHost().shutdownSimulator(deviceId: deviceId,
                                                                           simulatorId: simulator.id)
                        dismiss()
                    }
                } label: {
                    Label("Shut down", systemImage: "power")
                }
            } label: {
                circleLabel("ellipsis")
            }
            .accessibilityLabel("More")
            circleButton("house", label: "Home") { input.enqueue(.button(.home)) }
        }
        .padding(.top, 4)
    }

    private var screen: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay { touchSurface }
                    .accessibilityLabel("\(simulator.name) screen")
            }
            if let status {
                VStack(spacing: 10) {
                    if image == nil { ProgressView().tint(.white) }
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Sits exactly over the fitted image, so a touch's fraction of this view
    /// is its fraction of the simulator's screen.
    private var touchSurface: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            let point = fraction(value.location, in: geo.size)
                            let began = value.translation == .zero && !input.touching
                            input.touching = true
                            input.enqueue(.touch(began ? .begin : .move, x: point.x, y: point.y))
                        }
                        .onEnded { value in
                            let point = fraction(value.location, in: geo.size)
                            input.touching = false
                            input.enqueue(.touch(.end, x: point.x, y: point.y))
                        }
                )
        }
    }

    private var keyboardBar: some View {
        HStack(spacing: 8) {
            TextField("Type on the simulator", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($draftFocused)
                .submitLabel(.send)
                .onSubmit {
                    if !draft.isEmpty { input.enqueue(.text(draft)) }
                    input.enqueue(.key("enter"))
                    draft = ""
                    draftFocused = true
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.12), in: Capsule())
                .foregroundStyle(.white)
            circleButton("delete.left", label: "Delete") { input.enqueue(.key("backspace")) }
            circleButton("arrow.up.circle", label: "Send") {
                if !draft.isEmpty { input.enqueue(.text(draft)) }
                draft = ""
            }
        }
    }

    private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { circleLabel(symbol) }
            .accessibilityLabel(label)
    }

    private func circleLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Color.white.opacity(0.14), in: Circle())
    }

    private func fraction(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(x: min(max(point.x / size.width, 0), 1),
                       y: min(max(point.y / size.height, 0), 1))
    }

    /// Stream frames until the view goes away, reconnecting through gaps.
    private func watch() async {
        var retry: UInt64 = 500_000_000
        while !Task.isCancelled {
            do {
                let stream = try await model.simulatorHost().simulatorScreen(deviceId: deviceId,
                                                                             simulatorId: simulator.id)
                for try await frame in stream {
                    guard !Task.isCancelled else { return }
                    let decoded = await Task.detached(priority: .userInitiated) {
                        Data(base64Encoded: frame.jpeg).flatMap(UIImage.init(data:))
                    }.value
                    if let decoded {
                        image = decoded
                        status = nil
                        retry = 500_000_000
                    }
                }
                status = "Reconnecting…"
            } catch {
                guard !Task.isCancelled else { return }
                if case RelayError.rpc(let message) = error {
                    status = message.contains("unknown method")
                        ? "Update Harness on \(model.deviceName(deviceId)) to view its simulators."
                        : message
                } else {
                    status = "Reconnecting…"
                }
            }
            try? await Task.sleep(nanoseconds: retry)
            retry = min(retry * 2, 5_000_000_000)
        }
    }
}

/// Sends input in order, one call at a time, without holding up the gesture.
/// Moves coalesce: a move still waiting is replaced by the newer one.
@MainActor
final class InputQueue {
    var send: ((SimulatorInput) async throws -> Void)?
    var touching = false
    private var pending: [SimulatorInput] = []
    private var draining = false

    func enqueue(_ event: SimulatorInput) {
        if case .touch(.move, _, _) = event, case .touch(.move, _, _)? = pending.last {
            pending[pending.count - 1] = event
        } else {
            pending.append(event)
        }
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        while !pending.isEmpty {
            let event = pending.removeFirst()
            try? await send?(event)
        }
        draining = false
    }
}
