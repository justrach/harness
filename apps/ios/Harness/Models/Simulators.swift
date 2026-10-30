// iOS Simulators on one of your computers, as its engine reports them
// (`ListSimulators`), and one frame of a simulator's live screen
// (`WatchSimulatorScreen`).

import Foundation
import Network

struct SimulatorList: Decodable, Equatable {
    /// False off macOS or without Xcode; `reason` says which.
    var supported: Bool
    var reason: String?
    /// The computer has the streaming helper installed (`SetUpSimulators`).
    var setUp: Bool
    var devices: [SimulatorDevice]
}

struct SimulatorDevice: Decodable, Equatable, Identifiable, Hashable {
    var id: String
    var name: String
    /// e.g. "iOS 27.0".
    var runtime: String
    var booted: Bool
}

struct SimulatorFrame: Decodable {
    var seq: UInt64
    /// Base64 JPEG, downscaled on the computer.
    var jpeg: String
}

/// Input sent to a simulator. Touch coordinates are fractions of the screen.
enum SimulatorInput: Equatable {
    enum Phase: String { case begin, move, end }
    enum Button: String { case home, lock, volumeUp, volumeDown }

    case touch(Phase, x: Double, y: Double)
    case button(Button)
    case text(String)
    case key(String)

    var params: [String: Any] {
        switch self {
        case .touch(let phase, let x, let y):
            return ["kind": "touch", "phase": phase.rawValue, "x": x, "y": y]
        case .button(let button):
            return ["kind": "button", "button": button.rawValue]
        case .text(let text):
            return ["kind": "text", "text": text]
        case .key(let key):
            return ["kind": "key", "key": key]
        }
    }
}

/// Where the Simulators screens send their calls: a computer's engine over its
/// relay (`WorkspaceStore`), or demo mode's made-up Mac.
@MainActor
protocol SimulatorHost: AnyObject {
    func listSimulators(deviceId: String) async throws -> SimulatorList
    func setUpSimulators(deviceId: String) async throws -> SimulatorList
    func bootSimulator(deviceId: String, simulatorId: String) async throws
    func shutdownSimulator(deviceId: String, simulatorId: String) async throws
    func simulatorScreen(deviceId: String, simulatorId: String, maxFps: Int) async throws
        -> AsyncThrowingStream<SimulatorFrame, Error>
    func simulatorInput(deviceId: String, simulatorId: String, input: SimulatorInput) async throws
}

enum SimulatorHosts {
    /// Simulators run only on a Mac: its computers, online ones first.
    static func macs(_ devices: [DeviceRow], online: (String) -> Bool) -> [DeviceRow] {
        let candidates = devices.filter { $0.platform == "macos" && $0.canHostSessions }
        return candidates.filter { online($0.id) } + candidates.filter { !online($0.id) }
    }

    /// How a failed call reads: an older Mac, the engine's own sentence, or the relay's reason.
    static func failure(_ error: Error, deviceName: String) -> String {
        if case RelayError.rpc(let message) = error {
            if message.contains("unknown method") {
                return "Update Harness on \(deviceName) to use its simulators from your phone."
            }
            return message
        }
        let reason = (error as? RelayError)?.errorDescription ?? describeTransportError(error)
        return "Couldn't reach \(deviceName): \(reason)"
    }
}

/// How many frames a second to ask a computer for: fewer on a metered or Low
/// Data Mode network, where every frame is a JPEG over the relay.
enum SimulatorStreamRate {
    static let unmetered = 15
    static let metered = 6

    static func fps(expensive: Bool, constrained: Bool) -> Int {
        expensive || constrained ? metered : unmetered
    }

    /// The current path's rate (one look at the network, then the monitor stops).
    static func current() async -> Int {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = FirstUpdate()
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: fps(expensive: path.isExpensive,
                                                   constrained: path.isConstrained))
            }
            monitor.start(queue: DispatchQueue(label: "harness.simulator-rate"))
        }
    }
}

/// True for the first caller only (path updates arrive on the monitor's queue).
private final class FirstUpdate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
