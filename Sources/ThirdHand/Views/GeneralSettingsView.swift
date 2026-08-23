import SwiftUI
import UniformTypeIdentifiers

struct GeneralSettingsView: View {
    @AppStorage("defaultRepositoriesFolderPath") private var defaultRepositoriesFolderPath = ""
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("notificationQuestionsEnabled") private var notificationQuestions = true
    @AppStorage("notificationAttentionEnabled") private var notificationAttention = true
    @AppStorage("notificationResultsEnabled") private var notificationResults = true
    @AppStorage("notificationCompletionEnabled") private var notificationCompletion = true

    @State private var isChoosingRepositoriesFolder = false
    @State private var notificationPermissionWasDenied = false

    var body: some View {
        WideSettingsLayout {
            WideSettingsSection("Выполнение") {
                LabeledContent("Checkpoint при передаче") {
                    Text("Всегда")
                        .foregroundStyle(.secondary)
                }

                Text("Активная попытка продолжает работу после закрытия окна, пока сам процесс Third Hand остаётся запущен. Полный Quit завершает Runner этой версии.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            WideSettingsSection("Репозитории") {
                LabeledContent("Папка по умолчанию") {
                    HStack(spacing: 8) {
                        if defaultRepositoriesFolderPath.isEmpty {
                            Text("Не выбрана")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(defaultRepositoriesFolderPath)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        if !defaultRepositoriesFolderPath.isEmpty {
                            Button {
                                defaultRepositoriesFolderPath = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Сбросить папку")
                        }

                        Button("Выбрать…") {
                            isChoosingRepositoriesFolder = true
                        }
                    }
                }

                Text("Эта папка будет автоматически выбрана при создании новой задачи.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            WideSettingsSection("Уведомления") {
                Toggle("Разрешить уведомления", isOn: $notificationsEnabled)

                Toggle("Когда требуется ответ", isOn: $notificationQuestions)
                    .disabled(!notificationsEnabled)
                Toggle("Когда задача требует внимания", isOn: $notificationAttention)
                    .disabled(!notificationsEnabled)
                Toggle("Когда ответ агента готов", isOn: $notificationResults)
                    .disabled(!notificationsEnabled)
                Toggle("Когда задача завершена", isOn: $notificationCompletion)
                    .disabled(!notificationsEnabled)

                Text("Уведомления не содержат prompt, diff или terminal logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if notificationPermissionWasDenied {
                    Label(
                        "macOS не разрешила уведомления для Third Hand.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)

                    Link(
                        "Открыть настройки уведомлений macOS",
                        destination: URL(
                            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
                        )!
                    )
                    .font(.caption)
                }
            }
        }
        .fileImporter(
            isPresented: $isChoosingRepositoriesFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let folder = urls.first {
                defaultRepositoriesFolderPath = folder.path(percentEncoded: false)
            }
        }
        .onChange(of: notificationsEnabled) { _, enabled in
            guard enabled else { return }
            Task {
                notificationPermissionWasDenied = false
                let granted = await SystemTaskNotificationService.shared
                    .requestAuthorization()
                if !granted {
                    notificationsEnabled = false
                    notificationPermissionWasDenied = true
                }
            }
        }
    }
}
