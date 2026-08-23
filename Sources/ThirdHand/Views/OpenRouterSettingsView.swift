import SwiftUI

struct OpenRouterSettingsView: View {
    @AppStorage(OpenRouterPreferences.handoffEnabledKey)
    private var isHandoffEnabled = false
    @AppStorage(OpenRouterPreferences.handoffModelIDKey)
    private var modelID = ""

    @State private var apiKeyDraft = ""
    @State private var hasStoredKey = false
    @State private var availableModels: [OpenRouterModelOption] = []
    @State private var isLoadingModels = false
    @State private var isShowingModelPicker = false
    @State private var isConfirmingKeyDeletion = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    private let credentialStore = KeychainOpenRouterCredentialStore()
    private let client = OpenRouterAPIClient()

    var body: some View {
        Form {
            Section("Бесшовное переключение") {
                Toggle(
                    "Сжимать контекст через OpenRouter перед Auto failover",
                    isOn: $isHandoffEnabled
                )

                Text("Срабатывает только после подтверждённой ошибки лимита Codex, Claude или Antigravity. Если OpenRouter не ответит, Third Hand сделает локальный handoff и всё равно запустит следующего CLI-агента.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isHandoffEnabled && (!hasStoredKey || normalizedModelID.isEmpty) {
                    Label(
                        "Для удалённого сжатия сохраните ключ и выберите модель.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section("OpenRouter") {
                LabeledContent("API-ключ") {
                    HStack(spacing: 8) {
                        SecureField(
                            "API-ключ OpenRouter",
                            text: $apiKeyDraft,
                            prompt: Text(
                                hasStoredKey ? "Новый ключ для замены" : "sk-or-v1-…"
                            )
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 230)

                        Button(hasStoredKey ? "Заменить" : "Сохранить") {
                            saveAPIKey()
                        }
                        .disabled(normalizedKeyDraft.isEmpty)
                    }
                }

                HStack(spacing: 8) {
                    Label(
                        hasStoredKey ? "Ключ сохранён в Keychain" : "Ключ ещё не сохранён",
                        systemImage: hasStoredKey ? "checkmark.shield" : "key"
                    )
                    .font(.caption)
                    .foregroundStyle(hasStoredKey ? .green : .secondary)

                    Spacer()

                    if hasStoredKey {
                        Button("Удалить ключ…", role: .destructive) {
                            isConfirmingKeyDeletion = true
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                    }
                }

                LabeledContent("Модель для handoff") {
                    HStack(spacing: 8) {
                        TextField(
                            "ID модели OpenRouter",
                            text: $modelID,
                            prompt: Text("provider/model")
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 230)

                        Button("Выбрать…") {
                            isShowingModelPicker = true
                        }
                        .disabled(availableModels.isEmpty)
                    }
                }

                Button {
                    Task { await validateAndLoadModels() }
                } label: {
                    if isLoadingModels {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Проверяем OpenRouter…")
                        }
                    } else {
                        Label("Проверить ключ и загрузить модели", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(!hasStoredKey || isLoadingModels)

                if let statusMessage {
                    Label(
                        statusMessage,
                        systemImage: statusIsError
                            ? "exclamationmark.triangle"
                            : "checkmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .secondary)
                }
            }

            Section("Какие данные уходят") {
                Text("При переключении OpenRouter получает промпт личности, спецификацию, semantic handoff, последние 10 сообщений, ограниченный хвост вывода CLI и Git-сводку. Полный diff и вложения отдельно не отправляются; вывод CLI может содержать фрагменты, которые успел показать агент.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("API-ключ передаётся только OpenRouter в заголовке авторизации, хранится в Keychain и не записывается в UserDefaults или state.json.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear(perform: refreshCredentialState)
        .onChange(of: modelID) { _, value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if value != trimmed && value.hasSuffix("\n") {
                modelID = trimmed
            }
        }
        .sheet(isPresented: $isShowingModelPicker) {
            OpenRouterModelPicker(
                models: availableModels,
                selectedModelID: $modelID
            )
        }
        .confirmationDialog(
            "Удалить API-ключ OpenRouter?",
            isPresented: $isConfirmingKeyDeletion
        ) {
            Button("Удалить ключ", role: .destructive) {
                deleteAPIKey()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Удалённый handoff перестанет работать, пока вы не сохраните новый ключ.")
        }
    }

    private var normalizedKeyDraft: String {
        apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedModelID: String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshCredentialState() {
        do {
            hasStoredKey = try credentialStore.loadAPIKey() != nil
        } catch {
            hasStoredKey = false
            showError(error)
        }
    }

    private func saveAPIKey() {
        do {
            try credentialStore.saveAPIKey(normalizedKeyDraft)
            apiKeyDraft = ""
            hasStoredKey = true
            statusMessage = "Ключ сохранён. Теперь проверьте его и загрузите каталог моделей."
            statusIsError = false
        } catch {
            showError(error)
        }
    }

    private func deleteAPIKey() {
        do {
            try credentialStore.deleteAPIKey()
            apiKeyDraft = ""
            hasStoredKey = false
            availableModels = []
            isHandoffEnabled = false
            statusMessage = "Ключ удалён из Keychain; удалённый handoff выключен."
            statusIsError = false
        } catch {
            showError(error)
        }
    }

    @MainActor
    private func validateAndLoadModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }

        do {
            guard let apiKey = try credentialStore.loadAPIKey() else {
                hasStoredKey = false
                throw OpenRouterCredentialError.emptyKey
            }
            let keyInfo = try await client.validateAPIKey(apiKey)
            availableModels = try await client.fetchModels(apiKey: apiKey)
            let account = keyInfo.label.map { " для «\($0)»" } ?? ""
            statusMessage = "Ключ работает\(account). Загружено моделей: \(availableModels.count)."
            statusIsError = false
        } catch {
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        statusMessage = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        statusIsError = true
    }
}

private struct OpenRouterModelPicker: View {
    let models: [OpenRouterModelOption]
    @Binding var selectedModelID: String

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Модель для сжатия контекста")
                .font(.title3.weight(.semibold))

            TextField("Найти по имени или ID", text: $searchText)
                .textFieldStyle(.roundedBorder)

            List(filteredModels) { model in
                Button {
                    selectedModelID = model.id
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name)
                                .foregroundStyle(.primary)
                            Text(model.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if let contextLength = model.contextLength {
                            Text(contextLength.formatted(.number.notation(.compactName)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }

                        if model.id == selectedModelID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if filteredModels.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }

            HStack {
                Text("Найдено: \(filteredModels.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Закрыть") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 500)
    }

    private var filteredModels: [OpenRouterModelOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }
        return models.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }
}
