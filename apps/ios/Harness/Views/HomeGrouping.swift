// Home list grouping: the session list split into sections by project or by
// device. The list is recency-ordered (pins first); grouping keeps that order
// inside each section and places a section where its newest session sits. Pinned
// sessions leave their sections and gather in a "Pinned" section above them all,
// so a pin is never buried inside a group.

import SwiftUI

enum HomeGroupBy: String, CaseIterable, Identifiable {
    case none, project, device

    static let storageKey = "homeGroupBy"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .project: return "Project"
        case .device: return "Device"
        }
    }

    var symbol: String {
        switch self {
        case .none: return "list.bullet"
        case .project: return "folder"
        case .device: return "laptopcomputer"
        }
    }
}

struct HomeGroup: Identifiable, Equatable {
    enum Kind: Equatable {
        case all
        /// Pinned sessions, gathered above every project or device section.
        case pinned
        /// nil: sessions without a project.
        case project(spaceId: String?)
        case device(deviceId: String)
    }

    var id: String
    var kind: Kind
    var chats: [Chat]
}

enum HomeGrouping {
    static func groups(_ chats: [Chat], by grouping: HomeGroupBy,
                       pinned: Set<String> = []) -> [HomeGroup] {
        guard grouping != .none else {
            return [HomeGroup(id: "all", kind: .all, chats: chats)]
        }
        let pins = chats.filter { pinned.contains($0.id) }
        guard !pins.isEmpty else { return sections(chats, by: grouping) }
        return [HomeGroup(id: "pinned", kind: .pinned, chats: pins)]
            + sections(chats.filter { !pinned.contains($0.id) }, by: grouping)
    }

    private static func sections(_ chats: [Chat], by grouping: HomeGroupBy) -> [HomeGroup] {
        switch grouping {
        case .none:
            return [HomeGroup(id: "all", kind: .all, chats: chats)]
        case .project:
            let buckets = ordered(chats) { $0.spaceId ?? "" }
            // Projectless sessions collect at the end rather than splitting
            // the projects up.
            return (buckets.filter { !$0.key.isEmpty } + buckets.filter { $0.key.isEmpty }).map {
                HomeGroup(id: "project:\($0.key)",
                          kind: .project(spaceId: $0.key.isEmpty ? nil : $0.key),
                          chats: $0.chats)
            }
        case .device:
            return ordered(chats) { $0.deviceId }.map {
                HomeGroup(id: "device:\($0.key)", kind: .device(deviceId: $0.key), chats: $0.chats)
            }
        }
    }

    /// Buckets in order of first appearance, members in list order.
    private static func ordered(_ chats: [Chat], key: (Chat) -> String) -> [(key: String, chats: [Chat])] {
        var order: [String] = []
        var buckets: [String: [Chat]] = [:]
        for chat in chats {
            let bucket = key(chat)
            if buckets[bucket] == nil { order.append(bucket) }
            buckets[bucket, default: []].append(chat)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}

/// A section header: the project's color dot or the device's online dot, the
/// name, the session count, and a chevron that collapses the section.
struct HomeGroupHeader: View {
    @Environment(AppModel.self) private var model
    let group: HomeGroup
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                marker
                Text(title)
                    .font(Theme.sans(13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text("\(group.chats.count)")
                    .font(Theme.sans(12, weight: .medium))
                    .foregroundStyle(Theme.textFaint)
                    .monospacedDigit()
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textFaint)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(group.chats.count) sessions")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .accessibilityIdentifier("home-group-\(group.id)")
    }

    private var title: String {
        switch group.kind {
        case .all: return "All"
        case .pinned: return "Pinned"
        case .project(let spaceId?):
            return model.spaces.first { $0.id == spaceId }?.displayName
                ?? group.chats.first?.cwd.map { ($0 as NSString).lastPathComponent }
                ?? "Project"
        case .project(nil): return "No project"
        case .device(let deviceId): return model.deviceName(deviceId)
        }
    }

    @ViewBuilder private var marker: some View {
        switch group.kind {
        case .pinned:
            Image(systemName: "pin.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textMuted)
        case .project(let spaceId?):
            Circle().fill(Theme.projectTint(spaceId)).frame(width: 8, height: 8)
        case .device(let deviceId):
            Image(systemName: deviceSymbol(deviceId))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(model.deviceOnline(deviceId) ? Theme.statusCompleted : Theme.textFaint)
                        .frame(width: 6, height: 6)
                        .offset(x: 3, y: 2)
                }
        default:
            Circle().strokeBorder(Theme.textFaint, lineWidth: 1.5).frame(width: 8, height: 8)
        }
    }

    private func deviceSymbol(_ deviceId: String) -> String {
        switch model.devices.first(where: { $0.id == deviceId })?.platform {
        case "linux": return "server.rack"
        case "windows": return "pc"
        case "ios": return "iphone"
        default: return "laptopcomputer"
        }
    }
}
