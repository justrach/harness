// Alternate app icon choices (Light default vs Dark alternate icon).

import UIKit

enum AppIconChoice: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var alternateIconName: String? {
        switch self {
        case .light: return nil
        case .dark: return "AppIconDark"
        }
    }

    var previewAssetName: String {
        switch self {
        case .light: return "app-icon-light"
        case .dark: return "app-icon-dark"
        }
    }

    static func from(alternateIconName: String?) -> AppIconChoice {
        alternateIconName == "AppIconDark" ? .dark : .light
    }

    @MainActor
    func apply() {
        guard UIApplication.shared.supportsAlternateIcons else { return }
        guard UIApplication.shared.alternateIconName != alternateIconName else { return }
        UIApplication.shared.setAlternateIconName(alternateIconName) { _ in }
    }
}
