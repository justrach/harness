import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A photo the picker returned. PhotosUI loads only once a picker opens
/// (LateFramework), so this holds what it hands back rather than its types.
struct PickedPhoto: Equatable {
    let provider: NSItemProvider

    func loadTransferable(type: Data.Type) async throws -> Data? {
        await provider.imageBytes()
    }
}

extension NSItemProvider {
    /// The original bytes (including animated GIFs). A source can advertise several
    /// formats but fail to vend one of them, so this tries each.
    func imageBytes() async -> Data? {
        for type in registeredTypeIdentifiers where UTType(type)?.conforms(to: .image) == true {
            let data: Data? = await withCheckedContinuation { continuation in
                loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            if let data { return data }
        }
        return nil
    }
}

extension View {
    /// Photos supplies its own selection and prominent-confirmation palette.
    /// Keep both on the native semantic tint and the active theme's appearance,
    /// without changing the composer's or other sheets' theme-text tint.
    func themedPhotosPicker(isPresented: Binding<Bool>, selection: Binding<[PickedPhoto]>) -> some View {
        background {
            PhotoPicker(selection: selection, isPresented: isPresented)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

@objc private protocol PickerConfigurationAPI: NSObjectProtocol {
    init()
    var selectionLimit: Int { get set }
    var filter: AnyObject? { get set }
}

@objc private protocol PickerFilterAPI: NSObjectProtocol {
    static var imagesFilter: AnyObject { get }
}

@objc private protocol PickerViewControllerAPI: NSObjectProtocol {
    init(configuration: AnyObject)
    var delegate: AnyObject? { get set }
}

struct PhotoPicker: UIViewControllerRepresentable {
    @Binding var selection: [PickedPhoto]
    @Binding var isPresented: Bool

    static let maxSelection = 8

    /// Nil until PhotosUI is loaded.
    static func configuration() -> NSObject? {
        guard let configurationClass = NSClassFromString("PHPickerConfiguration"),
              let filterClass = NSClassFromString("PHPickerFilter") else { return nil }
        let api = unsafeBitCast(configurationClass, to: PickerConfigurationAPI.Type.self)
        let configuration = api.init()
        configuration.selectionLimit = maxSelection
        configuration.filter = unsafeBitCast(filterClass, to: PickerFilterAPI.Type.self).imagesFilter
        return configuration as? NSObject
    }

    static func makePicker(delegate: AnyObject) -> UIViewController? {
        guard let pickerClass = NSClassFromString("PHPickerViewController"),
              let configuration = configuration() else { return nil }
        let picker = unsafeBitCast(pickerClass, to: PickerViewControllerAPI.Type.self).init(configuration: configuration)
        picker.delegate = delegate
        return picker as? UIViewController
    }

    /// An empty controller to present from. The picker must be presented itself:
    /// held inside a sheet it drops its header and its Cancel and Done buttons.
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ anchor: UIViewController, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.isPresented = $isPresented
        context.coordinator.sync(from: anchor)
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, isPresented: $isPresented) }

    @MainActor
    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        var selection: Binding<[PickedPhoto]>
        var isPresented: Binding<Bool>
        private weak var picker: UIViewController?
        private var loading = false

        init(selection: Binding<[PickedPhoto]>, isPresented: Binding<Bool>) {
            self.selection = selection
            self.isPresented = isPresented
            super.init()
            LateFramework.adopt("PHPickerViewControllerDelegate", on: Coordinator.self)
        }

        func sync(from anchor: UIViewController) {
            if !isPresented.wrappedValue {
                if let picker {
                    self.picker = nil
                    picker.presentingViewController?.dismiss(animated: true)
                }
                return
            }
            guard picker == nil, !loading else { return }
            loading = true
            Task { @MainActor [weak anchor] in
                let loaded = await LateFramework.photosUI.load()
                loading = false
                // Closed while loading, or by now somewhere that can't present.
                guard isPresented.wrappedValue else { return }
                guard loaded, let anchor, anchor.view.window != nil,
                      let picker = PhotoPicker.makePicker(delegate: self) else {
                    isPresented.wrappedValue = false
                    return
                }
                // Photos' UIKit bridge reads the view's tint, and follows the
                // active theme's appearance rather than the system's.
                picker.view.tintColor = .systemBlue
                picker.overrideUserInterfaceStyle = UIUserInterfaceStyle(ThemeStore.shared.preferredScheme)
                picker.presentationController?.delegate = self
                self.picker = picker
                present(picker, from: anchor)
            }
        }

        /// Above whatever is showing, once any transition under way has ended (a
        /// menu closing, say). UIKit drops a presentation made during one, and the
        /// attach button would then do nothing.
        private func present(_ picker: UIViewController, from anchor: UIViewController) {
            var top = anchor
            while let next = top.presentedViewController { top = next }
            guard let transition = top.transitionCoordinator else {
                top.present(picker, animated: true)
                return
            }
            transition.animate(alongsideTransition: nil) { [weak self, weak anchor] _ in
                guard let self, let anchor, self.isPresented.wrappedValue else { return }
                self.present(picker, from: anchor)
            }
        }

        /// Swiped away: nothing picked, and the next open must present again.
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            picker = nil
            isPresented.wrappedValue = false
        }

        /// PHPickerViewControllerDelegate. Cancelling picks nothing, and leaves the
        /// selection as it was. It closes here rather than through `sync`: a Cancel
        /// changes nothing else in the composer, so SwiftUI has no reason to update.
        @objc(picker:didFinishPicking:)
        func picker(_ picker: UIViewController, didFinishPicking results: [NSObject]) {
            self.picker = nil
            picker.presentingViewController?.dismiss(animated: true)
            let photos = results.compactMap { $0.value(forKey: "itemProvider") as? NSItemProvider }
            if !photos.isEmpty { selection.wrappedValue = photos.map(PickedPhoto.init) }
            isPresented.wrappedValue = false
        }
    }
}
