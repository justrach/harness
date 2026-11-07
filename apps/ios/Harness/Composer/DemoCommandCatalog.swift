import Foundation

/// Offline simulator data captured from graff's ACP available_commands_update
/// in an empty synthetic workspace. Live chats always use the host's
/// ListCommands response, including workspace-specific commands and skills.
enum DemoCommandCatalog {
    private struct Snapshot: Decodable {
        let harness: String
        let version: String
        let commands: [ComposerCommand]
    }

    static func graff() throws -> [ComposerCommand] {
        guard let url = Bundle.main.url(forResource: "demo-graff-commands", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        guard snapshot.harness == "graff", !snapshot.version.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return snapshot.commands
    }
}
