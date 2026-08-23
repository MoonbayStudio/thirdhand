import SwiftUI

struct APISettingsView: View {
    @AppStorage(AIAPIPreferences.automaticFallbackEnabledKey)
    private var isAutomaticFallbackEnabled = true
    @AppStorage(AIAPIPreferences.casualConversationEnabledKey)
    private var isCasualConversationEnabled = true
    @AppStorage(AIAPIPreferences.preferredProviderKey)
    private var preferredProviderRaw = AIAPIProvider.openRouter.rawValue
    @AppStorage(AIAPIPreferences.handoffEnabledKey)
    private var isHandoffEnabled = false
    @AppStorage(AIAPIPreferences.handoffProviderKey)
    private var handoffProviderRaw = AIAPIProvider.openRouter.rawValue
    @AppStorage(AIAPIPreferences.handoffModelIDKey)
    private var handoffModelID = ""

    @State private var automaticAgentOrder = AgentRoutingPreferences.load()
    @State private var isShowingHandoffModelPicker = false
    @State private var handoffModels: [AIAPIModelOption] = []

    private var preferredProvider: AIAPIProvider {
        AIAPIProvider(rawValue: preferredProviderRaw) ?? .openRouter
    }

    private var handoffProvider: AIAPIProvider {
        AIAPIProvider(rawValue: handoffProviderRaw) ?? .openRouter
    }

