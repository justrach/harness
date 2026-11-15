import AuthenticationServices
import MachO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Harness

/// What the app links decides what loads before main. PhotosUI and
/// AuthenticationServices each bring 660 more system images, and with them an empty
/// app's first frame goes from 318 ms to 1,419 ms in the simulator. This test bundle
/// links both itself, which is how the rest of this file can check the runtime calls
/// the app makes without them.
@MainActor
final class LaunchLinkageTests: XCTestCase {
    /// What an image in the app's bundle links, from its load commands.
    private func linkedLibraries() -> [String] {
        var linked: [String] = []
        let bundle = Bundle.main.bundlePath
        for index in 0..<_dyld_image_count() {
            let path = String(cString: _dyld_get_image_name(index))
            guard path.contains(bundle), !path.contains(".xctest"),
                  let header = _dyld_get_image_header(index) else { continue }
            var cursor = UnsafeRawPointer(header) + MemoryLayout<mach_header_64>.size
            for _ in 0..<header.pointee.ncmds {
                let command = cursor.load(as: load_command.self)
                if command.cmd == UInt32(LC_LOAD_DYLIB) || command.cmd == (UInt32(0x18) | UInt32(LC_REQ_DYLD)) {
                    let offset = cursor.load(as: dylib_command.self).dylib.name.offset
                    linked.append(String(cString: (cursor + Int(offset)).assumingMemoryBound(to: CChar.self)))
                }
                cursor += Int(command.cmdsize)
            }
        }
        return linked
    }

    func testTheAppLinksNothingThatLoadsHundredsOfImagesAtLaunch() {
        let linked = linkedLibraries()
        XCTAssertTrue(linked.contains { $0.contains("SwiftUI.framework") }, "the walk must see what the app links")
        for name in ["PhotosUI.framework", "_PhotosUI_SwiftUI.framework", "AuthenticationServices.framework"] {
            XCTAssertFalse(linked.contains { $0.contains(name) },
                           "\(name) adds over a second to launch: reach it through LateFramework")
        }
    }

    func testThePickerIsBuiltAsThePhotosPickerWas() async throws {
        let loaded = await LateFramework.photosUI.load()
        XCTAssertTrue(loaded)
        let configuration = try XCTUnwrap(PhotoPicker.configuration())
        XCTAssertEqual(configuration.value(forKey: "selectionLimit") as? Int, 8)
        // Which filter it is shows only in the picker: the class doesn't describe it.
        XCTAssertNotNil(configuration.value(forKey: "filter"), "the picker would offer videos too")
        var selection: [PickedPhoto] = []
        var presented = true
        let coordinator = PhotoPicker.Coordinator(
            selection: Binding(get: { selection }, set: { selection = $0 }),
            isPresented: Binding(get: { presented }, set: { presented = $0 }))
        XCTAssertTrue(coordinator.conforms(to: try XCTUnwrap(objc_getProtocol("PHPickerViewControllerDelegate"))))
        let picker = try XCTUnwrap(PhotoPicker.makePicker(delegate: coordinator))
        XCTAssertTrue(picker.isKind(of: PHPickerViewController.self))
        // Through the runtime: PhotosUI's Swift overlay traps on reading this.
        XCTAssertTrue(picker.value(forKey: "delegate") as AnyObject === coordinator)
    }

    private func wait(_ what: String, until done: () -> Bool) async {
        for _ in 0..<300 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(done(), what)
    }

