import SwiftUI

/// Pure rules for the session header's folder + host subtitle (`~/harness @ MacBook Pro`).
enum SessionFolderLocation: Equatable {
    struct Resolved: Equatable {
        let label: String
        let device: String
        /// Project sessions tint the folder path with the space's color; plain chats and
        /// projectless sessions stay muted.
        let spaceId: String?

        var plainText: String { "\(label) @ \(device)" }
    }

    /// Shortens macOS (`/Users/<u>`), Linux (`/home/<u>`), and Windows (`C:\Users\<u>`)
    /// home prefixes to `~` so the working folder fits cleanly in a mobile header.
    static func abbreviatePath(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        if trimmed == "~" || trimmed == "~/" || trimmed == "~\\" {
            return "~"
        }
        if trimmed.hasPrefix("~/") {
            let rest = trimmed.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return rest.isEmpty ? "~" : "~/\(rest)"
        }
        if trimmed.hasPrefix("~\\") {
            let rest = trimmed.dropFirst(2)
                .replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return rest.isEmpty ? "~" : "~/\(rest)"
        }

        // Windows home paths: C:\Users\<name>\... or C:/Users/<name>/...
        if trimmed.count >= 9 {
            let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
            let chars = Array(normalized)
            if chars.count >= 9,
               chars[0].isLetter,
               chars[1] == ":",
               String(chars[2..<9]).caseInsensitiveCompare("/Users/") == .orderedSame {
                let afterUsers = String(chars.dropFirst(9))
                return collapseAfterHomeRoot(afterUsers)
            }
        }

        // Unix home paths: /Users/<name>/... or /home/<name>/...
        for prefix in ["/Users/", "/home/"] where trimmed.hasPrefix(prefix) {
            let afterRoot = String(trimmed.dropFirst(prefix.count))
            if let abbreviated = collapseAfterHomeRoot(afterRoot) {
                return abbreviated
            }
        }

        if trimmed.count > 1, trimmed.hasSuffix("/") {
            var copy = trimmed
            while copy.count > 1 && copy.hasSuffix("/") {
                copy.removeLast()
            }
            return copy
        }
        return trimmed
    }

    private static func collapseAfterHomeRoot(_ afterRoot: String) -> String? {
        let trimmed = afterRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        guard let slash = trimmed.firstIndex(of: "/") else {
            return "~"
        }
        let subpath = trimmed[trimmed.index(after: slash)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return subpath.isEmpty ? "~" : "~/\(subpath)"
    }

    static func resolve(cwd: String?, spaceId: String?, spacePath: String?,
                        spaceName: String?, isChatMode: Bool, device: String) -> Resolved {
        guard let spaceId else {
            if isChatMode {
                return Resolved(label: "Chat", device: device, spaceId: nil)
            }
            let folder = abbreviatePath(cwd) ?? "No project"
            return Resolved(label: folder, device: device, spaceId: nil)
        }
        let cleanSpaceName = spaceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = abbreviatePath(cwd)
            ?? abbreviatePath(spacePath)
            ?? ((cleanSpaceName?.isEmpty == false) ? cleanSpaceName! : "?")
        return Resolved(label: folder, device: device, spaceId: spaceId)
    }
}

@MainActor
func sessionHeaderLocation(chat: Chat, model: AppModel) -> Text {
    let space = model.space(for: chat)
    let resolved = SessionFolderLocation.resolve(
        cwd: chat.cwd,
        spaceId: chat.spaceId,
        spacePath: space?.path,
        spaceName: space?.displayName,
        isChatMode: chat.config?.isChatMode == true,
        device: model.deviceName(chat.deviceId)
    )
    guard let spaceId = resolved.spaceId else {
        return Text(resolved.plainText)
    }
    return Text("\(Text(resolved.label).foregroundStyle(Theme.projectTint(spaceId))) @ \(resolved.device)")
}
