import Foundation

enum InterfaceLanguage: String, CaseIterable {
    case system, english = "en", simplifiedChinese = "zh-Hans"
    static let preferenceKey = "interfaceLanguage"

    static func saved(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .system
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }

    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .english: return "en"
        case .simplifiedChinese: return "zh-Hans"
        case .system:
            return Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: preferredLanguages).first ?? "en"
        }
    }
}

struct Localizer {
    static let english = Localizer(language: .english)
    let locale: Locale
    private let bundle: Bundle?

    init(language: InterfaceLanguage, preferredLanguages: [String] = Locale.preferredLanguages) {
        let code = language.resolved(preferredLanguages: preferredLanguages)
        locale = Locale(identifier: code)
        bundle = Bundle.main.resourceURL.flatMap { Bundle(path: $0.appendingPathComponent("\(code).lproj").path) }
    }

    func text(_ key: String) -> String {
        bundle?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
    }

    func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
}
