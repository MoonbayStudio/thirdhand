import SwiftUI

enum SettingsSection: String, CaseIterable, Hashable, Identifiable {
    case general
    case privacy
    case automaticRouting
    case handoff

    var id: Self { self }

    var title: String {
        switch self {
        case .general:
            "Общее"
        case .privacy:
            "Приватность"
        case .automaticRouting:
            "Авто"
        case .handoff:
            "Handoff"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .privacy:
            "hand.raised"
        case .automaticRouting:
            "arrow.triangle.2.circlepath"
        case .handoff:
            "arrow.left.arrow.right.circle"
        }
    }

    var searchTerms: String {
        switch self {
        case .general:
            "общее основные выполнение репозитории папка уведомления"
        case .privacy:
            "приватность terminal logs логи секреты"
        case .automaticRouting:
            "авто порядок провайдеров codex claude antigravity лимиты"
        case .handoff:
            "handoff openrouter api ключ модель сжатие контекста"
        }
    }
}

struct SettingsScreen: View {
    @Environment(AppStore.self) private var store

    @State private var selection: SettingsSection? = .general
    @State private var searchText = ""

    var body: some View {
        HSplitView {
            SettingsSidebar(
                selection: $selection,
                searchText: $searchText,
                onClose: closeSettings
            )
            .frame(minWidth: 232, idealWidth: 252, maxWidth: 284)

            SettingsView(section: selection ?? .general)
                .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            DetailCanvasBackground()
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

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
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
            .padding(.top, 48)
            .padding(.bottom, 10)

            if filteredSections.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    Section("Настройки") {
                        ForEach(filteredSections) { section in
                            Label(section.title, systemImage: section.systemImage)
                                .tag(section)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("settings-section-list")
            }
        }
    }
}
