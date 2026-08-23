import SwiftUI

struct KeyboardShortcutsSettingsView: View {
    @AppStorage(AppPreferenceKeys.keyboardShortcutsEnabled)
    private var shortcutsEnabled = true

    var body: some View {
        WideSettingsLayout {
            WideSettingsSection {
                Toggle("Использовать сочетания клавиш", isOn: $shortcutsEnabled)

                Text("Пункты меню останутся доступны мышью, даже если сочетания выключены.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            WideSettingsSection("Основные действия") {
                ShortcutSettingsRow(title: "Настройки", keys: ["⌘", ","])
                ShortcutSettingsRow(title: "Создать агента", keys: ["⌘", "N"])
                ShortcutSettingsRow(title: "Подготовить агента", keys: ["⌘", "↩"])
                ShortcutSettingsRow(title: "Остановить агента", keys: ["⌘", "."])
                ShortcutSettingsRow(title: "Создать checkpoint", keys: ["⇧", "⌘", "S"])
                ShortcutSettingsRow(title: "Показать или скрыть профиль", keys: ["⇧", "⌘", "I"])
                ShortcutSettingsRow(title: "Удалить агента", keys: ["⌘", "⌫"])
            }

            WideSettingsSection("Поле сообщения") {
                ShortcutSettingsRow(title: "Отправить сообщение", keys: ["↩"])
                ShortcutSettingsRow(title: "Новая строка", keys: ["⌥", "↩"])

                Text("Кнопка микрофона управляет записью голосом и остаётся доступна с клавиатуры через Tab и пробел.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ShortcutSettingsRow: View {
    let title: LocalizedStringKey
    let keys: [String]

    var body: some View {
        LabeledContent {
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(.caption.monospaced().weight(.medium))
                        .frame(minWidth: 24, minHeight: 22)
                        .padding(.horizontal, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .accessibilityElement(children: .combine)
        } label: {
            Text(title)
        }
    }
}
