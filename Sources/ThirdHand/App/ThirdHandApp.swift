import SwiftUI

@main
@MainActor
struct ThirdHandApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = AppStore(
        handoffCompressor: OpenRouterHandoffService()
    )
    @NSApplicationDelegateAdaptor(ThirdHandAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Third Hand", id: "main") {
            RootView()
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
                    appDelegate.currentTaskID = store.selection
                    if scenePhase == .active {
                        store.startUsageAutoRefresh()
                    }
                }
                .onChange(of: store.selection) { _, selection in
                    appDelegate.currentTaskID = selection
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        store.startUsageAutoRefresh()
                    } else {
                        store.stopUsageAutoRefresh()
                    }
                }
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") {
                    store.isShowingSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandMenu("Агент") {
                Button("Создать агента") {
                    store.beginAgentCreation()
                }
                .keyboardShortcut("n")

                Divider()

                Button("Подготовить агента к работе") {
                    guard let id = store.selection else { return }
                    store.startOrResume(id)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(store.selection == nil)

                Button("Остановить агента") {
                    guard let id = store.selection else { return }
                    store.pause(id)
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(store.selection == nil)

                Button("Создать checkpoint чата") {
                    guard let id = store.selection else { return }
                    store.createCheckpoint(id)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(store.selection == nil)

                Divider()

                Button("Удалить агента…", role: .destructive) {
                    store.deleteSelectedTask()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(store.selection == nil)
            }
        }
    }
}