    var body: some View {
        WideSettingsLayout {
            WideSettingsSection("Исполнение агентов") {
                Toggle(
                    "Добавлять подключённые API в конец очереди Auto",
                    isOn: $isAutomaticFallbackEnabled
                )

                Text("Сначала Third Hand использует доступные CLI в порядке ниже. При подтверждённом лимите — продолжает через API. Если CLI не установлен, Auto сразу использует первый настроенный API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(Array(automaticAgentOrder.enumerated()), id: \.element) { index, agent in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        Label("\(agent.displayName) · CLI", systemImage: agent.systemImage)
                            .foregroundStyle(agent.tint)

                        Spacer()

                        Button {
                            moveAgent(at: index, by: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.plain)
                        .disabled(index == automaticAgentOrder.startIndex)
                        .help("Поднять в очереди")

                        Button {
                            moveAgent(at: index, by: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.plain)
                        .disabled(index == automaticAgentOrder.index(before: automaticAgentOrder.endIndex))
                        .help("Опустить в очереди")
                    }
                    .padding(.vertical, 2)
                }

                Picker("Основной API", selection: $preferredProviderRaw) {
                    ForEach(AIAPIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }

                Toggle(
                    "Обычные разговоры в Auto отвечать через основной API",
                    isOn: $isCasualConversationEnabled
                )

                Text("У каждого агента в профиле можно отдельно закрепить CLI или конкретный API с моделью. Эта настройка влияет только на Auto.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            WideSettingsSection("Handoff") {
                Toggle(
                    "Сжимать контекст через API перед переключением",
                    isOn: $isHandoffEnabled
                )

                Picker("Провайдер", selection: $handoffProviderRaw) {
                    ForEach(AIAPIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .onChange(of: handoffProviderRaw) { _, _ in
                    handoffModelID = AIAPIPreferences.primaryModelID(for: handoffProvider)
                }

                LabeledContent("Модель") {
                    HStack(spacing: 8) {
                        TextField("ID модели", text: $handoffModelID)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 220, idealWidth: 360)

                        Button("Выбрать…") {
                            handoffModels = AIAPIPreferences.cachedModels(for: handoffProvider)
                            isShowingHandoffModelPicker = true
                        }
                        .disabled(AIAPIPreferences.cachedModels(for: handoffProvider).isEmpty)
                    }
                }

                if isHandoffEnabled && handoffModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("Выберите модель для Handoff.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text("Handoff работает между CLI и API в обе стороны. Если выбранная модель недоступна, Third Hand передаст локальный контекст и всё равно попробует следующий маршрут.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            WideSettingsSection("Подключения API") {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 360), spacing: 14)],
                    alignment: .leading,
                    spacing: 14
                ) {
                    ForEach(AIAPIProvider.allCases) { provider in
                        APIProviderSettingsCard(
                            provider: provider,
                            isPreferred: preferredProvider == provider
                        )
                    }
                }
                .padding(.vertical, 6)
            }

            WideSettingsSection("Данные и ключи") {
                Text("API-ключи хранятся отдельно для каждого провайдера в Keychain. В настройки и файл состояния записываются только выбранные модели и кеш каталога — сами ключи туда не попадают.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("API-агент получает инструкции личности, историю текущего чата и подготовленный контекст задачи. Для проектного сценария в запрос также входит Git-сводка и доступный текстовый контекст; сама API-модель не получает прямого доступа к вашему терминалу или файловой системе.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: migrateLegacySettings)
        .sheet(isPresented: $isShowingHandoffModelPicker) {
            APIModelPicker(
                title: "Модель для Handoff",
                models: handoffModels,
                selectedModelID: $handoffModelID
            )
        }
    }

    private func moveAgent(at index: Int, by offset: Int) {
        let destination = index + offset
        guard automaticAgentOrder.indices.contains(index),
              automaticAgentOrder.indices.contains(destination)
        else { return }
        automaticAgentOrder.swapAt(index, destination)
        AgentRoutingPreferences.save(automaticAgentOrder)
    }

    private func migrateLegacySettings() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: AIAPIPreferences.handoffEnabledKey) == nil {
            isHandoffEnabled = defaults.bool(forKey: OpenRouterPreferences.handoffEnabledKey)
        }
        if defaults.object(forKey: AIAPIPreferences.casualConversationEnabledKey) == nil {
            isCasualConversationEnabled = OpenRouterPreferences
                .loadConversation(defaults: defaults)
                .isEnabled
        }
        if handoffModelID.isEmpty {
            handoffModelID = AIAPIPreferences.handoffTarget(defaults: defaults)?.modelID
                ?? AIAPIPreferences.primaryModelID(for: handoffProvider, defaults: defaults)
        }
    }
}

private struct APIProviderSettingsCard: View {
    let provider: AIAPIProvider
    let isPreferred: Bool

    @AppStorage private var primaryModelID: String
    @State private var apiKeyDraft = ""
    @State private var hasStoredKey = false
    @State private var availableModels: [AIAPIModelOption]
    @State private var isLoadingModels = false
    @State private var isShowingModelPicker = false
    @State private var isConfirmingKeyDeletion = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    private let credentialStore = KeychainAIAPICredentialStore()
    private let client = AIAPIClient()

    init(provider: AIAPIProvider, isPreferred: Bool) {
        self.provider = provider
        self.isPreferred = isPreferred
        _primaryModelID = AppStorage(
            wrappedValue: AIAPIPreferences.primaryModelID(for: provider),
            AIAPIPreferences.primaryModelKey(for: provider)
        )
        _availableModels = State(
            initialValue: AIAPIPreferences.cachedModels(for: provider)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Image(systemName: provider.systemImage)
                    .foregroundStyle(provider.tint)
                    .frame(width: 20)

                Text(provider.displayName)
                    .font(.headline)

                if isPreferred {
                    Text("Основной")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }

                Spacer()

                Label(
                    hasStoredKey ? "Подключён" : "Нет ключа",
                    systemImage: hasStoredKey ? "checkmark.shield.fill" : "key"
                )
                .font(.caption)
                .foregroundStyle(hasStoredKey ? .green : .secondary)
            }

            HStack(spacing: 8) {
                SecureField(
                    hasStoredKey ? "Новый ключ для замены" : provider.keyPlaceholder,
                    text: $apiKeyDraft
                )
                .textFieldStyle(.roundedBorder)

                Button(hasStoredKey ? "Заменить" : "Сохранить") {
                    saveAPIKey()
                }
                .disabled(normalizedKeyDraft.isEmpty)
            }

            HStack(spacing: 8) {
                TextField("Основная модель", text: $primaryModelID)
                    .textFieldStyle(.roundedBorder)

                Button("Модели…") {
                    isShowingModelPicker = true
                }
                .disabled(availableModels.isEmpty)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await loadModels() }
                } label: {
                    if isLoadingModels {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Загрузка…")
                        }
                    } else {
                        Label("Проверить и загрузить модели", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(!hasStoredKey || isLoadingModels)

                Spacer()

                if hasStoredKey {
                    Button("Удалить ключ…", role: .destructive) {
                        isConfirmingKeyDeletion = true
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
            }

            if let statusMessage {
                Label(
                    statusMessage,
                    systemImage: statusIsError ? "exclamationmark.triangle" : "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(statusIsError ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(
                    availableModels.isEmpty
                        ? "Сохраните ключ и загрузите каталог моделей. ID модели также можно ввести вручную."
                        : "В каталоге: \(availableModels.count). Выбранная здесь модель используется этим API по умолчанию."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .surfaceCard(padding: 14)
        .onAppear(perform: refreshCredentialState)
        .sheet(isPresented: $isShowingModelPicker) {
            APIModelPicker(
                title: "Основная модель \(provider.displayName)",
                models: availableModels,
                selectedModelID: $primaryModelID
            )
        }
        .confirmationDialog(
            "Удалить API-ключ \(provider.displayName)?",
            isPresented: $isConfirmingKeyDeletion
        ) {
            Button("Удалить ключ", role: .destructive, action: deleteAPIKey)
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Агенты, Auto и Handoff не смогут использовать этот API, пока вы не сохраните новый ключ.")
        }
    }

    private var normalizedKeyDraft: String {
        apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshCredentialState() {
        do {
            hasStoredKey = try credentialStore.loadAPIKey(for: provider) != nil
        } catch {
            hasStoredKey = false
            showError(error)
        }
    }

    private func saveAPIKey() {
        do {
            try credentialStore.saveAPIKey(normalizedKeyDraft, for: provider)
            apiKeyDraft = ""
            hasStoredKey = true
            statusMessage = "Ключ сохранён в Keychain."
            statusIsError = false
        } catch {
            showError(error)
        }
    }

    private func deleteAPIKey() {
        do {
            try credentialStore.deleteAPIKey(for: provider)
            apiKeyDraft = ""
            hasStoredKey = false
            statusMessage = "Ключ удалён из Keychain."
            statusIsError = false
        } catch {
            showError(error)
        }
    }

    @MainActor
    private func loadModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            guard let apiKey = try credentialStore.loadAPIKey(for: provider) else {
                hasStoredKey = false
                throw AIAPICredentialError.emptyKey(provider)
            }
            let models = try await client.fetchModels(provider: provider, apiKey: apiKey)
            availableModels = models
            AIAPIPreferences.saveCachedModels(models, for: provider)
            if primaryModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let first = models.first {
                primaryModelID = first.id
            }
            statusMessage = "Ключ работает. Загружено моделей: \(models.count)."
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

struct APIModelPicker: View {
    let title: String
    let models: [AIAPIModelOption]
    @Binding var selectedModelID: String

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
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
                                .foregroundStyle(.tint)
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
        .frame(width: 600, height: 520)
    }

    private var filteredModels: [AIAPIModelOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }
        return models.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }
}
