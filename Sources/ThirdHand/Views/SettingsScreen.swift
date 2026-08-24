import SwiftUI

enum SettingsSection: String, CaseIterable, Hashable, Identifiable {
    case general
    case appearance
    case language
    case voiceInput
    case accessibility
    case keyboardShortcuts
    case privacy
    case api

    var id: Self { self }

    var title: String {
        switch self {
        case .general:
            "Общее"
        case .appearance:
            "Внешний вид"
        case .language:
            "Язык"
        case .voiceInput:
            "Голосовой ввод"
        case .accessibility:
            "Универсальный доступ"
        case .keyboardShortcuts:
            "Сочетания клавиш"
        case .privacy:
            "Приватность"
        case .api:
            "API"
        }
    }

    var titleKey: LocalizedStringKey {
        LocalizedStringKey(title)
    }

    var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .appearance:
            "circle.lefthalf.filled"
        case .language:
            "globe"
        case .voiceInput:
            "mic"
        case .accessibility:
            "accessibility"
        case .keyboardShortcuts:
            "command"
        case .privacy:
            "hand.raised"
        case .api:
            "key.horizontal"
        }
    }

    var searchTerms: String {
        switch self {
        case .general:
            "общее основные выполнение репозитории папка уведомления general repositories notifications"
        case .appearance:
            "внешний вид тема светлая темная тёмная системная appearance theme light dark system"
        case .language:
            "язык русский english deutsch français español italiano português polski türkçe українська беларуская қазақша o‘zbekcha кыргызча тоҷикӣ türkmençe 中文 日本語 한국어 locale"
        case .voiceInput:
            "голос голосовой ввод микрофон диктовка распознавание речь voice microphone dictation speech"
        case .accessibility:
            "универсальный доступ движение прозрачность контраст размер текста voiceover accessibility motion contrast text"
        case .keyboardShortcuts:
            "сочетания клавиш горячие command shortcut keyboard хоткеи"
        case .privacy:
            "приватность terminal logs логи секреты privacy"
        case .api:
            "api апи ключ openrouter deepseek dsh openai anthropic claude gemini авто handoff модели провайдеры лимиты"
        }
    }

    var category: SettingsCategory {
        switch self {
        case .general, .appearance, .language, .voiceInput, .accessibility, .keyboardShortcuts:
            .application
        case .privacy, .api:
            .intelligenceAndData
        }
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case application
    case intelligenceAndData

    var id: Self { self }

    var titleKey: LocalizedStringKey {
        switch self {
        case .application:
            "Приложение"
        case .intelligenceAndData:
            "ИИ и данные"
        }
    }
}

struct SettingsScreen: View {
    @Environment(AppStore.self) private var store

    @State private var selection: SettingsSection? = .general
    @State private var searchText = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SettingsSidebar(
                selection: $selection,
                searchText: $searchText,
                onClose: closeSettings
            )
            .frame(minWidth: 250)
            .navigationSplitViewColumnWidth(min: 250, ideal: 270, max: 310)
        } detail: {
            SettingsView(section: selection ?? .general)
                .frame(minWidth: 360)
                .navigationSplitViewColumnWidth(
                    min: 360,
                    ideal: 760,
                    max: .infinity
                )
        }
        .navigationTitle("")
        .toolbar(removing: .sidebarToggle)
        .toolbarBackground(.hidden, for: .windowToolbar)
    }

    private func closeSettings() {
        store.isShowingSettings = false
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection?
    @Binding var searchText: String

    let onClose: () -> Void

    private var filteredSections: [SettingsSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SettingsSection.allCases }

        return SettingsSection.allCases.filter { section in
            section.title.localizedCaseInsensitiveContains(query)
                || section.searchTerms.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredCategories: [SettingsCategory] {
        SettingsCategory.allCases.filter { category in
            filteredSections.contains { $0.category == category }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(verbatim: "Third Hand")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)

                Button(action: onClose) {
                    Label("Вернуться в приложение", systemImage: "chevron.left")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .help("Вернуться к чатам")
                .accessibilityIdentifier("close-settings-button")

                TextField("Поиск настроек…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings-search-field")
            }
            .padding(.horizontal, 12)
            .padding(.top, 20)
            .padding(.bottom, 10)

            if filteredSections.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(filteredCategories) { category in
                        Section {
                            ForEach(filteredSections.filter { $0.category == category }) { section in
                                Label {
                                    Text(section.titleKey)
                                } icon: {
                                    Image(systemName: section.systemImage)
                                }
                                .tag(section)
                            }
                        } header: {
                            Text(category.titleKey)
                        }
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("settings-section-list")
            }
        }
    }
}
