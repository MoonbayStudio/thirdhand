import SwiftUI

struct EmptyTaskView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label("Создайте первого агента", systemImage: "person.crop.circle.badge.plus")
        } description: {
            Text("Дайте ему имя, аватар, характер и модель — затем общайтесь в отдельном чате.")
        } actions: {
            Button("Создать агента") {
                store.beginAgentCreation()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
                ToolbarItem {
                    InspectorToggleButton()
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    InspectorToggleButton()
                }
            }
        }
    }
}