    /// The picker lands above what is showing, closes with its binding, and opens
    /// again. The fixture's picker presents from a screen that is itself covered.
    func testThePickerOpensAboveWhatIsShowingClosesAndOpensAgain() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let anchor = UIViewController()
        window.rootViewController = anchor
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let cover = UIViewController()
        anchor.present(cover, animated: false)
        var selection: [PickedPhoto] = []
        var presented = true
        let coordinator = PhotoPicker.Coordinator(
            selection: Binding(get: { selection }, set: { selection = $0 }),
            isPresented: Binding(get: { presented }, set: { presented = $0 }))
        for _ in 0..<2 {
            presented = true
            coordinator.sync(from: anchor)
            await wait("the picker opens") { cover.presentedViewController is PHPickerViewController }
            await wait("it finishes opening") { cover.presentedViewController?.transitionCoordinator == nil }
            presented = false
            coordinator.sync(from: anchor)
            await wait("it closes with its binding") { cover.presentedViewController == nil }
            await wait("it finishes closing") { cover.transitionCoordinator == nil }
        }
        XCTAssertTrue(anchor.presentedViewController === cover, "what was showing stays")
    }

    /// Its own Cancel closes it, with no update from SwiftUI to help: in the
    /// composer nothing else changes, so none comes.
    func testThePickerClosesItselfWhenItFinishes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let anchor = UIViewController()
        window.rootViewController = anchor
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        var selection: [PickedPhoto] = []
        var presented = true
        let coordinator = PhotoPicker.Coordinator(
            selection: Binding(get: { selection }, set: { selection = $0 }),
            isPresented: Binding(get: { presented }, set: { presented = $0 }))
        coordinator.sync(from: anchor)
        await wait("the picker opens") { anchor.presentedViewController is PHPickerViewController }
        await wait("it finishes opening") { anchor.presentedViewController?.transitionCoordinator == nil }
        coordinator.picker(try XCTUnwrap(anchor.presentedViewController), didFinishPicking: [])
        await wait("it closes") { anchor.presentedViewController == nil }
        XCTAssertFalse(presented)
        await wait("it finishes closing") { anchor.transitionCoordinator == nil }
        presented = true
        coordinator.sync(from: anchor)
        await wait("it opens again") { anchor.presentedViewController is PHPickerViewController }
        presented = false
        coordinator.sync(from: anchor)
        await wait("and closes") { anchor.presentedViewController == nil }
    }

    /// Asked for during a transition, the picker opens when it ends.
    func testThePickerWaitsForATransitionUnderWay() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let anchor = UIViewController()
        window.rootViewController = anchor
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try? await Task.sleep(for: .milliseconds(100))
        let closing = UIViewController()
        anchor.present(closing, animated: false)
        var selection: [PickedPhoto] = []
        var presented = true
        let coordinator = PhotoPicker.Coordinator(
            selection: Binding(get: { selection }, set: { selection = $0 }),
            isPresented: Binding(get: { presented }, set: { presented = $0 }))
        // Loaded already: the picker asks to present on the next main-actor turns.
        let loaded = await LateFramework.photosUI.load()
        XCTAssertTrue(loaded)
        closing.dismiss(animated: true)
        coordinator.sync(from: anchor)
        await wait("the picker opens once the sheet has gone") {
            anchor.presentedViewController is PHPickerViewController
        }
        presented = false
        coordinator.sync(from: anchor)
        await wait("it closes") { anchor.presentedViewController == nil }
    }

    /// A Live Photo's bundle isn't an image file, so it must not be what's vended.
    func testALivePhotoBundleIsNotTakenForAnImage() {
        XCTAssertFalse(UTType.livePhoto.conforms(to: .image))
    }

    private final class FakeResult: NSObject {
        @objc let itemProvider: NSItemProvider
        init(_ provider: NSItemProvider) { itemProvider = provider }
    }

    func testFinishingThePickerKeepsThePhotosAndCancellingKeepsTheSelection() {
        let kept = PickedPhoto(provider: NSItemProvider())
        var selection = [kept]
        var presented = true
        let coordinator = PhotoPicker.Coordinator(
            selection: Binding(get: { selection }, set: { selection = $0 }),
            isPresented: Binding(get: { presented }, set: { presented = $0 }))
        coordinator.picker(UIViewController(), didFinishPicking: [])
        XCTAssertEqual(selection, [kept], "cancelling leaves the selection")
        XCTAssertFalse(presented)
        presented = true
        let provider = NSItemProvider()
        coordinator.picker(UIViewController(), didFinishPicking: [FakeResult(provider)])
        XCTAssertEqual(selection, [PickedPhoto(provider: provider)])
        XCTAssertFalse(presented)
    }

    func testAPickedPhotoVendsItsImageBytesAndNothingElse() async throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let image = NSItemProvider(item: bytes as NSData, typeIdentifier: "public.png")
        let loaded = try await PickedPhoto(provider: image).loadTransferable(type: Data.self)
        XCTAssertEqual(loaded, bytes)
        let text = NSItemProvider(item: Data("hello".utf8) as NSData, typeIdentifier: "public.plain-text")
        let none = try await PickedPhoto(provider: text).loadTransferable(type: Data.self)
        XCTAssertNil(none)
    }

    func testASignInSessionIsConfiguredAsItWas() async throws {
        let loaded = await LateFramework.authenticationServices.load()
        XCTAssertTrue(loaded)
        let coordinator = AuthSessionCoordinator()
        let session = try XCTUnwrap(coordinator.preparedSession(
            url: URL(string: "https://example.test/authorize")!, callbackScheme: "harness"
        ) as? ASWebAuthenticationSession)
        XCTAssertTrue(session.prefersEphemeralWebBrowserSession)
        XCTAssertTrue(session.presentationContextProvider === coordinator)
        XCTAssertTrue(coordinator.conforms(to: ASWebAuthenticationPresentationContextProviding.self))
    }

    func testASignInReportsTheOutcomesItDid() {
        XCTAssertEqual(AuthSessionCoordinator.sessionErrorDomain, ASWebAuthenticationSessionError.errorDomain)
        XCTAssertEqual(AuthSessionCoordinator.canceledLoginCode, ASWebAuthenticationSessionError.canceledLogin.rawValue)
        let url = URL(string: "harness://done")!
        XCTAssertEqual(AuthSessionCoordinator.outcome(callbackURL: url, error: nil), .success(url))
        XCTAssertEqual(AuthSessionCoordinator.outcome(callbackURL: nil, error: ASWebAuthenticationSessionError(.canceledLogin)),
                       .cancelled)
        let failure = AuthSessionCoordinator.outcome(callbackURL: nil, error: ASWebAuthenticationSessionError(.presentationContextInvalid))
        guard case .failure = failure else { return XCTFail("a real failure must not read as cancelled") }
        XCTAssertEqual(AuthSessionCoordinator.outcome(callbackURL: nil, error: nil), .failure("Sign-in failed"))
    }

    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .compactMap(\.keyWindow).first!
        }
    }

    /// The framework accepts the session built through the runtime, provider and
    /// all, and cancelling it does what cancelling one built directly does.
    func testTheFrameworkRunsARuntimeBuiltSessionAsItRunsADirectOne() async throws {
        let loaded = await LateFramework.authenticationServices.load()
        XCTAssertTrue(loaded)
        let url = URL(string: "https://example.test/authorize")!
        var directEnded = false
        let provider = Anchor()
        let direct = ASWebAuthenticationSession(url: url, callbackURLScheme: "harness") { _, _ in directEnded = true }
        direct.presentationContextProvider = provider
        direct.prefersEphemeralWebBrowserSession = true
        XCTAssertTrue(direct.canStart)
        XCTAssertTrue(direct.start())
        try? await Task.sleep(for: .seconds(1))
        direct.cancel()
        try? await Task.sleep(for: .seconds(1))

        let coordinator = AuthSessionCoordinator()
        var ended = false
        let session = try XCTUnwrap(coordinator.preparedSession(url: url, callbackScheme: "harness") { _ in
            ended = true
        } as? ASWebAuthenticationSession)
        XCTAssertTrue(session.canStart, "the framework refused the provider")
        XCTAssertTrue(session.start())
        try? await Task.sleep(for: .seconds(1))
        XCTAssertFalse(ended, "it must be running, not refused")
        session.cancel()
        try? await Task.sleep(for: .seconds(1))
        print("cancel: direct completion ran \(directEnded), runtime-built completion ran \(ended)")
        XCTAssertEqual(ended, directEnded)
    }

    /// A sign-in cancelled while the framework loads must end, and not open a sheet.
    func testCancellingASignInThatIsStillLoadingReportsCancelled() async {
        let coordinator = AuthSessionCoordinator()
        let finished = expectation(description: "the completion ran")
        var outcome: AuthSessionCoordinator.Outcome?
        coordinator.start(url: URL(string: "https://example.test")!, callbackScheme: "harness") {
            outcome = $0
            finished.fulfill()
        }
        coordinator.cancel()
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(outcome, .cancelled)
    }
}
