// Full attach menu (Photo Library, Take Photo, Choose File, Paste Image) and
// UIDocumentPickerViewController wrapper for ComposerView.

import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ComposerAttachSource: Equatable, Sendable {
    case photoLibrary
    case camera
    case file
    case pasteImage
}

/// The composer's `+` menu. Uses a fixed glass circle visual under a
/// transparent native `Menu` so the UIKit menu lift/clip never distorts the
/// glass rim, and keeps the `"Attach photos"` accessibility label expected by
/// existing UI tests.
struct ComposerAttachMenu: View {
    var cameraAvailable: Bool = CameraCapture.isAvailable
    var singleLine = false
    var enabled = true
    let onSelect: (ComposerAttachSource) -> Void

    @State private var pasteboardHasImages = UIPasteboard.general.hasImages

    private var diameter: CGFloat { singleLine ? 40 : 44 }

    var body: some View {
        ZStack {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(enabled ? Theme.textMuted : Theme.textFaint)
                .frame(width: diameter, height: diameter)
                .glassEffect(.regular.interactive(), in: Circle())
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            Menu {
                Button {
                    onSelect(.photoLibrary)
                } label: {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("composer-attach-photos")

                if cameraAvailable {
                    Button {
                        onSelect(.camera)
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
                    .accessibilityIdentifier("composer-attach-camera")
                }

                Button {
                    onSelect(.file)
                } label: {
                    Label("Choose File", systemImage: "doc")
                }
                .accessibilityIdentifier("composer-attach-file")

                if pasteboardHasImages {
                    Button {
                        onSelect(.pasteImage)
                    } label: {
                        Label("Paste Image", systemImage: "doc.on.clipboard")
                    }
                    .accessibilityIdentifier("composer-attach-paste")
                }
            } label: {
                Color.clear
                    .frame(width: diameter, height: diameter)
                    .contentShape(Circle())
            }
            .menuOrder(.fixed)
            .disabled(!enabled)
            .accessibilityLabel("Attach photos")
            .accessibilityIdentifier("composer-attach")
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            pasteboardHasImages = UIPasteboard.general.hasImages
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            pasteboardHasImages = UIPasteboard.general.hasImages
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            pasteboardHasImages = UIPasteboard.general.hasImages
        }
    }
}

/// System document picker supporting images as well as code, text, PDF, and
/// data files. `asCopy: true` gives readable temporary copies in the app
/// container.
struct DocumentFilePicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    var onCancel: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentFilePicker
        init(_ parent: DocumentFilePicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
            parent.dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
            parent.dismiss()
        }
    }
}

enum PickedAttachmentClassifier {
    struct Result {
        var images: [StagedAttachment] = []
        var files: [StagedFileAttachment] = []
        var failedCount = 0
    }

    static func classify(urls: [URL]) -> Result {
        var result = Result()
        for url in urls {
            let type = UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .image) == true {
                let scoped = url.startAccessingSecurityScopedResource()
                let data = try? Data(contentsOf: url)
                if scoped { url.stopAccessingSecurityScopedResource() }
                if let data {
                    let (staged, failed) = StagedAttachment.stage(images: [data])
                    result.images.append(contentsOf: staged)
                    result.failedCount += failed
                } else {
                    result.failedCount += 1
                }
            } else if let staged = StagedFileAttachment.stage(url: url) {
                result.files.append(staged)
            } else {
                result.failedCount += 1
            }
        }
        return result
    }
}
