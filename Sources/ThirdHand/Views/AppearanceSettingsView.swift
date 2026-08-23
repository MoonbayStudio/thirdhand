import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage(AppPreferenceKeys.appearance)
    private var appearance: AppAppearance = .system

    var body: some View {
        WideSettingsLayout {
            WideSettingsSection {
                HStack(spacing: 12) {
                    ForEach(AppAppearance.allCases) { option in
                        AppearancePreview(
                            appearance: option,
                            isSelected: appearance == option
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            appearance = option
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAddTraits(
                            appearance == option ? .isSelected : []
                        )
                        .accessibilityLabel(option.titleKey)
                        .accessibilityValue(
                            appearance == option ? "Выбрано" : ""
                        )
                    }
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Оформление приложения")

                Text("Системная тема автоматически следует настройке оформления macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AppearancePreview: View {
    @Environment(\.colorScheme) private var inheritedColorScheme

    let appearance: AppAppearance
    let isSelected: Bool

    private var previewScheme: ColorScheme {
        appearance.colorScheme ?? inheritedColorScheme
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red.opacity(0.9))
                Circle()
                    .fill(Color.yellow.opacity(0.9))
                Circle()
                    .fill(Color.green.opacity(0.9))
                Spacer()
            }
            .frame(height: 8)

            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 31)

                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.72))
                        .frame(width: 58, height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.24))
                        .frame(height: 27)
                }
            }

            Text(appearance.titleKey)
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 112)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: isSelected ? 2 : 0.5
                )
        }
        .environment(\.colorScheme, previewScheme)
    }
}
