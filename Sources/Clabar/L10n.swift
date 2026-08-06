import Foundation
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case auto, ru, en
    var id: String { rawValue }
}

enum Lang {
    static let defaultsKey = "appLanguage"

    /// Thread-safe (UserDefaults + Locale are), usable from any context.
    static var isRu: Bool {
        switch UserDefaults.standard.string(forKey: defaultsKey) ?? "auto" {
        case "ru": return true
        case "en": return false
        default: return Locale.preferredLanguages.first?.lowercased().hasPrefix("ru") ?? false
        }
    }
}

/// Inline pair localization: both languages live at the call site, nothing to
/// keep in sync. ponytail: swap for String Catalogs if a third language appears.
func L(_ ru: String, _ en: String) -> String { Lang.isRu ? ru : en }

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
