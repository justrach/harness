import Loro
import SwiftUI
import UIKit
import XCTest
@testable import Harness

@MainActor
final class VisualRuntimeTests: XCTestCase {
    private static let dashboardScript = """
    local count = 3
    return function()
        return ui.column{
            ui.text('Rollout scenario'),
            ui.row{
                ui.stat{ label='Iterations', value=count },
                ui.stat{ label='Target', value='99.9%' },
            },
            ui.chart{
                label='Throughput',
                values={12, 24, 36},
                labels={'Current', 'Growth', 'Peak'},
            },
            ui.button{
                label='Step',
                onClick=function() count = count + 1 end,
            },
        }
    end
    """

    private static let demoScript = """
    local traffic = 50
    local efficient = true
    local saved = 0
    return function()
        local cost = math.floor(traffic * (efficient and 0.72 or 1.0))
        return ui.column{
            ui.text('Illustrative capacity scenario — not a benchmark'),
            ui.row{
                ui.stat{ label='Baseline', value=tostring(traffic) .. ' rps' },
                ui.stat{ label='Est. cost', value='$' .. tostring(cost) .. '/mo' },
                ui.stat{ label='Saved', value=saved },
            },
            ui.chart{
                label='Requests per second',
                values={traffic, traffic * 1.5, traffic * 2, traffic * 2.4},
                labels={'Current', 'Growth', 'Peak', 'Burst'},
            },
            ui.slider{
                label='Capacity', value=traffic, min=10, max=200,
                onChange=function(v) traffic = math.floor(v + 0.5) end,
            },
            ui.row{
                ui.toggle{
                    label='Efficiency mode', value=efficient,
                    onChange=function(on) efficient = on end,
                },
                ui.button{
                    label='Save scenario',
                    onClick=function() saved = saved + 1 end,
                },
            },
        }
    end
    """

    func testDashboardAndStatefulButton() throws {
        let sb = try VisualSandbox(source: Self.dashboardScript)
        let first = try sb.render()
        guard case .column(let children) = first else {
            return XCTFail("Expected column root")
        }
        guard case .row(let stats) = children[1],
              case .stat(let firstStat) = stats[0] else {
            return XCTFail("Expected stat inside row")
        }
        XCTAssertEqual(firstStat, "Iterations: 3")
        guard case .button(_, let handlerId) = children[3], let hid = handlerId else {
            return XCTFail("Expected button handler")
        }

        let next = try sb.call(handlerId: hid, input: .click)
        guard case .column(let nextChildren) = next,
              case .row(let nextStats) = nextChildren[1],
              case .stat(let nextStat) = nextStats[0] else {
            return XCTFail("Expected updated stat")
        }
        XCTAssertEqual(nextStat, "Iterations: 4")

        XCTAssertThrowsError(try sb.call(handlerId: hid, input: .click)) { err in
            XCTAssertTrue(err.localizedDescription.contains("stale"))
        }
    }

    func testInteractiveControlsAndLocalGlobals() throws {
        let script = """
        local n = 10
        private_value = 7
        return function()
            return ui.column{
                ui.text(tostring(n + private_value)),
                ui.toggle{ label='Flag', value=true, onChange=function(b) n = b and 20 or 5 end },
                ui.slider{ label='Scale', value=n, min=0, max=100, onChange=function(v) n = v end },
            }
        end
        """
        let sb = try VisualSandbox(source: script)
        let r1 = try sb.render()
        guard case .column(let c1) = r1,
              case .text(let t1) = c1[0],
              case .toggle(_, let tVal, let thid) = c1[1],
              case .slider(_, let sVal, _, _, _) = c1[2],
              let toggleId = thid else {
            return XCTFail("Unexpected tree shape")
        }
        XCTAssertEqual(t1, "17")
        XCTAssertTrue(tVal)
        XCTAssertEqual(sVal, 10)

        let r2 = try sb.call(handlerId: toggleId, input: .boolean(false))
        guard case .column(let c2) = r2,
              case .text(let t2) = c2[0],
              case .slider(_, _, _, _, let shid) = c2[2],
              let sliderId = shid else {
            return XCTFail("Unexpected tree after toggle")
        }
        XCTAssertEqual(t2, "12")

        let r3 = try sb.call(handlerId: sliderId, input: .number(42))
        guard case .column(let c3) = r3, case .text(let t3) = c3[0] else {
            return XCTFail("Unexpected tree after slider")
        }
        XCTAssertEqual(t3, "49")
    }

