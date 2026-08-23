import SwiftUI

struct AccessibilitySettingsView: View {
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        WideSettingsLayout {
            WideSettingsSection {
                AccessibilityPreferenceRow(
                    title: "Уменьшение движения",
                    systemImage: "figure.walk.motion",
                    isEnabledInSystem: reduceMotion,
                    isAdditionallyEnabled: $additionallyReduceMotion
                )
                AccessibilityPreferenceRow(
                    title: "Уменьшение прозрачности",
                    systemImage: "circle.dotted.circle",
                    isEnabledInSystem: reduceTransparency,
                    isAdditionallyEnabled: $additionallyReduceTransparency
                )
                AccessibilityPreferenceRow(
                    title: "Различение без цвета",
                    systemImage: "eye",
                    isEnabledInSystem: differentiateWithoutColor,
                    isAdditionallyEnabled: $additionallyDifferentiateWithoutColor
                )
                AccessibilityPreferenceRow(
                    title: "Повышенный контраст",
                    systemImage: "circle.lefthalf.filled",
                    isEnabledInSystem: colorSchemeContrast == .increased,
                    isAdditionallyEnabled: $additionallyIncreaseContrast
                )

                Text("Third Hand автоматически учитывает параметры macOS. Переключатели выше позволяют дополнительно усилить их только внутри приложения.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            WideSettingsSection("Размер текста") {
                Picker("Текст интерфейса", selection: $textSize) {
                    ForEach(AppAccessibilityTextSize.allCases) { option in
                        Text(option.titleKey)
                            .tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Text("Крупный текст применяется к системным стилям шрифта и не уменьшает размер, выбранный в macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            WideSettingsSection("Навигация") {
                LabeledContent("VoiceOver") {
                    Text("Поддерживается системными элементами")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Полный доступ с клавиатуры") {
                    Text("Кнопки и поля доступны по Tab")
                        .foregroundStyle(.secondary)
                }

                Text("Для проверки экранов используйте Accessibility Inspector и VoiceOver из macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AccessibilityPreferenceRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isEnabledInSystem: Bool
    @Binding var isAdditionallyEnabled: Bool

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if isEnabledInSystem {
                    Text("macOS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("", isOn: effectiveBinding)
                    .labelsHidden()
                    .disabled(isEnabledInSystem)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .accessibilityElement(children: .combine)
    }

    private var effectiveBinding: Binding<Bool> {
        Binding(
            get: { isEnabledInSystem || isAdditionallyEnabled },
            set: { isAdditionallyEnabled = $0 }
        )
    }
}
