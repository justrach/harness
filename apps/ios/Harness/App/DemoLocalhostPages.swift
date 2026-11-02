// Demo mode's localhost page: a made-up "Garden planner" a made-up dev
// server serves, drawn on the phone at the size the page view asks for, so
// the view can be explored, screenshotted and UI-tested offline. It answers
// taps (Water the tomatoes, the plant field), typing, Enter, scrolling,
// Back, and Reload the way a page would show them.

import UIKit

@MainActor
final class DemoLocalhostPages: LocalhostPageHost {
    /// What the page was sent, oldest first (UI tests read the page instead).
    private(set) var inputs: [LocalhostPageInput] = []
    private var pages: [String: DemoPage] = [:]
    private var watchers: [String: [UUID: AsyncThrowingStream<LocalhostPageEvent, Error>.Continuation]] = [:]
    private var next = 1

    let servers = [
        LocalServer(port: 5173, url: "http://localhost:5173", name: "Vite", folder: "garden-planner"),
        LocalServer(port: 8080, url: "http://localhost:8080", name: "HTTP server", folder: "seed-api"),
    ]

    func listLocalhostServers(deviceId: String) async throws -> [LocalServer] {
        try? await Task.sleep(nanoseconds: 150_000_000)  // feel like a network hop
        return servers
    }

    func watchLocalhostPage(deviceId: String, watch: LocalhostWatch) async throws
        -> AsyncThrowingStream<LocalhostPageEvent, Error> {
        guard let url = LocalhostPages.pageURL(watch.url) else {
            throw RelayError.rpc("Only pages on this computer open here (localhost or 127.0.0.1), not \(watch.url).")
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        let page: DemoPage
        if let id = watch.viewId, let existing = pages[id] {
            page = existing
        } else {
            page = DemoPage(id: "page-\(next)", url: url)
            next += 1
            pages[page.id] = page
        }
        page.size = CGSize(width: watch.width, height: watch.height)
        let (stream, continuation) = AsyncThrowingStream<LocalhostPageEvent, Error>.makeStream()
        let token = UUID()
        watchers[page.id, default: [:]][token] = continuation
        let pageId = page.id
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.watchers[pageId]?[token] = nil }
        }
        continuation.yield(.frame(page.frame()))
        return stream
    }

    func localhostPageInput(deviceId: String, viewId: String, input: LocalhostPageInput) async throws {
        guard let page = pages[viewId] else { throw RelayError.rpc("That page has closed. Open it again.") }
        inputs.append(input)
        page.apply(input)
        let frame = page.frame()
        for continuation in watchers[viewId].map({ Array($0.values) }) ?? [] {
            continuation.yield(.frame(frame))
        }
    }
}

/// A drawn stand-in for a page a dev server serves.
@MainActor
private final class DemoPage {
    let id: String
    var size = CGSize(width: 390, height: 700)
    private var history: [String]
    private var index = 0
    private var seq: UInt64 = 0
    private var watered = false
    private var plantFocused = false
    private var plant = ""
    private var plants = ["Tomatoes", "Basil", "Peppers"]
    private var scroll: CGFloat = 0
    private var notice: String?

    init(id: String, url: String) {
        self.id = id
        history = [url]
    }

    private var url: String { history[index] }
    private var onPlants: Bool { url.hasSuffix("/plants") }

    // Layout, in page points.
    private var waterButton: CGRect { CGRect(x: 20, y: 236 - scroll, width: size.width - 40, height: 52) }
    private var plantField: CGRect { CGRect(x: 20, y: 316 - scroll, width: size.width - 40, height: 48) }
    private var plantsLink: CGRect { CGRect(x: 20, y: 392 - scroll + CGFloat(plants.count) * 44, width: 160, height: 32) }

    func apply(_ input: LocalhostPageInput) {
        notice = nil
        switch input {
        case .tap(let x, let y):
            let point = CGPoint(x: x, y: y)
            plantFocused = false
            if onPlants {
                if y < 120 { back() }
            } else if waterButton.contains(point) {
                watered.toggle()
            } else if plantField.contains(point) {
                plantFocused = true
            } else if plantsLink.contains(point) {
                var plantsPage = URLComponents(string: url)
                plantsPage?.percentEncodedPath = "/plants"
                plantsPage?.query = nil
                plantsPage?.fragment = nil
                push(plantsPage?.string ?? url)
            }
        case .scroll(_, _, _, let dy):
            scroll = min(max(scroll + dy, 0), 600)
        case .text(let text):
            if plantFocused { plant += text }
        case .key("backspace"):
            if plantFocused, !plant.isEmpty { plant.removeLast() }
        case .key("enter"):
            if plantFocused, !plant.isEmpty {
                plants.append(plant)
                plant = ""
            }
        case .key:
            break
        case .navigate(let next):
            push(next)
        case .back:
            back()
        case .forward:
            if index + 1 < history.count { index += 1 }
        case .reload:
            scroll = 0
        case .resize(let width, let height, _):
            size = CGSize(width: width, height: height)
        }
    }

