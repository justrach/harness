// Pages a computer serves on its own localhost (a dev server an agent
// started), opened on the phone: the computer renders the page in a headless
// browser and streams it (`WatchLocalhostPage`); taps, scrolls and typing go
// back as `LocalhostPageInput`. `ListLocalhostServers` lists what answers there.

import CoreGraphics
import Foundation
import Network

/// One frame of a page. `jpeg` is absent when only the page's state changed.
struct LocalhostFrame: Decodable, Equatable {
    var viewId: String
    var seq: UInt64
    var jpeg: String?
    /// The page's visible size in CSS pixels: what taps are measured in.
    var width: Double
    var height: Double
    var url: String
    var title: String
    var canGoBack: Bool
    var canGoForward: Bool
    var loading: Bool
    var notice: String?
}

/// An item of `WatchLocalhostPage`: a frame, or the page ending (the stream
/// finishes after it).
enum LocalhostPageEvent: Decodable, Equatable {
    case frame(LocalhostFrame)
    case ended(String)

    private enum Keys: String, CodingKey { case kind, message }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "ended":
            self = .ended(try container.decode(String.self, forKey: .message))
        default:
            self = .frame(try LocalhostFrame(from: decoder))
        }
    }
}

/// Input sent to a page. Coordinates are the page's CSS pixels.
enum LocalhostPageInput: Equatable {
    case tap(x: Double, y: Double)
    case scroll(x: Double, y: Double, dx: Double, dy: Double)
    case text(String)
    case key(String)
    case navigate(String)
    case back
    case forward
    case reload
    case resize(width: Double, height: Double, scale: Double)

    var params: [String: Any] {
        switch self {
        case .tap(let x, let y): return ["kind": "tap", "x": x, "y": y]
        case .scroll(let x, let y, let dx, let dy):
            return ["kind": "scroll", "x": x, "y": y, "dx": dx, "dy": dy]
        case .text(let text): return ["kind": "text", "text": text]
        case .key(let name): return ["kind": "key", "name": name]
        case .navigate(let url): return ["kind": "navigate", "url": url]
        case .back: return ["kind": "back"]
        case .forward: return ["kind": "forward"]
        case .reload: return ["kind": "reload"]
        case .resize(let width, let height, let scale):
            return ["kind": "resize", "width": width, "height": height, "scale": scale]
        }
    }
}

/// A server listening on a computer's loopback.
struct LocalServer: Decodable, Equatable, Identifiable, Hashable {
    var port: Int
    var url: String
    /// What it looks like (`Vite`, `Next.js`, `HTTP server`).
    var name: String
    /// The folder it runs in.
    var folder: String?

    var id: Int { port }
}

struct LocalServerList: Decodable {
    var servers: [LocalServer]
}

/// What the page view asks a computer for: its size in points, its scale, and
/// how many frames a second.
struct LocalhostWatch: Equatable {
    var url: String
    var viewId: String?
    var width: Double
    var height: Double
    var scale: Double
    var fps: Int

    var params: [String: Any] {
        var params: [String: Any] = ["url": url, "width": width, "height": height,
                                     "scale": scale, "fps": fps]
        if let viewId { params["viewId"] = viewId }
        return params
    }
}

/// Where the page view sends its calls: a computer's engine over its relay
/// (`WorkspaceStore`), or demo mode's made-up page.
@MainActor
protocol LocalhostPageHost: AnyObject {
    func watchLocalhostPage(deviceId: String, watch: LocalhostWatch) async throws
        -> AsyncThrowingStream<LocalhostPageEvent, Error>
    func localhostPageInput(deviceId: String, viewId: String, input: LocalhostPageInput) async throws
    func listLocalhostServers(deviceId: String) async throws -> [LocalServer]
}

/// A page opened from a link or the servers list.
struct LocalhostPageTarget: Identifiable, Hashable {
    var url: String
    var deviceId: String
    var deviceName: String

    var id: String { "\(deviceId)|\(url)" }
}

