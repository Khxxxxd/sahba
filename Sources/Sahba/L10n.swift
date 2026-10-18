import Foundation

/// The app's language: the Mac's own (automatic), Arabic, or English. Picked from the menu.
enum Language: String, CaseIterable {
    case auto, arabic, english
}

enum L10n {
    private static let key = "language"
    /// Set by the command-line test modes (`--lang ar|en`) so they don't touch the saved choice.
    static var override: Language?

    static var setting: Language {
        get { override ?? Language(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            // System panels (Move, AirDrop) follow this after the app is reopened.
            switch newValue {
            case .auto: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            case .arabic: UserDefaults.standard.set(["ar"], forKey: "AppleLanguages")
            case .english: UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
            }
        }
    }

    static var arabic: Bool {
        switch setting {
        case .arabic: return true
        case .english: return false
        case .auto:
            // The Mac's language, not AppleLanguages for this app (which the menu choice may have changed).
            let global = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
            return (global?.first ?? Locale.preferredLanguages.first ?? "").hasPrefix("ar")
        }
    }

    /// File size in the app's language (English digits even on an Arabic Mac).
    static func size(_ bytes: Int64) -> String {
        if arabic { return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        guard value >= 1000 else { return "\(bytes) bytes" }
        var i = -1
        repeat { value /= 1000; i += 1 } while value >= 1000 && i < units.count - 1
        return String(format: "%.1f %@", locale: Locale(identifier: "en_US_POSIX"), value, units[i])
    }
}

/// Arabic text when the app speaks Arabic, English otherwise.
func tr(_ arabic: String, _ english: String) -> String { L10n.arabic ? arabic : english }
