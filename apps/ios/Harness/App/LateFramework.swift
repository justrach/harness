// System frameworks loaded when they are first used, not at launch.
//
// Linking PhotosUI or AuthenticationServices makes dyld load 660 more system
// images before main (CarPlay, HealthKit, MapKit, ...), for two screens most
// launches never open. An empty app's first frame went from 318 ms to 1,419 ms in
// the simulator with either one linked, and Harness's own took 1,675 ms.
// LaunchLinkageTests fails if the app links them again, so neither may be imported
// here: their classes are reached through the Objective-C runtime, each described
// by a small @objc protocol the compiler can check calls against.

import Foundation

enum LateFramework: String {
    case photosUI = "/System/Library/Frameworks/PhotosUI.framework/PhotosUI"
    case authenticationServices = "/System/Library/Frameworks/AuthenticationServices.framework/AuthenticationServices"

    /// Off the main thread: the first load takes as long as linking it would have.
    func load() async -> Bool {
        let path = rawValue
        return await Task.detached(priority: .userInitiated) {
            dlopen(path, RTLD_LAZY) != nil
        }.value
    }

    /// Say `type` adopts a protocol of this framework, once it is loaded. Its
    /// classes check for that before they call back.
    static func adopt(_ protocolName: String, on type: AnyClass) {
        if let adopted = objc_getProtocol(protocolName) { class_addProtocol(type, adopted) }
    }
}
