import Foundation

/// App-authored text uses English source keys, with an explicit English
/// fallback for command-line helpers and test bundles without app resources.
enum L10n {
    static func tr(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), locale: Locale.current, arguments: arguments)
    }
}

/// Uses macOS's per-app language preference, so SwiftUI, AppKit alerts and
/// embedded frameworks agree on the language after the next launch.
enum InterfaceLanguage: String, CaseIterable {
    case system = "system"
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let preferenceKey = "interfaceLanguage"

    static func current(in defaults: UserDefaults = .standard) -> InterfaceLanguage {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .system
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
        switch self {
        case .system:
            // Remove only this app's override. Never change the global language.
            defaults.removeObject(forKey: "AppleLanguages")
        case .english, .simplifiedChinese:
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }

    var displayName: String {
        switch self {
        case .system: return L10n.tr("System Default")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}
