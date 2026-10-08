// iOS Simulators on one of your computers, as its engine reports them
// (`ListSimulators`), and one frame of a simulator's live screen
// (`WatchSimulatorScreen`).

import Foundation

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
enum SimulatorInput {
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
