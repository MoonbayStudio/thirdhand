import Foundation
import Speech
import SwiftUI

enum AppPreferenceKeys {
    static let appearance = "appAppearance"
    static let language = "appLanguage"
    static let voiceInputEnabled = "voiceInputEnabled"
    static let voiceRecognitionLanguage = "voiceRecognitionLanguage"
    static let voiceAddsPunctuation = "voiceAddsPunctuation"
    static let voicePrefersOnDeviceRecognition = "voicePrefersOnDeviceRecognition"
    static let reduceMotion = "appReduceMotion"
    static let reduceTransparency = "appReduceTransparency"
    static let differentiateWithoutColor = "appDifferentiateWithoutColor"
    static let increaseContrast = "appIncreaseContrast"
    static let textSize = "appAccessibilityTextSize"
    static let keyboardShortcutsEnabled = "keyboardShortcutsEnabled"
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var titleKey: LocalizedStringKey {
        switch self {
        case .system:
            "Системная"
        case .light:
            "Светлая"
        case .dark:
            "Тёмная"
        }
    }

    var systemImage: String {
        switch self {
        case .system:
            "circle.lefthalf.filled"
        case .light:
            "sun.max.fill"
        case .dark:
            "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case russian
    case english
    case german
    case french
    case spanish
    case italian
    case portugueseBrazil
    case polish
    case turkish
    case ukrainian
    case belarusian
    case kazakh
    case uzbek
    case kyrgyz
    case tajik
    case turkmen
    case chineseSimplified
    case japanese
    case korean

    var id: Self { self }

    var displayName: String {
        switch self {
        case .system:
            "Системный язык"
        case .russian:
            "Русский"
        case .english:
            "English"
        case .german:
            "Deutsch"
        case .french:
            "Français"
        case .spanish:
            "Español"
        case .italian:
            "Italiano"
        case .portugueseBrazil:
            "Português (Brasil)"
        case .polish:
            "Polski"
        case .turkish:
            "Türkçe"
        case .ukrainian:
            "Українська"
        case .belarusian:
            "Беларуская"
        case .kazakh:
            "Қазақша"
        case .uzbek:
            "O‘zbekcha"
        case .kyrgyz:
            "Кыргызча"
        case .tajik:
            "Тоҷикӣ"
        case .turkmen:
            "Türkmençe"
        case .chineseSimplified:
            "简体中文"
        case .japanese:
            "日本語"
        case .korean:
            "한국어"
        }
    }

    var displayNameKey: LocalizedStringKey {
        LocalizedStringKey(displayName)
    }

    var locale: Locale {
        localeIdentifier.map(Locale.init(identifier:)) ?? .autoupdatingCurrent
    }

    var localeIdentifier: String? {
        switch self {
        case .system: nil
        case .russian: "ru-RU"
        case .english: "en-US"
        case .german: "de-DE"
        case .french: "fr-FR"
        case .spanish: "es-ES"
        case .italian: "it-IT"
        case .portugueseBrazil: "pt-BR"
        case .polish: "pl-PL"
        case .turkish: "tr-TR"
        case .ukrainian: "uk-UA"
        case .belarusian: "be-BY"
        case .kazakh: "kk-KZ"
        case .uzbek: "uz-UZ"
        case .kyrgyz: "ky-KG"
        case .tajik: "tg-TJ"
        case .turkmen: "tk-TM"
        case .chineseSimplified: "zh-Hans"
        case .japanese: "ja-JP"
        case .korean: "ko-KR"
        }
    }

    var resourceLocalization: String? {
        switch self {
        case .system: nil
        case .russian: "ru"
        case .english: "en"
        case .german: "de"
        case .french: "fr"
        case .spanish: "es"
        case .italian: "it"
        case .portugueseBrazil: "pt-br"
        case .polish: "pl"
        case .turkish: "tr"
        case .ukrainian: "uk"
        case .belarusian: "be"
        case .kazakh: "kk"
        case .uzbek: "uz"
        case .kyrgyz: "ky"
        case .tajik: "tg"
        case .turkmen: "tk"
        case .chineseSimplified: "zh-hans"
        case .japanese: "ja"
        case .korean: "ko"
        }
    }
}

enum VoiceRecognitionLanguage: String, CaseIterable, Identifiable {
    case automatic
    case russian
    case english
    case german
    case french
    case spanish
    case italian
    case portugueseBrazil
    case polish
    case turkish
    case ukrainian
    case belarusian
    case kazakh
    case uzbek
    case kyrgyz
    case tajik
    case turkmen
    case chineseSimplified
    case japanese
    case korean

    var id: Self { self }

    var displayName: String {
        switch self {
        case .automatic:
            "Автоматически"
        case .russian:
            "Русский"
        case .english:
            "English"
        case .german:
            "Deutsch"
        case .french:
            "Français"
        case .spanish:
            "Español"
        case .italian:
            "Italiano"
        case .portugueseBrazil:
            "Português (Brasil)"
        case .polish:
            "Polski"
        case .turkish:
            "Türkçe"
        case .ukrainian:
            "Українська"
        case .belarusian:
            "Беларуская"
        case .kazakh:
            "Қазақша"
        case .uzbek:
            "O‘zbekcha"
        case .kyrgyz:
            "Кыргызча"
        case .tajik:
            "Тоҷикӣ"
        case .turkmen:
            "Türkmençe"
        case .chineseSimplified:
            "简体中文"
        case .japanese:
            "日本語"
        case .korean:
            "한국어"
        }
    }

    var displayNameKey: LocalizedStringKey {
        LocalizedStringKey(displayName)
    }

    static var availableCases: [Self] {
        allCases.filter { language in
            language == .automatic || language.isSupportedOnCurrentSystem
        }
    }

    var isSupportedOnCurrentSystem: Bool {
        guard let localeIdentifier else { return true }
        return Self.supportedLocaleIdentifiers.contains(localeIdentifier)
    }

    func locale(appLanguage: AppLanguage) -> Locale {
        switch self {
        case .automatic:
            Self.automaticLocale(appLanguage: appLanguage)
        default:
            Locale(identifier: localeIdentifier ?? "en-US")
        }
    }

    private var localeIdentifier: String? {
        switch self {
        case .automatic: nil
        case .russian: "ru-RU"
        case .english: "en-US"
        case .german: "de-DE"
        case .french: "fr-FR"
        case .spanish: "es-ES"
        case .italian: "it-IT"
        case .portugueseBrazil: "pt-BR"
        case .polish: "pl-PL"
        case .turkish: "tr-TR"
        case .ukrainian: "uk-UA"
        case .belarusian: "be-BY"
        case .kazakh: "kk-KZ"
        case .uzbek: "uz-UZ"
        case .kyrgyz: "ky-KG"
        case .tajik: "tg-TJ"
        case .turkmen: "tk-TM"
        case .chineseSimplified: "zh-Hans"
        case .japanese: "ja-JP"
        case .korean: "ko-KR"
        }
    }

    private static let supportedLocaleIdentifiers = Set(
        SFSpeechRecognizer.supportedLocales().map(\.identifier)
    )

    private static func automaticLocale(appLanguage: AppLanguage) -> Locale {
        if let appLocaleIdentifier = appLanguage.localeIdentifier,
           supportedLocaleIdentifiers.contains(appLocaleIdentifier) {
            return Locale(identifier: appLocaleIdentifier)
        }

        let systemLocale = Locale.autoupdatingCurrent
        if supportedLocaleIdentifiers.contains(systemLocale.identifier) {
            return systemLocale
        }

        if let languageCode = systemLocale.language.languageCode?.identifier,
           let matchingIdentifier = supportedLocaleIdentifiers.first(where: {
               Locale(identifier: $0).language.languageCode?.identifier == languageCode
           }) {
            return Locale(identifier: matchingIdentifier)
        }

        let fallbackIdentifier = supportedLocaleIdentifiers.contains("ru-RU")
            ? "ru-RU"
            : "en-US"
        return Locale(identifier: fallbackIdentifier)
    }
}

enum AppAccessibilityTextSize: String, CaseIterable, Identifiable {
    case standard
    case large
    case extraLarge

    var id: Self { self }

    var titleKey: LocalizedStringKey {
        switch self {
        case .standard:
            "Стандартный"
        case .large:
            "Крупный"
        case .extraLarge:
            "Очень крупный"
        }
    }

    func resolvedSize(systemSize: DynamicTypeSize) -> DynamicTypeSize {
        switch self {
        case .standard:
            systemSize
        case .large:
            max(systemSize, .xLarge)
        case .extraLarge:
            max(systemSize, .xxxLarge)
        }
    }
}

struct AppAccessibilityOptions: Equatable, Sendable {
    var reduceMotion = false
    var reduceTransparency = false
    var differentiateWithoutColor = false
    var increaseContrast = false
}

private struct AppAccessibilityOptionsKey: EnvironmentKey {
    static let defaultValue = AppAccessibilityOptions()
}

extension EnvironmentValues {
    var appAccessibilityOptions: AppAccessibilityOptions {
        get { self[AppAccessibilityOptionsKey.self] }
        set { self[AppAccessibilityOptionsKey.self] = newValue }
    }
}
