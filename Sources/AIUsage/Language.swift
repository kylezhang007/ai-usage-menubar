import Foundation

/// UI language: follows the system unless the user picks one in Settings.
enum Language: String, CaseIterable {
    case system, chinese, english

    static var current: Language {
        Language(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system
    }

    static var isChinese: Bool {
        switch current {
        case .chinese: return true
        case .english: return false
        case .system: return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
    }

    static var locale: Locale { Locale(identifier: isChinese ? "zh_CN" : "en_US") }
}

/// Picks the Chinese or English text for the current UI language.
func L(_ zh: String, _ en: String) -> String {
    Language.isChinese ? zh : en
}
