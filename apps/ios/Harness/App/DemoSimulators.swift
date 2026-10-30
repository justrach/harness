// Demo mode's Mac and its iOS Simulators: a made-up list, so Settings →
// Simulators can be explored and tested offline, and a drawn screen for the
// live view that answers touches, typing, and the Home button the way a
// simulator would show them. Launch flag `-simulators-set-up` starts with the
// streaming helper already installed.

import UIKit

@MainActor
final class DemoSimulators: SimulatorHost {
    private(set) var setUp: Bool
    private(set) var devices: [SimulatorDevice] = [
        SimulatorDevice(id: "5D3A1C2E-8F4B-4A6D-9E21-7B0C3D4E5F60", name: "iPhone 17 Pro",
                        runtime: "iOS 27.0", booted: true),
        SimulatorDevice(id: "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D", name: "iPhone 17",
                        runtime: "iOS 27.0", booted: false),
        SimulatorDevice(id: "0F1E2D3C-4B5A-4968-8776-655443322110", name: "iPad Air 13-inch (M4)",
                        runtime: "iOS 27.0", booted: false),
    ]
    /// What each simulator was sent, oldest first (UI tests read the screen instead).
    private(set) var inputs: [String: [SimulatorInput]] = [:]
    private var screens: [String: DemoScreen] = [:]
    private var watchers: [String: [UUID: AsyncThrowingStream<SimulatorFrame, Error>.Continuation]] = [:]

    init(setUp: Bool) {
        self.setUp = setUp
    }

    private var list: SimulatorList {
        SimulatorList(supported: true, reason: nil, setUp: setUp, devices: devices)
    }

    func listSimulators(deviceId: String) async throws -> SimulatorList {
        try? await Task.sleep(nanoseconds: 150_000_000)  // feel like a network hop
        return list
    }

    func setUpSimulators(deviceId: String) async throws -> SimulatorList {
        try? await Task.sleep(nanoseconds: 900_000_000)  // an install takes a while
        setUp = true
        return list
    }

    func bootSimulator(deviceId: String, simulatorId: String) async throws {
        try? await Task.sleep(nanoseconds: 600_000_000)
        try setBooted(simulatorId, true)
    }

    func shutdownSimulator(deviceId: String, simulatorId: String) async throws {
        try? await Task.sleep(nanoseconds: 300_000_000)
        try setBooted(simulatorId, false)
        let ended = watchers.removeValue(forKey: simulatorId).map { Array($0.values) } ?? []
        for continuation in ended {
            continuation.finish()
        }
    }

    private func setBooted(_ id: String, _ booted: Bool) throws {
        guard let index = devices.firstIndex(where: { $0.id == id }) else {
            throw RelayError.rpc("no iOS Simulator \(id) on this computer")
        }
        devices[index].booted = booted
    }

    func simulatorScreen(deviceId: String, simulatorId: String, maxFps: Int) async throws
        -> AsyncThrowingStream<SimulatorFrame, Error> {
        guard let device = devices.first(where: { $0.id == simulatorId }), device.booted else {
            throw RelayError.rpc("no iOS Simulator \(simulatorId) on this computer")
        }
        let (stream, continuation) = AsyncThrowingStream<SimulatorFrame, Error>.makeStream()
        let token = UUID()
        watchers[simulatorId, default: [:]][token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.watchers[simulatorId]?[token] = nil }
        }
        let screen = screens[simulatorId] ?? DemoScreen(name: device.name)
        screens[simulatorId] = screen
        continuation.yield(screen.frame())
        return stream
    }

    func simulatorInput(deviceId: String, simulatorId: String, input: SimulatorInput) async throws {
        guard let screen = screens[simulatorId] else {
            throw RelayError.rpc("no iOS Simulator \(simulatorId) on this computer")
        }
        inputs[simulatorId, default: []].append(input)
        screen.apply(input)
        let frame = screen.frame()
        let watching = watchers[simulatorId].map { Array($0.values) } ?? []
        for continuation in watching {
            continuation.yield(frame)
        }
    }
}

/// A drawn stand-in for a simulator's screen.
@MainActor
private final class DemoScreen {
    let name: String
    private var seq: UInt64 = 0
    private var typed = ""
    private var lastTouch: CGPoint?
    private var page = "Home"

    init(name: String) {
        self.name = name
    }

    func apply(_ input: SimulatorInput) {
        switch input {
        case .touch(let phase, let x, let y):
            lastTouch = CGPoint(x: x, y: y)
            if phase == .end { page = "Tapped" }
        case .button(.home):
            page = "Home"
            typed = ""
            lastTouch = nil
        case .button:
            break
        case .text(let text):
            typed += text
        case .key("backspace"):
            if !typed.isEmpty { typed.removeLast() }
        case .key:
            break
        }
    }

    func frame() -> SimulatorFrame {
        seq += 1
        let size = CGSize(width: 442, height: 960)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(red: 0.16, green: 0.22, blue: 0.42, alpha: 1).cgColor,
                          UIColor(red: 0.45, green: 0.25, blue: 0.48, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero,
                                                     end: CGPoint(x: 0, y: size.height), options: [])
            }
            let title: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: UIColor.white,
            ]
            let body: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .regular),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85),
            ]
            (page as NSString).draw(at: CGPoint(x: 32, y: 120), withAttributes: title)
            (name as NSString).draw(at: CGPoint(x: 32, y: 168), withAttributes: body)
            if !typed.isEmpty {
                ("Typed: \(typed)" as NSString).draw(in: CGRect(x: 32, y: 230, width: size.width - 64, height: 200),
                                                     withAttributes: body)
            }
            for row in 0..<4 {
                for column in 0..<4 {
                    let rect = CGRect(x: 32 + CGFloat(column) * 98, y: 470 + CGFloat(row) * 104,
                                      width: 74, height: 74)
                    UIColor.white.withAlphaComponent(0.22).setFill()
                    UIBezierPath(roundedRect: rect, cornerRadius: 18).fill()
                }
            }
            if let touch = lastTouch {
                let point = CGPoint(x: touch.x * size.width, y: touch.y * size.height)
                UIColor.white.withAlphaComponent(0.7).setFill()
                UIBezierPath(ovalIn: CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)).fill()
            }
        }
        let jpeg = image.jpegData(compressionQuality: 0.6) ?? Data()
        return SimulatorFrame(seq: seq, jpeg: jpeg.base64EncodedString())
    }
}