    private func push(_ next: String) {
        history = Array(history.prefix(index + 1)) + [next]
        index = history.count - 1
        scroll = 0
        plantFocused = false
    }

    private func back() {
        if index > 0 { index -= 1 }
    }

    func frame() -> LocalhostFrame {
        seq += 1
        let title = onPlants ? "Plants · Garden planner" : "Garden planner"
        return LocalhostFrame(viewId: id, seq: seq, jpeg: render().base64EncodedString(),
                              width: size.width, height: size.height, url: url, title: title,
                              canGoBack: index > 0, canGoForward: index + 1 < history.count,
                              loading: false, notice: notice)
    }

    private func render() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor(red: 0.97, green: 0.96, blue: 0.92, alpha: 1).setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            let green = UIColor(red: 0.18, green: 0.45, blue: 0.27, alpha: 1)
            let ink = UIColor(red: 0.13, green: 0.15, blue: 0.13, alpha: 1)
            func draw(_ text: String, _ point: CGPoint, size: CGFloat, weight: UIFont.Weight = .regular,
                      color: UIColor? = nil) {
                (text as NSString).draw(at: point, withAttributes: [
                    .font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color ?? ink,
                ])
            }
            // Header bar.
            green.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: size.width, height: 96 - min(scroll, 40)))
            draw(onPlants ? "‹ Plants" : "🌱 Garden planner", CGPoint(x: 20, y: 52 - min(scroll, 40)),
                 size: 22, weight: .bold, color: .white)
            if onPlants {
                for (i, name) in plants.enumerated() {
                    draw("• \(name)", CGPoint(x: 24, y: 130 + CGFloat(i) * 40 - scroll), size: 19)
                }
                return
            }
            draw("Spring beds", CGPoint(x: 20, y: 124 - scroll), size: 28, weight: .bold)
            draw("Bed A · 6 plants · last watered \(watered ? "just now" : "yesterday")",
                 CGPoint(x: 20, y: 166 - scroll), size: 15, color: .darkGray)
            draw("Harvest in 3 weeks", CGPoint(x: 20, y: 192 - scroll), size: 15, color: .darkGray)
            // Water button.
            (watered ? UIColor(red: 0.30, green: 0.62, blue: 0.40, alpha: 1) : green).setFill()
            UIBezierPath(roundedRect: waterButton, cornerRadius: 12).fill()
            draw(watered ? "✓ Tomatoes watered" : "Water the tomatoes",
                 CGPoint(x: waterButton.minX + 18, y: waterButton.minY + 14), size: 18, weight: .semibold,
                 color: .white)
            // Plant field.
            UIColor.white.setFill()
            let field = UIBezierPath(roundedRect: plantField, cornerRadius: 10)
            field.fill()
            (plantFocused ? green : UIColor.lightGray).setStroke()
            field.lineWidth = plantFocused ? 2 : 1
            field.stroke()
            draw(plant.isEmpty ? "Add a plant…" : plant + (plantFocused ? "|" : ""),
                 CGPoint(x: plantField.minX + 14, y: plantField.minY + 13), size: 17,
                 color: plant.isEmpty ? .gray : ink)
            for (i, name) in plants.enumerated() {
                draw("• \(name)", CGPoint(x: 24, y: 384 + CGFloat(i) * 44 - scroll), size: 18)
            }
            draw("All plants ›", CGPoint(x: plantsLink.minX, y: plantsLink.minY + 4), size: 17,
                 weight: .semibold, color: green)
            for row in 0..<6 {
                let y = plantsLink.maxY + 30 + CGFloat(row) * 120
                UIColor.white.setFill()
                UIBezierPath(roundedRect: CGRect(x: 20, y: y, width: size.width - 40, height: 100),
                             cornerRadius: 12).fill()
                draw("Bed \(["B", "C", "D", "E", "F", "G"][row])", CGPoint(x: 36, y: y + 16), size: 18,
                     weight: .semibold)
                draw("Compost due in \(row + 2) days", CGPoint(x: 36, y: y + 50), size: 15, color: .darkGray)
            }
        }
        return image.jpegData(compressionQuality: 0.7) ?? Data()
    }
}
