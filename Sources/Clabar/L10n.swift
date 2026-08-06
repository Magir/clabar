import Foundation
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case auto, ru, en, es, pt, fr, de, uk

    var id: String { rawValue }

    /// Native display name for the settings picker.
    var displayName: String {
        switch self {
        case .auto: return L("Авто (как в системе)", "Auto (system)")
        case .ru: return "Русский"
        case .en: return "English"
        case .es: return "Español"
        case .pt: return "Português"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .uk: return "Українська"
        }
    }
}

enum Lang {
    static let defaultsKey = "appLanguage"
    static let supported = ["ru", "en", "es", "pt", "fr", "de", "uk"]

    /// Effective language code. Thread-safe (UserDefaults + Locale are).
    static var current: String {
        let stored = UserDefaults.standard.string(forKey: defaultsKey) ?? "auto"
        if supported.contains(stored) { return stored }
        for preferred in Locale.preferredLanguages {
            let code = String(preferred.prefix(2)).lowercased()
            if supported.contains(code) { return code }
        }
        return "en"
    }

    static var isRu: Bool { current == "ru" }

    /// Locale for date/number formatting — follows the forced language, or the
    /// system when auto. Inject via .environment(\.locale, Lang.locale).
    static var locale: Locale {
        switch UserDefaults.standard.string(forKey: defaultsKey) ?? "auto" {
        case "ru": return Locale(identifier: "ru_RU")
        case "en": return Locale(identifier: "en_US")
        case "es": return Locale(identifier: "es_ES")
        case "pt": return Locale(identifier: "pt_BR")
        case "fr": return Locale(identifier: "fr_FR")
        case "de": return Locale(identifier: "de_DE")
        case "uk": return Locale(identifier: "uk_UA")
        default: return .autoupdatingCurrent
        }
    }
}

/// Localization: call sites carry the ru/en pair inline; the other languages
/// are looked up in Translations by the ENGLISH string (verbatim key). A
/// missing key falls back to English — graceful, never crashes.
func L(_ ru: String, _ en: String) -> String {
    switch Lang.current {
    case "ru": return ru
    case "en": return en
    case let code: return Translations.table[en]?[code] ?? en
    }
}

/// Template variant for strings with parameters: `{name}` placeholders in both
/// the pair and the Translations entry, substituted after lookup.
func LT(_ ru: String, _ en: String, _ subs: [String: String]) -> String {
    var out = L(ru, en)
    for (key, value) in subs {
        out = out.replacingOccurrences(of: "{\(key)}", with: value)
    }
    return out
}

/// Views observe this to re-render when the language changes.
@MainActor
final class LangObserver: ObservableObject {
    static let shared = LangObserver()

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Lang.defaultsKey) }
    }

    private init() {
        language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: Lang.defaultsKey) ?? "auto") ?? .auto
    }
}
