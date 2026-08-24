import SwiftUI

@main
@MainActor
struct ThirdHandApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppPreferenceKeys.language)
    private var appLanguage: AppLanguage = .russian
    @AppStorage(AppPreferenceKeys.keyboardShortcutsEnabled)
    private var keyboardShortcutsEnabled = true
    @State private var store = AppStore(
        handoffCompressor: MultiProviderAPIService(),
        conversationResponder: MultiProviderAPIService(),
        apiExecutor: MultiProviderAPIService()
    )
    @NSApplicationDelegateAdaptor(ThirdHandAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Third Hand", id: "main") {
            AppPreferencesHost {
                AppLaunchView()
                    .environment(store)
                    .frame(
                        minWidth: 1_040,
                        maxWidth: .infinity,
                        minHeight: 680,
                        maxHeight: .infinity
                    )
                    .ignoresSafeArea(.container, edges: .top)
                    .onAppear {
                        appDelegate.onOpenTask = { taskID in
                            store.openTaskFromNotification(taskID)
                        }
                        appDelegate.currentTaskID = store.selectedTask?.id
                        if scenePhase == .active {
                            store.startUsageAutoRefresh()
                        }
                    }
                    .onChange(of: store.selection) { _, selection in
                        appDelegate.currentTaskID = store.selectedTask?.id
                    }
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active {
                            store.startUsageAutoRefresh()
                        } else {
                            store.stopUsageAutoRefresh()
                        }
                    }
            }
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                if keyboardShortcutsEnabled {
                    Button(localized("Настройки…")) {
                        store.isShowingSettings = true
                    }
                    .keyboardShortcut(",", modifiers: .command)
                } else {
                    Button(localized("Настройки…")) {
                        store.isShowingSettings = true
                    }
                }
            }

            CommandMenu(localized("Агент")) {
                if keyboardShortcutsEnabled {
                    Button(localized("Создать агента")) {
                        store.beginAgentCreation()
                    }
                    .keyboardShortcut("n")
                } else {
                    Button(localized("Создать агента")) {
                        store.beginAgentCreation()
                    }
                }

                if keyboardShortcutsEnabled {
                    Button("Создать групповой чат…") {
                        store.isShowingNewGroupChatSheet = true
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                } else {
                    Button("Создать групповой чат…") {
                        store.isShowingNewGroupChatSheet = true
                    }
                }

                Divider()

                if keyboardShortcutsEnabled {
                    Button(localized("Подготовить агента к работе")) {
                        guard let id = store.selection else { return }
                        store.startOrResume(id)
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(store.selectedTask == nil)
                } else {
                    Button(localized("Подготовить агента к работе")) {
                        guard let id = store.selection else { return }
                        store.startOrResume(id)
                    }
                    .disabled(store.selectedTask == nil)
                }

                if keyboardShortcutsEnabled {
                    Button(localized("Остановить агента")) {
                        guard let id = store.selection else { return }
                        if store.selectedGroupChat != nil {
                            Task { await store.stopGroupChat(groupID: id) }
                        } else {
                            store.pause(id)
                        }
                    }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(
                        store.selectedTask == nil
                            && store.selectedGroupChat.map {
                                store.activeGroupRuns[$0.id] == nil
                            } != false
                    )
                } else {
                    Button(localized("Остановить агента")) {
                        guard let id = store.selection else { return }
                        if store.selectedGroupChat != nil {
                            Task { await store.stopGroupChat(groupID: id) }
                        } else {
                            store.pause(id)
                        }
                    }
                    .disabled(
                        store.selectedTask == nil
                            && store.selectedGroupChat.map {
                                store.activeGroupRuns[$0.id] == nil
                            } != false
                    )
                }

                if keyboardShortcutsEnabled {
                    Button(localized("Создать checkpoint чата")) {
                        guard let id = store.selection else { return }
                        store.createCheckpoint(id)
                    }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(store.selectedTask == nil)
                } else {
                    Button(localized("Создать checkpoint чата")) {
                        guard let id = store.selection else { return }
                        store.createCheckpoint(id)
                    }
                    .disabled(store.selectedTask == nil)
                }

                if keyboardShortcutsEnabled {
                    Button(localized("Показать или скрыть профиль")) {
                        store.isShowingInspector.toggle()
                    }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(store.selection == nil || store.isShowingSettings)
                } else {
                    Button(localized("Показать или скрыть профиль")) {
                        store.isShowingInspector.toggle()
                    }
                    .disabled(store.selection == nil || store.isShowingSettings)
                }

                Divider()

                if keyboardShortcutsEnabled {
                    Button(localized("Удалить агента…"), role: .destructive) {
                        store.deleteSelectedTask()
                    }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(store.selection == nil)
                } else {
                    Button(localized("Удалить агента…"), role: .destructive) {
                        store.deleteSelectedTask()
                    }
                    .disabled(store.selection == nil)
                }
            }
        }
    }

    private func localized(_ key: String.LocalizationValue) -> String {
        AppLocalization.string(key, language: appLanguage)
    }
}
