import Foundation

enum AppLocalization {
    static var language: AppLanguage {
        UserDefaults.standard.string(forKey: AppPreferenceKeys.language)
            .flatMap(AppLanguage.init(rawValue:))
            ?? .russian
    }

    static func string(_ key: String.LocalizationValue) -> String {
        string(key, language: language)
    }

    static func string(
        _ key: String.LocalizationValue,
        language: AppLanguage
    ) -> String {
        String(
            localized: key,
            bundle: localizationBundle(for: language),
            locale: language.locale
        )
    }

    /// `String(localized:locale:)` still follows the process' preferred
    /// localization on macOS 14. Selecting the concrete `.lproj` bundle makes
    /// the in-app language switch deterministic without restarting the app.
    private static func localizationBundle(for language: AppLanguage) -> Bundle {
        guard
            let localization = language.resourceLocalization,
            let path = Bundle.module.path(forResource: localization, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            return .module
        }

        return bundle
    }
}
