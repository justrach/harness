// Attachments on a queued message (#187): add, preview, replace and remove
// its images before it sends. The message keeps its text and its place in
// the queue; confirming commits only the attachment list, to that row.
//
// The + control (#493): the native menu lifts, clips and transforms its label
// while it opens and closes. The visible button (glyph, fill and border) is
// therefore drawn once, as one fixed view outside the menu, and a transparent
// 44pt menu trigger sits on top of it. The menu keeps its native actions and
// accessibility, and its transition never touches what you see.

import SwiftUI
import UniformTypeIdentifiers

struct QueuedImageEditor: View {
    /// Device whose uploads hold the row's committed images (the chat's host).
    let deviceId: String
    /// Saves the draft to its row; returns an error line, or nil once saved.
    let commit: (QueuedAttachmentDraft) async -> String?

    @State private var draft: QueuedAttachmentDraft
    @State private var saving = false
    @State private var error: String?
    @State private var pickerItems: [PickedPhoto] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    /// The slot a pick replaces; nil adds.
    @State private var replacingId: String?
    @State private var preview: AttachmentPreview?
    @Environment(\.dismiss) private var dismiss

    private let cache = AttachmentImageCache.shared
    private static let thumbSize: CGFloat = 64

    init(draft: QueuedAttachmentDraft, deviceId: String,
         commit: @escaping (QueuedAttachmentDraft) async -> String?) {
        self.deviceId = deviceId
        self.commit = commit
        _draft = State(initialValue: draft)
    }

