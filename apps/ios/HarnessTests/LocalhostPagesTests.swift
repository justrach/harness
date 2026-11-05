// A computer's localhost page on the phone: the engine's wire shapes, how a
// touch on the shown frame maps to the page, how typing becomes input, the
// input queue's order and coalescing, how failures read, and demo mode's page.
// The loopback rule itself runs the shared vector in ParityTests.

import XCTest
@testable import Harness

@MainActor
final class LocalhostPagesTests: XCTestCase {
    func testFramesAndTheEndDecodeFromTheEnginesShape() throws {
        let frame = #"""
        {"kind":"frame","viewId":"page-1","seq":2,"jpeg":"AAA","width":390,"height":700,
         "url":"http://localhost:3000/","title":"Garden planner","canGoBack":false,
         "canGoForward":false,"loading":true}
        """#
        guard case .frame(let decoded) = try JSONDecoder().decode(LocalhostPageEvent.self, from: Data(frame.utf8))
        else { return XCTFail("a frame") }
        XCTAssertEqual(decoded.viewId, "page-1")
        XCTAssertEqual(decoded.jpeg, "AAA")
        XCTAssertEqual(decoded.width, 390)
        XCTAssertTrue(decoded.loading)
        XCTAssertNil(decoded.notice)

        let stateOnly = #"""
        {"kind":"frame","viewId":"page-1","seq":3,"width":390,"height":700,"url":"http://localhost:3000/",
         "title":"","canGoBack":true,"canGoForward":false,"loading":false,"notice":"example.com isn't on Studio."}
        """#
        guard case .frame(let next) = try JSONDecoder().decode(LocalhostPageEvent.self, from: Data(stateOnly.utf8))
        else { return XCTFail("a frame") }
        XCTAssertNil(next.jpeg, "the picture didn't change")
        XCTAssertEqual(next.notice, "example.com isn't on Studio.")

        let ended = try JSONDecoder().decode(LocalhostPageEvent.self,
                                             from: Data(#"{"kind":"ended","message":"gone"}"#.utf8))
        XCTAssertEqual(ended, .ended("gone"))
        let servers = try JSONDecoder().decode(LocalServerList.self, from: Data(#"""
        {"servers":[{"port":5173,"url":"http://localhost:5173","name":"Vite","folder":"garden"},
                    {"port":8080,"url":"http://localhost:8080","name":"HTTP server"}]}
        """#.utf8))
        XCTAssertEqual(servers.servers.map(\.port), [5173, 8080])
        XCTAssertNil(servers.servers[1].folder)
    }

    func testInputParamsMatchTheEnginesTaggedShape() {
        XCTAssertEqual(LocalhostPageInput.tap(x: 10, y: 20).params as NSDictionary,
                       ["kind": "tap", "x": 10.0, "y": 20.0])
        XCTAssertEqual(LocalhostPageInput.scroll(x: 1, y: 2, dx: 0, dy: 40).params as NSDictionary,
                       ["kind": "scroll", "x": 1.0, "y": 2.0, "dx": 0.0, "dy": 40.0])
        XCTAssertEqual(LocalhostPageInput.text("Basil").params as NSDictionary, ["kind": "text", "text": "Basil"])
        XCTAssertEqual(LocalhostPageInput.key("enter").params as NSDictionary, ["kind": "key", "name": "enter"])
        XCTAssertEqual(LocalhostPageInput.navigate("http://localhost:3000/").params as NSDictionary,
                       ["kind": "navigate", "url": "http://localhost:3000/"])
        XCTAssertEqual(LocalhostPageInput.back.params as NSDictionary, ["kind": "back"])
        XCTAssertEqual(LocalhostPageInput.resize(width: 390, height: 700, scale: 2).params as NSDictionary,
                       ["kind": "resize", "width": 390.0, "height": 700.0, "scale": 2.0])
        let watch = LocalhostWatch(url: "http://localhost:3000/", viewId: nil, width: 390, height: 700,
                                   scale: 2, fps: 15)
        XCTAssertNil(watch.params["viewId"])
        var rejoin = watch
        rejoin.viewId = "page-4"
        XCTAssertEqual(rejoin.params["viewId"] as? String, "page-4")
    }

    func testATouchOnTheShownFrameLandsOnTheSameSpotOfThePage() {
        // The frame is shown at 195×350 points for a 390×700 page.
        let view = CGSize(width: 195, height: 350)
        let page = CGSize(width: 390, height: 700)
        XCTAssertEqual(LocalhostPages.pagePoint(CGPoint(x: 97.5, y: 50), viewSize: view, page: page),
                       CGPoint(x: 195, y: 100))
        XCTAssertEqual(LocalhostPages.pagePoint(CGPoint(x: -5, y: 400), viewSize: view, page: page),
                       CGPoint(x: 0, y: 700), "clamped to the page")
        XCTAssertEqual(LocalhostPages.pagePoint(.zero, viewSize: .zero, page: page), .zero)
        // Dragging up 10 points scrolls the page down 20 of its pixels.
        XCTAssertEqual(LocalhostPages.scrollDelta(CGSize(width: 0, height: -10), viewSize: view, page: page),
                       CGSize(width: 0, height: 20))
        XCTAssertTrue(LocalhostPages.isTap(CGSize(width: 3, height: 4)))
        XCTAssertFalse(LocalhostPages.isTap(CGSize(width: 0, height: 12)))
        XCTAssertEqual(LocalhostPages.renderScale(screenScale: 3), 2)
        XCTAssertEqual(LocalhostPages.renderScale(screenScale: 1), 1)
    }

    func testTypingFollowsTheFieldWithTextAndBackspaces() {
        XCTAssertEqual(LocalhostPages.typingEdits(from: "", to: "Bas"), [.text("Bas")])
        XCTAssertEqual(LocalhostPages.typingEdits(from: "Bas", to: "Basil"), [.text("il")])
        XCTAssertEqual(LocalhostPages.typingEdits(from: "Basil", to: "Bas"),
                       [.key("backspace"), .key("backspace")])
        XCTAssertEqual(LocalhostPages.typingEdits(from: "Basil", to: "Bay"),
                       [.key("backspace"), .key("backspace"), .key("backspace"), .text("y")])
        XCTAssertEqual(LocalhostPages.typingEdits(from: "same", to: "same"), [])
    }

    func testTheAddressBarShowsHostPortAndPath() {
        XCTAssertEqual(LocalhostPages.displayAddress("http://localhost:3000/"), "localhost:3000")
        XCTAssertEqual(LocalhostPages.displayAddress("http://localhost:5173/plots?bed=a"), "localhost:5173/plots?bed=a")
        XCTAssertEqual(LocalhostPages.displayAddress("https://127.0.0.1/"), "127.0.0.1")
    }

    func testInputGoesInOrderWaitingScrollsAddUpAndResizesReplace() async {
        let queue = LocalhostInputQueue()
        queue.viewId = "page-1"
        var sent: [LocalhostPageInput] = []
        let gate = AsyncStream<Void>.makeStream()
        var first = true
        queue.send = { viewId, event in
            XCTAssertEqual(viewId, "page-1")
            sent.append(event)
            if first {
                first = false
                for await _ in gate.stream { break }
            }
        }
        queue.enqueue(.tap(x: 1, y: 1))
        await Task.yield()
        queue.enqueue(.scroll(x: 5, y: 5, dx: 0, dy: 10))
        queue.enqueue(.scroll(x: 6, y: 6, dx: 2, dy: 30))
        queue.enqueue(.resize(width: 300, height: 600, scale: 2))
        queue.enqueue(.resize(width: 390, height: 700, scale: 2))
        queue.enqueue(.text("a"))
        gate.continuation.yield()
        for _ in 0..<50 where sent.count < 4 { await Task.yield() }
        XCTAssertEqual(sent, [.tap(x: 1, y: 1), .scroll(x: 6, y: 6, dx: 2, dy: 40),
                              .resize(width: 390, height: 700, scale: 2), .text("a")])
    }

    func testFailuresSayWhatToDo() {
        XCTAssertEqual(LocalhostPages.failure(RelayError.rpc("unknown method: WatchLocalhostPage"), deviceName: "Studio"),
                       "Update Harness on Studio to open its pages on your phone.")
        let noBrowser = "Viewing localhost on your phone needs Google Chrome, Microsoft Edge, Brave or Chromium on Studio."
        XCTAssertEqual(LocalhostPages.failure(RelayError.rpc(noBrowser), deviceName: "Studio"), noBrowser)
        XCTAssertEqual(LocalhostPages.failure(RelayError.hostOffline, deviceName: "Studio"),
                       "Couldn't reach Studio: The device is offline")
    }

    func testOnlyLoopbackLinksOfferToOpenOnThePhone() throws {
        func link(_ raw: String) -> HostLink? { HostLink.classify(URL(string: raw)!, cwd: nil) }
        XCTAssertEqual(link("http://0.0.0.0:3000/docs")?.pageURL, "http://localhost:3000/docs")
        XCTAssertEqual(link("http://127.0.0.1:3777/md")?.pageURL, "http://127.0.0.1:3777/md")
        XCTAssertNil(link("/Users/me/notes.md")?.pageURL, "a file isn't a page")
        XCTAssertNil(link("http://127.0.0.1.example.com/"), "a public name that starts with 127. stays a web link")
    }

    func testDemoPageAnswersTapsTypingAndHistory() async throws {
        let host = DemoLocalhostPages()
        let servers = try await host.listLocalhostServers(deviceId: "mac")
        XCTAssertEqual(servers.first?.port, 5173)
        let stream = try await host.watchLocalhostPage(
            deviceId: "mac", watch: LocalhostWatch(url: "localhost:5173", viewId: nil, width: 390, height: 700,
                                                   scale: 2, fps: 15))
        var frames = stream.makeAsyncIterator()
        guard case .frame(let first)? = try await frames.next() else { return XCTFail("a frame") }
        XCTAssertEqual(first.url, "http://localhost:5173/")
        XCTAssertEqual(first.title, "Garden planner")
        XCTAssertNotNil(first.jpeg.flatMap { Data(base64Encoded: $0) }.flatMap(UIImage.init(data:)))
        XCTAssertFalse(first.canGoBack)

        try await host.localhostPageInput(deviceId: "mac", viewId: first.viewId, input: .tap(x: 195, y: 260))
        guard case .frame(let watered)? = try await frames.next() else { return XCTFail("a frame") }
        XCTAssertNotEqual(watered.jpeg, first.jpeg, "the button changed the page")

        try await host.localhostPageInput(deviceId: "mac", viewId: first.viewId,
                                          input: .navigate("http://localhost:5173/plants"))
        guard case .frame(let plants)? = try await frames.next() else { return XCTFail("a frame") }
        XCTAssertTrue(plants.canGoBack)
        XCTAssertEqual(plants.title, "Plants · Garden planner")
        do {
            _ = try await host.watchLocalhostPage(
                deviceId: "mac", watch: LocalhostWatch(url: "https://example.com", viewId: nil, width: 390,
                                                       height: 700, scale: 2, fps: 15))
            XCTFail("an address off the computer is refused")
        } catch RelayError.rpc(let message) {
            XCTAssertTrue(message.contains("Only pages on this computer"), message)
        }
    }
}
