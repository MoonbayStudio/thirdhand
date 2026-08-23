import Foundation
import SwiftUI
import XCTest
@testable import ThirdHand

final class AppPreferenceModelsTests: XCTestCase {
    func testAppearanceMapsToExpectedColorScheme() {
        XCTAssertNil(AppAppearance.system.colorScheme)
        XCTAssertEqual(AppAppearance.light.colorScheme, .light)
        XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)
    }

    func testAutomaticVoiceLanguageFollowsAppLanguage() {
        XCTAssertEqual(
            VoiceRecognitionLanguage.automatic
                .locale(appLanguage: .russian)
                .identifier,
            "ru-RU"
        )
        XCTAssertEqual(
            VoiceRecognitionLanguage.automatic
                .locale(appLanguage: .english)
                .identifier,
            "en-US"
        )
    }

    func testExplicitVoiceLanguagesDoNotDependOnInterfaceLanguage() {
        XCTAssertEqual(
            VoiceRecognitionLanguage.german
                .locale(appLanguage: .russian)
                .identifier,
            "de-DE"
        )
        XCTAssertEqual(
            VoiceRecognitionLanguage.spanish
                .locale(appLanguage: .english)
                .identifier,
            "es-ES"
        )
        XCTAssertEqual(
            VoiceRecognitionLanguage.japanese
                .locale(appLanguage: .russian)
                .identifier,
            "ja-JP"
        )
        XCTAssertEqual(
            VoiceRecognitionLanguage.portugueseBrazil
                .locale(appLanguage: .english)
                .identifier,
            "pt-BR"
        )
    }

    func testAccessibilityTextSizeNeverShrinksSystemChoice() {
        XCTAssertEqual(
            AppAccessibilityTextSize.standard.resolvedSize(systemSize: .accessibility2),
            .accessibility2
        )
        XCTAssertGreaterThanOrEqual(
            AppAccessibilityTextSize.large.resolvedSize(systemSize: .large),
            .xLarge
        )
        XCTAssertGreaterThanOrEqual(
            AppAccessibilityTextSize.extraLarge.resolvedSize(systemSize: .large),
            .xxxLarge
        )
    }

    func testEnglishSettingsLocalizationIsBundled() {
        let value = AppLocalization.string(
            "Внешний вид",
            language: .english
        )

        XCTAssertEqual(value, "Appearance")
    }

    func testRussianCatalogDoesNotFallBackToEnglish() {
        let value = AppLocalization.string(
            "Внешний вид",
            language: .russian
        )

        XCTAssertEqual(value, "Внешний вид")
    }

    func testEverySelectableLanguageHasACompleteResourceCatalog() {
        let languages = AppLanguage.allCases.filter { $0 != .system }
        XCTAssertEqual(languages.count, 19)
        XCTAssertEqual(VoiceRecognitionLanguage.allCases.count, 20)

        for language in languages {
            guard let localization = language.resourceLocalization else {
                return XCTFail("Missing resource localization for \(language)")
            }
            XCTAssertNotNil(
                Bundle.module.path(forResource: localization, ofType: "lproj"),
                "Missing bundled catalog for \(language)"
            )

            let localizedSettings = AppLocalization.string(
                "Настройки",
                language: language
            )
            XCTAssertFalse(localizedSettings.isEmpty)

            let interpolated = AppLocalization.string(
                "Сообщение для \("Muni")…",
                language: language
            )
            XCTAssertTrue(
                interpolated.contains("Muni"),
                "Interpolation was lost for \(language): \(interpolated)"
            )
        }
    }

    func testNewRegionalLanguagesUseExpectedLocales() {
        XCTAssertEqual(AppLanguage.belarusian.locale.identifier, "be-BY")
        XCTAssertEqual(AppLanguage.kazakh.locale.identifier, "kk-KZ")
        XCTAssertEqual(AppLanguage.uzbek.locale.identifier, "uz-UZ")
        XCTAssertEqual(AppLanguage.kyrgyz.locale.identifier, "ky-KG")
        XCTAssertEqual(AppLanguage.tajik.locale.identifier, "tg-TJ")
        XCTAssertEqual(AppLanguage.turkmen.locale.identifier, "tk-TM")
    }

    func testVoicePickerOnlyOffersLocalesSupportedByMacOS() {
        XCTAssertTrue(VoiceRecognitionLanguage.availableCases.contains(.automatic))
        XCTAssertTrue(
            VoiceRecognitionLanguage.availableCases
                .filter { $0 != .automatic }
                .allSatisfy(\.isSupportedOnCurrentSystem)
        )
    }

    func testCommonPlatformTermsUseReviewedTranslations() {
        XCTAssertEqual(
            AppLocalization.string("Универсальный доступ", language: .german),
            "Bedienungshilfen"
        )
        XCTAssertEqual(
            AppLocalization.string("Внешний вид", language: .chineseSimplified),
            "外观"
        )
        XCTAssertEqual(
            AppLocalization.string("Приватность", language: .korean),
            "개인정보 보호"
        )
        XCTAssertEqual(
            AppLocalization.string("Настройки", language: .belarusian),
            "Налады"
        )
        XCTAssertEqual(
            AppLocalization.string("Универсальный доступ", language: .kazakh),
            "Арнайы мүмкіндіктер"
        )
        XCTAssertEqual(
            AppLocalization.string("Внешний вид", language: .uzbek),
            "Tashqi ko‘rinish"
        )
        XCTAssertEqual(
            AppLocalization.string("Приватность", language: .kyrgyz),
            "Купуялык"
        )
        XCTAssertEqual(
            AppLocalization.string("Язык", language: .tajik),
            "Забон"
        )
        XCTAssertEqual(
            AppLocalization.string("Сочетания клавиш", language: .turkmen),
            "Klawiatura gysga ýollary"
        )
    }

    func testInterpolatedEnglishLocalizationUsesSelectedAppLanguage() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppPreferenceKeys.language)
        defaults.set(AppLanguage.english.rawValue, forKey: AppPreferenceKeys.language)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppPreferenceKeys.language)
            } else {
                defaults.removeObject(forKey: AppPreferenceKeys.language)
            }
        }

        XCTAssertEqual(
            AppLocalization.string("Сообщение для \("Muni")…"),
            "Message Muni…"
        )
        XCTAssertEqual(
            AppLocalization.string("Агент \("Muni"), \("Online")"),
            "Agent Muni, Online"
        )
    }

    func testSettingsExposeAllRequestedSections() {
        XCTAssertTrue(SettingsSection.allCases.contains(.appearance))
        XCTAssertTrue(SettingsSection.allCases.contains(.voiceInput))
        XCTAssertTrue(SettingsSection.allCases.contains(.accessibility))
        XCTAssertTrue(SettingsSection.allCases.contains(.keyboardShortcuts))
        XCTAssertTrue(SettingsSection.allCases.contains(.language))
    }
}
