import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Shared by the session's drop surface and its composer. Drops only stage
/// attachments; the existing send/upload path remains the sole sender.
@MainActor
@Observable
final class AttachmentDraft {
    var items: [StagedAttachment] = []
    var error: String?
    var loading = false
    var enabled = false
    var targeted = false

    var canImport: Bool { enabled && !loading }

    static func supports(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            || provider.canLoadObject(ofClass: UIImage.self)
    }

    @discardableResult
    func receive(_ providers: [NSItemProvider]) -> Bool {
        let images = providers.filter(Self.supports)
        guard canImport, !images.isEmpty else { return false }
        loading = true
        error = nil
        Task {
            defer { loading = false }
            var failed = 0
            // Sequential loads preserve the source order and bound decode memory.
            for provider in images {
                if let attachment = await Self.load(provider) {
                    items.append(attachment)
                } else {
                    failed += 1
                }
            }
            AttachSound.play(added: images.count - failed)
            reportFailures(failed)
        }
        return true
    }

    func stagePhotos(_ photos: [PhotosPickerItem]) async {
        guard canImport else { return }
        loading = true
        error = nil
        defer { loading = false }
        var failed = 0
        for photo in photos {
            if let data = try? await photo.loadTransferable(type: Data.self),
               let attachment = StagedAttachment.stage(data: data) {
                items.append(attachment)
            } else {
                failed += 1
            }
        }
        AttachSound.play(added: photos.count - failed)
        reportFailures(failed)
    }

    private func reportFailures(_ count: Int) {
        guard count > 0 else { return }
        error = count == 1
            ? "One image couldn't be attached (unsupported or over 24 MB)."
            : "\(count) images couldn't be attached (unsupported or over 24 MB)."
    }

    private static func load(_ provider: NSItemProvider) async -> StagedAttachment? {
        // Prefer original bytes (including animated GIFs) over a UIImage
        // conversion. Files, Photos, and screenshot thumbnails vend image UTIs.
        // A source can advertise several formats but fail to vend one of them.
        // Try the remaining representations before falling back to UIImage.
        for type in provider.registeredTypeIdentifiers where UTType(type)?.conforms(to: .image) == true {
            let data: Data? = await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            if let data { return StagedAttachment.stage(data: data) }
        }
        // Some drag sources only provide an in-memory UIImage.
        guard provider.canLoadObject(ofClass: UIImage.self) else { return nil }
        let image: UIImage? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
        guard let data = image?.pngData() else { return nil }
        return StagedAttachment.stage(data: data)
    }
}