    func testStdlibIsFrozenAndGlobalsBlocked() {
        XCTAssertThrowsError(try VisualSandbox(source: "math.sin = function() return 0 end; return function() return ui.text('ok') end"))
        XCTAssertThrowsError(try VisualSandbox(source: "return function() require('os'); return ui.text('ok') end").render())
        XCTAssertThrowsError(try VisualSandbox(source: "return 123"))
        XCTAssertThrowsError(try VisualSandbox(source: "return function() return 123 end").render())
    }

    func testSourceMemoryAndDeadlineLimits() {
        let oversized = String(repeating: "a", count: VisualLimits.maxSourceBytes + 1)
        XCTAssertThrowsError(try VisualSandbox(source: oversized)) { err in
            XCTAssertTrue(err.localizedDescription.contains("64 KiB"))
        }

        let memHog = """
        return function()
            local t = {}
            for i = 1, 2000000 do t[i] = string.rep('x', 128) end
            return ui.text('ok')
        end
        """
        XCTAssertThrowsError(try VisualSandbox(source: memHog).render())

        let infLoop = "return function() while true do end end"
        XCTAssertThrowsError(try VisualSandbox(source: infLoop).render()) { err in
            XCTAssertTrue(err.localizedDescription.contains("20 ms"))
        }

        let pcallLoop = "return function() while true do pcall(function() while true do end end) end end"
        XCTAssertThrowsError(try VisualSandbox(source: pcallLoop).render()) { err in
            XCTAssertTrue(err.localizedDescription.contains("20 ms"))
        }
    }

    func testTreeValidationCaps() {
        XCTAssertThrowsError(try VisualSandbox(source: "return function() return ui.text({ text='x', color='red' }) end").render())
        XCTAssertThrowsError(try VisualSandbox(source: "return function() return ui.chart{ values={1, 0/0} } end").render())
        XCTAssertThrowsError(try VisualSandbox(source: "return function() return ui.column{ [2]=ui.text('hole') } end").render())

        let tooDeep = """
        return function()
            local n = ui.text('leaf')
            for i = 1, 30 do n = ui.column{ n } end
            return n
        end
        """
        XCTAssertThrowsError(try VisualSandbox(source: tooDeep).render())

        let tooManyNodes = """
        return function()
            local children = {}
            for i = 1, 520 do children[i] = ui.text('x') end
            return ui.column(children)
        end
        """
        XCTAssertThrowsError(try VisualSandbox(source: tooManyNodes).render())

        let tooMuchText = """
        return function()
            return ui.text(string.rep('a', 9000))
        end
        """
        XCTAssertThrowsError(try VisualSandbox(source: tooMuchText).render())
    }

    func testSessionStoreDecodesVisualPart() {
        let valid = LoroValue.fromJSON([
            "id": "v1",
            "kind": "visual",
            "title": "Capacity plan",
            "script": Self.dashboardScript,
        ])
        XCTAssertEqual(
            SessionStore.partFrom(valid),
            .visual(id: "v1", title: "Capacity plan", script: Self.dashboardScript)
        )

        let blankTitle = LoroValue.fromJSON([
            "id": "v2",
            "kind": "visual",
            "title": "   ",
            "script": Self.dashboardScript,
        ])
        XCTAssertNil(SessionStore.partFrom(blankTitle))
    }

    func testSnapshotDemoCardIfRequested() throws {
        guard let snapDir = ProcessInfo.processInfo.environment["IOS_VISUAL_SNAP_DIR"], !snapDir.isEmpty else {
            return
        }
        let cache = VisualCache()
        cache.ensureLoaded(partKey: "snap-demo", title: "Capacity Planner", script: Self.demoScript)

        let exp = expectation(description: "visual ready")
        Task {
            for _ in 0..<100 {
                if let e = cache.entry(for: "snap-demo"), case .ready = e.state {
                    exp.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        wait(for: [exp], timeout: 2.0)

        let card = VisualCardView(partKey: "snap-demo", title: "Capacity Planner", script: Self.demoScript, cache: cache)
            .padding(16)
            .background(Theme.bg)
            .environment(\.colorScheme, ThemeStore.shared.colorScheme)

        let controller = UIHostingController(rootView: card)
        controller.overrideUserInterfaceStyle = .dark
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 515)
        controller.view.layoutIfNeeded()

        let renderer = UIGraphicsImageRenderer(bounds: controller.view.bounds)
        let image = renderer.image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let dirURL = URL(fileURLWithPath: snapDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let png = try XCTUnwrap(image.pngData())
        try png.write(to: dirURL.appendingPathComponent("ios-visual-demo.png"))
    }
}
