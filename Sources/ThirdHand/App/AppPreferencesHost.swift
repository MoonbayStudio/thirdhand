import SwiftUI

/// Applies durable presentation and accessibility preferences at the window root.
/// Accessibility additions are combined with macOS values, so an app setting can
/// never turn off a system accommodation selected by the user.
struct AppPreferencesHost<Content: View>: View {
    @AppStorage(AppPreferenceKeys.appearance)
    private var appearance: AppAppearance = .system
    @AppStorage(AppPreferenceKeys.language)
    private var language: AppLanguage = .russian
    @AppStorage(AppPreferenceKeys.reduceMotion)
    private var additionallyReduceMotion = false
    @AppStorage(AppPreferenceKeys.reduceTransparency)
    private var additionallyReduceTransparency = false
    @AppStorage(AppPreferenceKeys.differentiateWithoutColor)
    private var additionallyDifferentiateWithoutColor = false
    @AppStorage(AppPreferenceKeys.increaseContrast)
    private var additionallyIncreaseContrast = false
    @AppStorage(AppPreferenceKeys.textSize)
    private var textSize: AppAccessibilityTextSize = .standard

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor) private var systemDifferentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var systemColorSchemeContrast
    @Environment(\.dynamicTypeSize) private var systemDynamicTypeSize

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let accessibilityOptions = AppAccessibilityOptions(
            reduceMotion: systemReduceMotion || additionallyReduceMotion,
            reduceTransparency: systemReduceTransparency || additionallyReduceTransparency,
            differentiateWithoutColor: systemDifferentiateWithoutColor
                || additionallyDifferentiateWithoutColor,
            increaseContrast: systemColorSchemeContrast == .increased
                || additionallyIncreaseContrast
        )

        content
            .preferredColorScheme(appearance.colorScheme)
            .environment(\.locale, language.locale)
            .environment(\.appAccessibilityOptions, accessibilityOptions)
            .environment(
                \.dynamicTypeSize,
                textSize.resolvedSize(systemSize: systemDynamicTypeSize)
            )
            .contrast(accessibilityOptions.increaseContrast ? 1.08 : 1)
    }
}
