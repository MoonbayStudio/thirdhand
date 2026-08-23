import SwiftUI
import UniformTypeIdentifiers

struct AgentProfileInspectorView: View {
    private enum ImportTarget {
        case avatar
        case repository
    }

    @Environment(AppStore.self) private var store
    let task: CodingTask

    @State private var draft: AgentProfileDraft
    @State private var savedDraft: AgentProfileDraft
    @State private var importTarget: ImportTarget = .repository
    @State private var isChoosingFile = false
    @State private var isShowingAPIModelPicker = false
    @State private var showsSavedConfirmation = false

    init(task: CodingTask) {
        self.task = task
        let initialDraft = AgentProfileDraft(
            task: task,
            fallbackAgent: task.currentAgent ?? .codex
        )
        _draft = State(initialValue: initialDraft)
        _savedDraft = State(initialValue: initialDraft)
    }

    private var capabilities: AgentCapabilitySet {
        store.capabilities(for: draft.agentKind)
    }

    private var isBusy: Bool {
        store.activeRuns[task.id] != nil || store.activeValidations[task.id] != nil
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.personalityPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(draft.routingMode == .manual
                && draft.executionSource == .api
                && draft.apiModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !isBusy
    }

    private var isDirty: Bool {
        draft != savedDraft || task.effectivePersona.needsReview
    }

    private var storedProfileDraft: AgentProfileDraft {
        AgentProfileDraft(
            task: task,
            fallbackAgent: task.currentAgent ?? .codex
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                profileHeader

                if task.onboardingStage != nil {
                    onboardingBanner
                } else if task.effectivePersona.needsReview {
                    reviewBanner
                }

                profileSection
                Divider()
                personalitySection
                Divider()
                interactionSection
                Divider()
                modelSection
                Divider()
                workspaceSection
                saveSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 18)
        }
        .background(.ultraThinMaterial)
        .navigationTitle("Профиль")
        .onChange(of: task.id) { _, _ in
            resetDraft(from: task)
        }
        .onChange(of: storedProfileDraft) { oldValue, newValue in
            let hasLocalEdits = draft != savedDraft
            savedDraft = newValue
            if !hasLocalEdits || draft == oldValue {
                draft = newValue
            }
        }
        .onChange(of: draft.agentKind) { oldValue, newValue in
            guard oldValue != newValue, draft.executionSource == .cli else { return }
            draft.configuration = TaskAgentConfiguration(
                values: [AgentOptionID.model.rawValue: capabilities.defaultModelID]
            )
        }
        .onChange(of: draft.executionSource) { _, source in
            if source == .api, draft.apiModelID.isEmpty {
                draft.apiModelID = AIAPIPreferences.primaryModelID(for: draft.apiProvider)
            }
        }
        .onChange(of: draft.apiProvider) { oldValue, newValue in
            guard oldValue != newValue else { return }
            draft.apiModelID = AIAPIPreferences.primaryModelID(for: newValue)
        }
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: importTarget == .avatar ? [.image] : [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
        .sheet(isPresented: $isShowingAPIModelPicker) {
            APIModelPicker(
                title: "Модель \(draft.apiProvider.displayName)",
                models: AIAPIPreferences.cachedModels(for: draft.apiProvider),
                selectedModelID: $draft.apiModelID
            )
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 12) {
            PersonaAvatarView(
                imageData: draft.avatarImageData,
                name: draft.name,
                color: draft.avatarColor,
                size: 54
            )

            VStack(alignment: .leading, spacing: 3) {
                Group {
                    if draft.name.isEmpty {
                        Text("Новый агент")
                    } else {
                        Text(draft.name)
                    }
                }
                .font(.title3.weight(.semibold))
                .lineLimit(1)

                Text(runtimeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reviewBanner: some View {
        Label {
            Text("Это черновик из вашего описания. Проверьте имя и промпт, затем сохраните.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "pencil.and.list.clipboard")
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var onboardingBanner: some View {
        Label {
            Text(onboardingBannerText)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: task.onboardingStage == .configuring ? "wand.and.stars" : "bubble.left.and.text.bubble.right")
        }
        .font(.caption)
        .foregroundStyle(Color.accentColor)
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var onboardingBannerText: String {
        switch task.onboardingStage {
        case .introducing:
            AppLocalization.string("Агент начинает знакомство в чате. Профиль уже можно заполнить вручную.")
        case .awaitingIdentity:
            AppLocalization.string("Опишите агента в чате — ИИ заполнит этот профиль. Либо настройте всё вручную и сохраните.")
        case .configuring:
            AppLocalization.string("ИИ собирает имя, характер и параметры модели из вашего ответа. Его служебный ответ останется внутри приложения.")
        case nil:
            ""
        }
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("Профиль")

            TextField("Имя", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("agent-name-field")

            PersonaAvatarEditor(
                imageData: $draft.avatarImageData,
                color: $draft.avatarColor,
                name: draft.name,
                onChoosePhoto: {
                    importTarget = .avatar
                    isChoosingFile = true
                }
            )
        }
    }

    private var personalitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Инструкции агента")
            Text("Они добавляются к каждому сообщению этому агенту.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $draft.personalityPrompt)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 170)
                .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.6)
                }
                .accessibilityIdentifier("agent-personality-editor")
        }
    }

    private var interactionSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("Сценарий")

            Picker("Сценарий", selection: $draft.interactionMode) {
                Text("Авто").tag(AgentInteractionMode.automatic)
                Text("Общение").tag(AgentInteractionMode.conversation)
                Text("Проект").tag(AgentInteractionMode.workspace)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("agent-interaction-mode-picker")

            Text(draft.interactionMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("ИИ и лимиты")

            Picker("Режим", selection: $draft.routingMode) {
                Text("Авто").tag(AgentRoutingMode.automatic)
                Text("Фикс.").tag(AgentRoutingMode.manual)
            }
            .pickerStyle(.segmented)

            if draft.routingMode == .automatic {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Авто-выбор при исчерпании лимита", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout.weight(.medium))

                    Text("Агент начнёт с первого доступного CLI и при подтверждённом лимите продолжит через следующий CLI или подключённый API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        ForEach(Array(store.automaticAgentOrder.enumerated()), id: \.element) { index, kind in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Image(systemName: kind.systemImage)
                                .foregroundStyle(kind.tint)
                                .help("\(kind.displayName) · CLI")
                        }

                        ForEach(store.availableAPITargets) { target in
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Image(systemName: target.provider.systemImage)
                                .foregroundStyle(target.provider.tint)
                                .help(target.displayName)
                        }
                    }
                }
                .padding(11)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            } else {
                Picker("Способ запуска", selection: $draft.executionSource) {
                    Text("CLI").tag(AgentExecutionSource.cli)
                    Text("API").tag(AgentExecutionSource.api)
                }
                .pickerStyle(.segmented)

                if draft.executionSource == .cli {
                    Picker("CLI", selection: $draft.agentKind) {
                        ForEach(store.agentInstallations) { installation in
                            Text(
                                installation.isAvailable
                                    ? installation.kind.displayName
                                    : AppLocalization.string("\(installation.kind.displayName) — CLI не найден")
                            )
                            .tag(installation.kind)
                        }
                    }

                    Picker("Модель", selection: modelBinding) {
                        ForEach(capabilities.models) { model in
                            Text(model.title).tag(model.id)
                        }
                    }
                } else {
                    Picker("API", selection: $draft.apiProvider) {
                        ForEach(AIAPIProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }

                    LabeledContent("Модель") {
                        HStack(spacing: 7) {
                            TextField("ID модели", text: $draft.apiModelID)
                                .textFieldStyle(.roundedBorder)

                            Button("Выбрать…") {
                                isShowingAPIModelPicker = true
                            }
                            .disabled(
                                AIAPIPreferences.cachedModels(for: draft.apiProvider).isEmpty
                            )
                        }
                    }

                    if draft.apiModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Label(
                            "Сначала подключите API и выберите модель в настройках.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("Рабочая папка")

            if draft.interactionMode == .conversation {
                Text("В режиме общения агент запускается в изолированной папке и не получает Git-контекст проекта.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(draft.repositoryPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Button("Выбрать папку…") {
                    importTarget = .repository
                    isChoosingFile = true
                }
            }
        }
    }

    private var saveSection: some View {
        VStack(spacing: 10) {
            Button {
                save()
            } label: {
                HStack {
                    if showsSavedConfirmation {
                        Image(systemName: "checkmark")
                    }
                    Text(
                        showsSavedConfirmation
                            ? AppLocalization.string("Сохранено")
                            : AppLocalization.string("Сохранить изменения")
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSave || (!isDirty && !showsSavedConfirmation))
            .accessibilityIdentifier("save-agent-profile-button")

            if isBusy {
                Text("Остановите агента или проверку, чтобы изменить профиль.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            Button("Удалить агента…", role: .destructive) {
                store.requestTaskDeletion(task.id)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .disabled(isBusy)
        }
        .padding(.top, 4)
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: {
                let stored = draft.configuration[.model]
                return capabilities.models.contains(where: { $0.id == stored })
                    ? stored ?? capabilities.defaultModelID
                    : capabilities.defaultModelID
            },
            set: { value in
                draft.configuration[.model] = value
                draft.configuration[.reasoningEffort] = nil
                draft.configuration[.speedTier] = nil
            }
        )
    }

    private var runtimeSummary: String {
        if draft.routingMode == .automatic {
            return AppLocalization.string("\(draft.interactionMode.title) · Auto: CLI → API")
        }
        if draft.executionSource == .api {
            let model = draft.apiModelID.isEmpty ? nil : draft.apiModelID
            return [draft.interactionMode.title, draft.apiProvider.shortName, model]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
        let model = capabilities.model(for: draft.configuration[.model])?.compactTitle
        return [draft.interactionMode.title, draft.agentKind.shortName, model]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .textCase(.uppercase)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    private func resetDraft(from task: CodingTask) {
        let newDraft = AgentProfileDraft(task: task, fallbackAgent: task.currentAgent ?? .codex)
        draft = newDraft
        savedDraft = newDraft
        showsSavedConfirmation = false
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            switch importTarget {
            case .avatar:
                draft.avatarImageData = try PersonaAvatarImageProcessor.normalizedImageData(from: url)
            case .repository:
                draft.repositoryPath = url.path
            }
        } catch {
            store.lastError = importTarget == .avatar
                ? AppLocalization.string("Не удалось загрузить фото: \(error.localizedDescription)")
                : AppLocalization.string("Не удалось выбрать папку: \(error.localizedDescription)")
        }
    }

    private func save() {
        guard store.updateAgentProfile(draft, for: task.id) else { return }
        draft.needsReview = false
        savedDraft = draft
        showsSavedConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            showsSavedConfirmation = false
        }
    }
}
