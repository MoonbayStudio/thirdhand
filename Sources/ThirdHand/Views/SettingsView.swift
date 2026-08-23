import SwiftUI

struct SettingsView: View {
    let section: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.titleKey)
                .font(.system(size: 26, weight: .semibold))
                .padding(.horizontal, 76)
                .padding(.top, 20)
                .padding(.bottom, 8)

            Group {
                switch section {
                case .general:
                    GeneralSettingsView()
                case .appearance:
                    AppearanceSettingsView()
                case .language:
                    LanguageSettingsView()
                case .voiceInput:
                    VoiceInputSettingsView()
                case .accessibility:
                    AccessibilitySettingsView()
                case .keyboardShortcuts:
                    KeyboardShortcutsSettingsView()
                case .privacy:
                    PrivacySettingsView()
                case .api:
                    APISettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            DetailCanvasBackground()
        }
    }
}
