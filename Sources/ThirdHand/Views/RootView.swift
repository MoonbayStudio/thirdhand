import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var store = store

        GeometryReader { geometry in
            Group {
                if store.isShowingSettings {
                    SettingsScreen()
                } else {
                    NavigationSplitView(columnVisibility: $columnVisibility) {
                        SidebarView()
                            .frame(minWidth: 190)
                            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 210)
                    } detail: {
                        Group {
                            if let agent = store.selectedTask {
                                TaskDetailView(task: agent)
                            } else {
                                EmptyTaskView()
                            }
                        }
                        .frame(minWidth: 360)
                        .navigationSplitViewColumnWidth(
                            min: 360,
                            ideal: 520,
                            max: .infinity
                        )
                    }
                    .inspector(isPresented: $store.isShowingInspector) {
                        Group {
                            if let agent = store.selectedTask {
                                AgentProfileInspectorView(task: agent)
                                    .id(agent.id)
                            } else {
                                ContentUnavailableView {
                                    Label("Профиль агента", systemImage: "person.crop.circle")
                                } description: {
                                    Text("Выберите или создайте агента.")
                                }
                            }
                        }
                        .frame(minWidth: 260)
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 400)
                    }
                    .toolbarBackground(.hidden, for: .windowToolbar)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear {
                adaptColumns(to: geometry.size.width)
            }
            .onChange(of: geometry.size.width) { _, width in
                adaptColumns(to: width)
            }
            .background(
                MacWindowChromeConfigurator(
                    title: store.isShowingSettings
                        ? "Настройки"
                        : store.selectedTask?.title ?? "Third Hand"
                )
            )
            .alert(
                "Удалить агента?",
                isPresented: Binding(
                    get: { store.taskPendingDeletion != nil },
                    set: { if !$0 { store.cancelTaskDeletion() } }
                )
            ) {
                Button("Удалить", role: .destructive) {
                    store.confirmTaskDeletion()
                }
                Button("Отмена", role: .cancel) {
                    store.cancelTaskDeletion()
                }
            } message: {
                Text(deletionMessage)
            }
            .alert(
                "Third Hand требует внимания",
                isPresented: Binding(
                    get: { store.lastError != nil },
                    set: { if !$0 { store.lastError = nil } }
                )
            ) {
                Button("OK") {
                    store.lastError = nil
                }
            } message: {
                Text(store.lastError ?? "")
            }
        }
    }

    private var deletionMessage: String {
        guard let taskID = store.taskPendingDeletion,
              let agent = store.tasks.first(where: { $0.id == taskID })
        else {
            return "Будет удалён профиль и история чата. Файлы рабочей папки останутся на месте."
        }
        return "«\(agent.title)» и история этого чата будут удалены из Third Hand. Репозиторий и его файлы останутся на месте."
    }

    private func adaptColumns(to width: CGFloat) {
        if width < 1_100, columnVisibility != .doubleColumn {
            columnVisibility = .doubleColumn
        } else if width > 1_180, columnVisibility != .all {
            columnVisibility = .all
        }
    }
}
