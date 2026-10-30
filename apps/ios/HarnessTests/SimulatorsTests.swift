// Settings → Simulators: the engine's wire shapes, which computers are offered,
// the per-network frame rate, how failures read, the input queue's ordering and
// coalescing, and demo mode's made-up Mac.

import XCTest
@testable import Harness

@MainActor
final class SimulatorsTests: XCTestCase {
    func testTheEnginesListDecodes() throws {
        let json = #"""
        {"supported":true,"reason":null,"setUp":false,"devices":[
          {"id":"6BBA9FD8-EFAD-45B7-B9FC-30715804D2A1","name":"iPhone 17","runtime":"iOS 27.0","booted":true}]}
        """#
        let list = try JSONDecoder().decode(SimulatorList.self, from: Data(json.utf8))
        XCTAssertTrue(list.supported)
        XCTAssertFalse(list.setUp)
        XCTAssertEqual(list.devices.map(\.name), ["iPhone 17"])
        let frame = try JSONDecoder().decode(SimulatorFrame.self, from: Data(#"{"seq":7,"jpeg":"AAEC"}"#.utf8))
        XCTAssertEqual(frame.seq, 7)
    }

    func testInputParamsMatchTheEnginesTaggedShape() {
        XCTAssertEqual(SimulatorInput.touch(.move, x: 0.5, y: 0.25).params as NSDictionary,
                       ["kind": "touch", "phase": "move", "x": 0.5, "y": 0.25])
        XCTAssertEqual(SimulatorInput.button(.volumeUp).params as NSDictionary,
                       ["kind": "button", "button": "volumeUp"])
        XCTAssertEqual(SimulatorInput.text("hi").params as NSDictionary, ["kind": "text", "text": "hi"])
        XCTAssertEqual(SimulatorInput.key("enter").params as NSDictionary, ["kind": "key", "key": "enter"])
    }

    func testOnlyMacsAreOfferedOnlineFirst() {
        let devices = [
            DeviceRow(id: "linux", name: "Cloud box", platform: "linux"),
            DeviceRow(id: "mac-off", name: "Studio", platform: "macos"),
            DeviceRow(id: "phone", name: "iPhone", platform: "ios"),
            DeviceRow(id: "mac-on", name: "Laptop", platform: "macos"),
            DeviceRow(id: "win", name: "Desktop", platform: "windows"),
        ]
        let macs = SimulatorHosts.macs(devices) { $0 == "mac-on" || $0 == "linux" }
        XCTAssertEqual(macs.map(\.id), ["mac-on", "mac-off"])
        XCTAssertTrue(SimulatorHosts.macs(devices.filter { $0.platform != "macos" }) { _ in true }.isEmpty)
    }

    func testMeteredNetworksGetFewerFrames() {
        XCTAssertEqual(SimulatorStreamRate.fps(expensive: false, constrained: false), 15)
        XCTAssertEqual(SimulatorStreamRate.fps(expensive: true, constrained: false), 6)
        XCTAssertEqual(SimulatorStreamRate.fps(expensive: false, constrained: true), 6)
    }

    func testFailuresSayWhatToDo() {
        XCTAssertEqual(SimulatorHosts.failure(RelayError.rpc("unknown method: ListSimulators"), deviceName: "Laptop"),
                       "Update Harness on Laptop to use its simulators from your phone.")
        XCTAssertEqual(SimulatorHosts.failure(RelayError.rpc("Node.js wasn't found on this computer."),
                                              deviceName: "Laptop"),
                       "Node.js wasn't found on this computer.")
        XCTAssertEqual(SimulatorHosts.failure(RelayError.hostOffline, deviceName: "Laptop"),
                       "Couldn't reach Laptop: The device is offline")
    }

    func testInputGoesInOrderAndWaitingMovesCoalesce() async {
        let queue = InputQueue()
        var sent: [SimulatorInput] = []
        let gate = AsyncStream<Void>.makeStream()
        var first = true
        queue.send = { event in
            sent.append(event)
            if first {
                first = false
                // Hold the first send so the rest queue up behind it.
                for await _ in gate.stream { break }
            }
        }
        queue.enqueue(.touch(.begin, x: 0.1, y: 0.1))
        await Task.yield()
        queue.enqueue(.touch(.move, x: 0.2, y: 0.2))
        queue.enqueue(.touch(.move, x: 0.3, y: 0.3))
        queue.enqueue(.touch(.move, x: 0.4, y: 0.4))
        queue.enqueue(.touch(.end, x: 0.4, y: 0.4))
        queue.enqueue(.button(.home))
        gate.continuation.yield()
        for _ in 0..<100 where sent.count < 4 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(sent, [
            .touch(.begin, x: 0.1, y: 0.1),
            .touch(.move, x: 0.4, y: 0.4),
            .touch(.end, x: 0.4, y: 0.4),
            .button(.home),
        ])
    }

    func testDemoMacSetsUpBootsStreamsAndTakesInput() async throws {
        let demo = DemoSimulators(setUp: false)
        var list = try await demo.listSimulators(deviceId: "dev-mac")
        XCTAssertFalse(list.setUp)
        list = try await demo.setUpSimulators(deviceId: "dev-mac")
        XCTAssertTrue(list.setUp)
        let off = try XCTUnwrap(list.devices.first { !$0.booted })
        do {
            _ = try await demo.simulatorScreen(deviceId: "dev-mac", simulatorId: off.id, maxFps: 15)
            XCTFail("an off simulator has no screen")
        } catch {}
        try await demo.bootSimulator(deviceId: "dev-mac", simulatorId: off.id)
        var frames = try await demo.simulatorScreen(deviceId: "dev-mac", simulatorId: off.id, maxFps: 15)
            .makeAsyncIterator()
        let first = try await frames.next()
        XCTAssertNotNil(first.flatMap { Data(base64Encoded: $0.jpeg) }.flatMap(UIImage.init(data:)))
        try await demo.simulatorInput(deviceId: "dev-mac", simulatorId: off.id, input: .text("hi"))
        let second = try await frames.next()
        XCTAssertGreaterThan(second?.seq ?? 0, first?.seq ?? 0)
        XCTAssertEqual(demo.inputs[off.id], [.text("hi")])
        try await demo.shutdownSimulator(deviceId: "dev-mac", simulatorId: off.id)
        let ended = try await frames.next()
        XCTAssertNil(ended, "shutting down ends the screen")
    }
}
