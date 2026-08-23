import SwiftUI

struct LanguageSettingsView: View {
    @AppStorage(AppPreferenceKeys.language)
    private var language: AppLanguage = .russian

    var body: some View {
        WideSettingsLayout {
            WideSettingsSection {
                Picker("Язык интерфейса", selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.displayNameKey)
                            .tag(option)
                    }
                }
                .pickerStyle(.menu)

                Text("Язык меняется сразу для локализованных частей интерфейса. Новые переводы будут добавляться в тот же каталог без изменения настроек пользователя.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