enum LocalhostPages {
    /// The address a computer's browser opens for `raw`, or nil when it isn't
    /// an http(s) page on that computer's loopback. Same cases as the engine:
    /// `apps/parity/vectors/localhost-pages.json`.
    static func pageURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4096 else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard var parts = URLComponents(string: withScheme),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              parts.user == nil, parts.password == nil,
              let rawHost = parts.percentEncodedHost, !rawHost.isEmpty else { return nil }
        if let port = parts.port {
            guard (1...65535).contains(port) else { return nil }
            if (scheme == "http" && port == 80) || (scheme == "https" && port == 443) { parts.port = nil }
        }
        let host = rawHost.lowercased()
        if host == "0.0.0.0" || host == "[::]" || host == "::" {
            parts.percentEncodedHost = "localhost"
        } else if isLoopbackHost(host) {
            if host != rawHost { parts.percentEncodedHost = host }
        } else {
            return nil
        }
        parts.scheme = scheme
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        return parts.string
    }

    /// `localhost`, `*.localhost`, 127.0.0.0/8 and `::1`.
    static func isLoopbackHost(_ host: String) -> Bool {
        var host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let octets = bare.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4 {
            let values = octets.map { $0.count <= 3 && $0.allSatisfy(\.isASCII) ? UInt8($0) : nil }
            return values.allSatisfy { $0 != nil } && values[0] == 127
        }
        guard bare.contains(":"), let v6 = IPv6Address(bare) else { return false }
        return v6.isLoopback || (v6.asIPv4?.isLoopback ?? false)
    }

    /// A point on the shown page (a view of `viewSize` the frame exactly
    /// fills) in the page's CSS pixels.
    static func pagePoint(_ point: CGPoint, viewSize: CGSize, page: CGSize) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let x = min(max(point.x / viewSize.width, 0), 1) * page.width
        let y = min(max(point.y / viewSize.height, 0), 1) * page.height
        return CGPoint(x: x, y: y)
    }

    /// The scroll a finger's movement makes, in page pixels: dragging up
    /// scrolls the page down.
    static func scrollDelta(_ moved: CGSize, viewSize: CGSize, page: CGSize) -> CGSize {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        return CGSize(width: -moved.width * page.width / viewSize.width,
                      height: -moved.height * page.height / viewSize.height)
    }

    /// A drag shorter than this (points) is a tap.
    static let tapSlop: CGFloat = 8

    static func isTap(_ translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) < tapSlop
    }

    /// The scale the computer renders at: the phone's own, capped at 2x
    /// (sharper isn't worth the extra bytes over the relay).
    static func renderScale(screenScale: CGFloat) -> Double {
        Double(min(max(screenScale, 1), 2))
    }

    /// How a failed call reads: an older computer, the engine's own sentence,
    /// or the relay's reason.
    static func failure(_ error: Error, deviceName: String) -> String {
        if case RelayError.rpc(let message) = error {
            if message.contains("unknown method") {
                return "Update Harness on \(deviceName) to open its pages on your phone."
            }
            return message
        }
        let reason = (error as? RelayError)?.errorDescription ?? describeTransportError(error)
        return "Couldn't reach \(deviceName): \(reason)"
    }

    /// What to send so the page's focused field follows the phone's typing
    /// field going from `old` to `new`: added text, or a Backspace per removed
    /// character (all of it retyped when the change is in the middle).
    static func typingEdits(from old: String, to new: String) -> [LocalhostPageInput] {
        if new == old { return [] }
        if new.hasPrefix(old) { return [.text(String(new.dropFirst(old.count)))] }
        if old.hasPrefix(new) {
            return Array(repeating: .key("backspace"), count: min(old.count - new.count, 500))
        }
        let shared = zip(old, new).prefix { $0 == $1 }.count
        var edits = Array(repeating: LocalhostPageInput.key("backspace"), count: min(old.count - shared, 500))
        let added = String(new.dropFirst(shared))
        if !added.isEmpty { edits.append(.text(added)) }
        return edits
    }

    /// The address bar's text: host, port and path, without `http://`.
    static func displayAddress(_ url: String) -> String {
        guard let parts = URLComponents(string: url), let host = parts.percentEncodedHost else { return url }
        var text = host
        if let port = parts.port { text += ":\(port)" }
        let path = parts.percentEncodedPath
        if path != "/" { text += path }
        if let query = parts.percentEncodedQuery { text += "?" + query }
        return text
    }
}