    private var messageLine: String {
        let visible = MessageQueue.visibleText(draft.text, attachments: draft.originalPaths)
        return MessageQueue.oneLine(visible)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(messageLine)
                .font(Theme.sans(13))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("queued-attachments-message")
            HStack(alignment: .center, spacing: 12) {
                AddAttachmentMenu(cameraAvailable: CameraCapture.isAvailable,
                                  enabled: !saving) { source in
                    replacingId = nil
                    open(source)
                }
                strip
            }
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SheetStyle.panel)
        .interactiveDismissDisabled(saving)
        .themedPhotosPicker(isPresented: $showPhotos, selection: $pickerItems)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await stagePicked(items) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image],
                      allowsMultipleSelection: true) { result in
            stageFiles(result)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCapture { data in
                if let data { stage([data]) }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $preview) { AttachmentLightbox(preview: $0) }
        .presentationDetents([.height(180)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .harnessAppearance()
    }

    // MARK: Header: centered title, X / checkmark confirm

    private var header: some View {
        ZStack {
            Text("Attachments")
                .font(Theme.sans(15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("queued-attachments-title")
            HStack {
                // Mirrors the confirm control so the title stays centered.
                Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                Spacer(minLength: 0)
                confirmButton
            }
        }
        .frame(height: 44)
    }

    private var confirmButton: some View {
        let changed = draft.isChanged
        let enabled = !saving && (!changed || draft.canConfirm)
        return Button {
            if changed { save() } else { dismiss() }
        } label: {
            ZStack {
                Circle().fill(changed ? AnyShapeStyle(Theme.text) : AnyShapeStyle(ink(0.06)))
                Circle().strokeBorder(changed ? Color.clear : hairline(0.08), lineWidth: 1)
                if saving {
                    ProgressView().controlSize(.small).tint(Theme.bg)
                } else {
                    Image(systemName: changed ? "checkmark" : "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(changed ? Theme.bg : Theme.textMuted)
                }
            }
            .frame(width: 44, height: 44)
            .opacity(enabled || saving ? 1 : 0.4)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(changed ? "Save attachments" : "Close")
        .accessibilityIdentifier("queued-attachments-confirm")
        .motionAnimation(Motion.fadeQuick, value: changed)
    }

    // MARK: Images

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if draft.items.isEmpty {
                    Text("No images yet")
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.textFaint)
                }
                ForEach(Array(draft.items.enumerated()), id: \.element.id) { index, item in
                    thumb(item, index: index)
                }
            }
            // Room for the remove badges, which sit over the top corner.
            .padding(.top, 6)
            .padding(.trailing, 6)
            .frame(minHeight: Self.thumbSize + 6)
        }
        .frame(height: Self.thumbSize + 6)
    }

    private func image(for item: QueuedAttachmentDraft.Item) -> (name: String, image: UIImage)? {
        switch item.source {
        case .staged(let staged): return (staged.name, staged.image)
        case .committed(let path):
            if case .loaded(let name, let image) = cache.snapshot(deviceId: deviceId, path: path) {
                return (name, image)
            }
            return nil
        }
    }

    private func thumb(_ item: QueuedAttachmentDraft.Item, index: Int) -> some View {
        let loaded = image(for: item)
        let shape = RoundedRectangle(cornerRadius: 12)
        return Button {
            if let loaded { preview = AttachmentPreview(name: loaded.name, image: loaded.image) }
        } label: {
            Group {
                if let loaded {
                    Image(uiImage: loaded.image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ProgressView().controlSize(.small).tint(Theme.textFaint)
                }
            }
            .frame(width: Self.thumbSize, height: Self.thumbSize)
            .background(ink(0.035))
            .clipShape(shape)
            .overlay(shape.strokeBorder(hairline(0.11), lineWidth: 1))
            .overlay(alignment: .bottomLeading) {
                if item.locked {
                    Image(systemName: "macwindow")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 18, height: 18)
                        .background(Theme.bg.opacity(0.85), in: Circle())
                        .padding(4)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.locked ? "Preview Appshot \(index + 1)" : "Preview attachment \(index + 1)")
        .accessibilityIdentifier("queued-attachment-\(index)")
        .contextMenu {
            if let loaded {
                Button("Preview", systemImage: "eye") {
                    preview = AttachmentPreview(name: loaded.name, image: loaded.image)
                }
            }
            if !item.locked {
                Button("Replace", systemImage: "arrow.triangle.2.circlepath") {
                    replacingId = item.id
                    open(.photos)
                }
                Button("Remove", systemImage: "trash", role: .destructive) {
                    draft.remove(id: item.id)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if !item.locked {
                Button {
                    draft.remove(id: item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 18, height: 18)
                        .background(Theme.bg.opacity(0.85), in: Circle())
                        .overlay(Circle().strokeBorder(hairline(0.2), lineWidth: 1))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(saving)
                .offset(x: 8, y: -8)
                .accessibilityLabel("Remove attachment \(index + 1)")
            }
        }
        .task(id: item.path) {
            if let path = item.path { cache.load(deviceId: deviceId, path: path) }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let error {
            Text(error)
                .font(Theme.sans(12))
                .foregroundStyle(Theme.danger)
                .lineLimit(2)
        } else if saving {
            Text("Uploading…")
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textMuted)
        } else if draft.isChanged && draft.commitText == nil {
            Text("A queued message needs text or an image.")
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textMuted)
        }
    }

    // MARK: Picking

    private func open(_ source: AddAttachmentMenu.Source) {
        error = nil
        switch source {
        case .camera: showCamera = true
        case .photos: showPhotos = true
        case .files: showFiles = true
        }
    }

    private func stagePicked(_ items: [PickedPhoto]) async {
        var images: [Data] = []
        var failed = 0
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                images.append(data)
            } else {
                failed += 1
            }
        }
        pickerItems = []
        stage(images, alreadyFailed: failed)
    }

    private func stageFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else {
            replacingId = nil
            return
        }
        var images: [Data] = []
        var failed = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { images.append(data) } else { failed += 1 }
        }
        stage(images, alreadyFailed: failed)
    }

    private func stage(_ images: [Data], alreadyFailed: Int = 0) {
        var (staged, failed) = StagedAttachment.stage(images: images)
        failed += alreadyFailed
        if let replacingId, let first = staged.first {
            draft.replace(id: replacingId, with: first)
            staged.removeFirst()
        }
        draft.add(staged)
        replacingId = nil
        error = StagedAttachment.failureMessage(failed)
    }

    private func save() {
        guard draft.canConfirm, !saving else { return }
        saving = true
        error = nil
        let snapshot = draft
        Task { @MainActor in
            let failure = await commit(snapshot)
            saving = false
            error = failure
        }
    }
}

/// The + control. One fixed visual, with a transparent native menu over it.
struct AddAttachmentMenu: View {
    enum Source { case camera, photos, files }

    var cameraAvailable: Bool
    var enabled = true
    var pick: (Source) -> Void

    var body: some View {
        ZStack {
            // Glyph, fill and border together, outside the menu label, so the
            // menu's lift, clip and scale never apply to any of them.
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(enabled ? Theme.textMuted : Theme.textFaint)
                .frame(width: 44, height: 44)
                .background(ink(0.06), in: Circle())
                .overlay(Circle().strokeBorder(hairline(0.08), lineWidth: 1))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Menu {
                Button("Camera", systemImage: "camera") { pick(.camera) }
                    .disabled(!cameraAvailable)
                Button("Photos", systemImage: "photo.on.rectangle") { pick(.photos) }
                Button("Files", systemImage: "folder") { pick(.files) }
            } label: {
                Color.clear
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            // Camera, Photos, Files, top to bottom, wherever the menu opens.
            .menuOrder(.fixed)
            .disabled(!enabled)
            .accessibilityLabel("Add attachment")
            .accessibilityIdentifier("queued-attachments-add")
        }
        .frame(width: 44, height: 44)
    }
}

/// The system camera, returning the captured photo's JPEG bytes (nil on
/// cancel).
struct CameraCapture: UIViewControllerRepresentable {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    let done: (Data?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCapture
        init(_ parent: CameraCapture) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            parent.done(image?.jpegData(compressionQuality: 0.9))
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.done(nil)
            parent.dismiss()
        }
    }
}
