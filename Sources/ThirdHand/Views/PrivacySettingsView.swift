import SwiftUI

struct PrivacySettingsView: View {
    @AppStorage("showRawTerminalLogs") private var showRawTerminalLogs = false

    var body: some View {
        Form {
            Section("Приватность") {
                Toggle("Показывать raw terminal logs", isOn: $showRawTerminalLogs)
            }

            Section {
                Text("Raw-логи могут содержать секреты и по умолчанию выключены.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
