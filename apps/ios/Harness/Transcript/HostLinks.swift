// Links in agent replies that only make sense on the chat's host computer:
// file paths (POSIX, Windows drives, file://, workspace-relative) and loopback
// web servers (`http://localhost:5173`). Handing those to the system does
// nothing on a phone, so the transcript opens a sheet instead: it names the
// host, previews images the host is willing to serve, and copies the target.

import SwiftUI

struct HostLink: Identifiable, Hashable {
    enum Kind: Hashable {
        /// A path on the host's disk, as the agent wrote it.
        case file(path: String)
        /// A web page served from the host's own loopback interface.
        case loopback(URL)
    }

    let kind: Kind
    /// Absolute POSIX path to try reading an image from, when there is one.
    var imagePath: String? = nil

    var id: String {
        switch kind {
        case .file(let path): return "file:\(path)"
        case .loopback(let url): return "web:\(url.absoluteString)"
        }
    }

    /// What Copy puts on the pasteboard.
    var copyText: String {
        switch kind {
        case .file(let path): return path
        case .loopback(let url): return url.absoluteString
        }
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    private static let webSchemes: Set<String> = ["http", "https"]

    /// nil for links the system should open (web pages, mail, the app's own
    /// `harness://` links). `cwd` resolves workspace-relative paths.
    static func classify(_ url: URL, cwd: String?) -> HostLink? {
        let scheme = url.scheme?.lowercased()
        if let scheme, webSchemes.contains(scheme) {
            guard let host = url.host(percentEncoded: false), isLoopback(host) else { return nil }
            return HostLink(kind: .loopback(url))
        }
        let path: String
        if scheme == "file" {
            path = url.path(percentEncoded: false)
        } else if scheme == nil || scheme?.count == 1 {
            // No scheme: a POSIX or relative path. One letter: a Windows
            // drive (`C:/…`, `I:\…`), which URL parses as a scheme.
            guard let raw = url.absoluteString.removingPercentEncoding else { return nil }
            path = stripLineSuffix(stripFragment(raw))
        } else {
            return nil
        }
        guard !path.isEmpty else { return nil }
        return HostLink(kind: .file(path: path), imagePath: imageReadPath(path, cwd: cwd))
    }

    static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host.hasSuffix(".localhost")
            || host == "0.0.0.0" || host == "::1" || host.hasPrefix("127.")
    }

    /// The POSIX path to read an image preview from: absolute paths as-is,
    /// relative ones under the chat's folder. Windows paths and non-images
    /// get no preview.
    private static func imageReadPath(_ path: String, cwd: String?) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard imageExtensions.contains(ext), !path.contains("\\") else { return nil }
        if path.hasPrefix("/") { return path }
        if path.count > 1, path.dropFirst().first == ":" { return nil }  // drive letter
        guard let cwd, cwd.hasPrefix("/") else { return nil }
        let relative = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        return (cwd as NSString).appendingPathComponent(relative)
    }

    private static func stripFragment(_ raw: String) -> String {
        guard let hash = raw.firstIndex(of: "#") else { return raw }
        return String(raw[..<hash])
    }

    /// `src/main.rs:42` / `:42:7` — the location, not part of the file name.
    private static func stripLineSuffix(_ path: String) -> String {
        var trimmed = path
        for _ in 0..<2 {
            guard let colon = trimmed.lastIndex(of: ":"),
                  colon != trimmed.index(after: trimmed.startIndex),  // `C:`
                  !trimmed[trimmed.index(after: colon)...].isEmpty,
                  trimmed[trimmed.index(after: colon)...].allSatisfy(\.isNumber) else { break }
            trimmed = String(trimmed[..<colon])
        }
        return trimmed
    }
}

struct HostLinkSheet: View {
    let link: HostLink
    let deviceId: String
    let deviceName: String

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var title: String {
        switch link.kind {
        case .file: return "File on \(deviceName)"
        case .loopback: return "Page on \(deviceName)"
        }
    }

    private var explanation: String {
        switch link.kind {
        case .file:
            return "This link points at a file on \(deviceName), so your phone can't open it. "
                + "Open it on that computer, or copy the path."
        case .loopback:
            return "This page is served by \(deviceName) itself and only opens in a browser on that computer."
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(explanation)
                        .font(Theme.sans(15))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(link.copyText)
                        .font(Theme.mono(13))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ink(0.035), in: RoundedRectangle(cornerRadius: Theme.panelRadius))
                        .accessibilityIdentifier("host-link-target")
                    if let path = link.imagePath, !deviceId.isEmpty {
                        HostImagePreview(deviceId: deviceId, path: path)
                    }
                    Button {
                        UIPasteboard.general.string = link.copyText
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : (isFile ? "Copy path" : "Copy link"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("host-link-copy")
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .harnessAppearance()
    }

    private var isFile: Bool {
        if case .file = link.kind { return true }
        return false
    }
}

/// An image a link points at, read over the host's relay. The host only
/// serves its uploads folder and its chats' folders; anything else reports
/// unavailable instead of spinning.
private struct HostImagePreview: View {
    let deviceId: String
    let path: String

    private let cache = AttachmentImageCache.shared
    @State private var preview: AttachmentPreview?

    var body: some View {
        Group {
            switch cache.snapshot(deviceId: deviceId, path: path) {
            case .loaded(let name, let image):
                Button {
                    preview = AttachmentPreview(name: name, image: image)
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .frame(maxHeight: 320)
                }
                .buttonStyle(.plain)
                .contextMenu { ImageActionsMenu(name: name, image: image) }
                .accessibilityLabel("Preview image")
            case .loading:
                ProgressView()
                    .tint(Theme.textFaint)
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
            case .error:
                Label("\((path as NSString).lastPathComponent) isn't available to preview",
                      systemImage: "photo.badge.exclamationmark")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity)
                    .frame(height: 80)
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: "\(deviceId)|\(path)") { cache.load(deviceId: deviceId, path: path) }
        .fullScreenCover(item: $preview) { AttachmentLightbox(preview: $0) }
    }
}
