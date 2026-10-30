// Debug builds only: `-simulator-engine <port>` sends the Simulators screens'
// calls to an engine's local RPC socket on this Mac instead of over a relay.
// The iOS Simulator shares the Mac's loopback, so the screens can be tested
// end to end against real simulators without an account. Shipping builds
// never compile this.

#if DEBUG
import Foundation

@MainActor
final class LocalEngineSimulatorHost: SimulatorHost {
    private let url: URL
    private var socket: URLSessionWebSocketTask?
    private let pending = DeviceRpcPending()
    private var nextId: UInt64 = 1

    init(port: Int) {
        url = URL(string: "ws://127.0.0.1:\(port)")!
    }

    /// The port from `-simulator-engine <port>`, if the app was launched with one.
    static func launchPort(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Int? {
        guard let index = arguments.firstIndex(of: "-simulator-engine"), index + 1 < arguments.count else {
            return nil
        }
        return Int(arguments[index + 1])
    }

    private func connected() -> URLSessionWebSocketTask {
        if let socket, socket.state == .running { return socket }
        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
        socket = task
        Task { await receive(on: task) }
        return task
    }

    private func receive(on task: URLSessionWebSocketTask) async {
        while true {
            do {
                switch try await task.receive() {
                case .string(let text): pending.handlePayload(Data(text.utf8))
                case .data(let data): pending.handlePayload(data)
                @unknown default: break
                }
            } catch {
                if socket === task { socket = nil }
                pending.failAll(error: .notConnected)
                return
            }
        }
    }

    private func send(_ object: [String: Any], on task: URLSessionWebSocketTask, id: UInt64) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        Task {
            do {
                try await task.send(.string(String(decoding: data, as: UTF8.self)))
            } catch {
                pending.fail(id: id, error: .notConnected)
            }
        }
    }

    private func call<Response: Decodable>(_ method: String, _ params: [String: Any]) async throws -> Response {
        let task = connected()
        let id = nextId
        nextId += 1
        let result: Result<Data, RelayError> = await withCheckedContinuation { continuation in
            pending.registerUnary(id: id) { continuation.resume(returning: $0) }
            send(["id": id, "method": method, "params": params], on: task, id: id)
        }
        return try JSONDecoder().decode(Response.self, from: result.get())
    }

    private struct Ok: Decodable {}

    func listSimulators(deviceId: String) async throws -> SimulatorList {
        try await call("ListSimulators", [:])
    }

    func setUpSimulators(deviceId: String) async throws -> SimulatorList {
        try await call("SetUpSimulators", [:])
    }

    func bootSimulator(deviceId: String, simulatorId: String) async throws {
        let _: Ok = try await call("BootSimulator", ["simulatorId": simulatorId])
    }

    func shutdownSimulator(deviceId: String, simulatorId: String) async throws {
        let _: Ok = try await call("ShutdownSimulator", ["simulatorId": simulatorId])
    }

    func simulatorScreen(deviceId: String, simulatorId: String, maxFps: Int) async throws
        -> AsyncThrowingStream<SimulatorFrame, Error> {
        let task = connected()
        let id = nextId
        nextId += 1
        let stream = pending.registerStream(id: id, as: SimulatorFrame.self) { [weak self] in
            Task { @MainActor in
                guard let self, self.pending.removeStreamForCancellation(id: id) else { return }
                self.send(["id": id, "cancel": true], on: task, id: id)
            }
        }
        send(["id": id, "method": "WatchSimulatorScreen",
              "params": ["simulatorId": simulatorId, "maxFps": maxFps]], on: task, id: id)
        return stream
    }

    func simulatorInput(deviceId: String, simulatorId: String, input: SimulatorInput) async throws {
        let _: Ok = try await call("SimulatorInput", ["simulatorId": simulatorId, "input": input.params])
    }
}
#endif
