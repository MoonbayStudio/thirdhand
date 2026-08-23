import SwiftUI

struct PrivacySettingsView: View {
    @AppStorage("showRawTerminalLogs") private var showRawTerminalLogs = false

    var body: some View {
        WideSettingsLayout {
            WideSettingsSection {
                Toggle("Показывать raw terminal logs", isOn: $showRawTerminalLogs)

                Text("Raw-логи могут содержать секреты и по умолчанию выключены.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
