import Foundation

/// A draft always names either a real project or an explicit execution host.
/// A missing project never silently becomes a projectless session.
enum NewSessionDestination: Hashable {
    case project(spaceId: String)
    case projectless(deviceId: String)

    /// Names this destination for the draft kept while its composer is away.
    var draftKey: String {
        switch self {
        case .project(let id): return "project:\(id)"
        case .projectless(let id): return "projectless:\(id)"
        }
    }

    func space(in spaces: [Space]) -> Space? {
        guard case .project(let id) = self else { return nil }
        return spaces.first { $0.id == id }
    }

    func deviceId(spaces: [Space], devices: [DeviceRow]) -> String? {
        switch self {
        case .project:
            return space(in: spaces)?.deviceId
        case .projectless(let id):
            // Offline hosts remain selectable: delivery is durable. iOS is
            // a viewer, so it can never be the execution target.
            return devices.first { $0.id == id && $0.canHostSessions }?.id
        }
    }
}

extension DeviceRow {
    var canHostSessions: Bool { platform != "ios" && !id.isEmpty }
}
