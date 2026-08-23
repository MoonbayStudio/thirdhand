import SwiftUI
import UniformTypeIdentifiers

struct NewTaskSheet: View {
    private enum CreationMode: String, CaseIterable, Identifiable {
        case conversation
        case manual

        var id: String { rawValue }
        var title: String {
            switch self {
            case .conversation: "Через описание"
            case .manual: "Вручную"
            }
        }
    }

    private enum ImportTarget {
        case avatar
        case repository
    }

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultRepositoriesFolderPath") private var defaultRepositoriesFolderPath = ""

    @State private var mode: CreationMode = .conversation
    @State private var description = ""
    @State private var name = ""
    @State private var personalityPrompt = ""
    @State private var avatarEmoji = "🤖"
    @State private var avatarImageData: Data?
    @State private var avatarColor: AgentAvatarColor = .indigo
    @State private var routingMode: AgentRoutingMode = .automatic
    @State private var agentKind: AgentKind = .codex
    @State private var modelID = ""
    @State private var repositoryURL: URL?
    @State private var importTarget: ImportTarget = .repository
    @State private var isChoosingFile = false
    @State private var importError: String?
    @State private var isCreating = false

    private var parsedSeed: AgentPersonaSeed {
        AgentPersonaDraftParser.parse(description)
    }

    private var capabilities: AgentCapabilitySet {
        store.capabilities(for: agentKind)
    }

    private var canCreate: Bool {
        guard repositoryURL != nil, !isCreating else { return false }
        switch mode {
        case .conversation:
            return !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .manual:
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !personalityPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Group {
                switch mode {
                case .conversation:
                    conversationCreator
                case .manual:
                    manualCreator
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 720, height: 600)
        .onAppear {
            selectDefaultsIfNeeded()
        }
        .onChange(of: agentKind) {
            resetModelSelection()
        }
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: importTarget == .avatar ? [.image] : [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
        .alert(
            importTarget == .avatar ? "Не удалось загрузить фото" : "Не удалось выбрать папку",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK") {
                importError = nil
            }
        } message: {
            Text(importError ?? "Попробуйте ещё раз.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Создать агента")
                    .font(.title2.weight(.semibold))
                Text("Задайте характер и правила один раз — дальше это отдельный постоянный чат.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Способ", selection: $mode) {
                ForEach(CreationMode.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 245)
        }
        .padding(22)
    }

    private var conversationCreator: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 10) {
                    PersonaAvatarView(
                        imageData: nil,
                        name: "Third Hand",
                        color: .indigo,
                        size: 36
                    )
                    Text("Расскажите, кого создать. Достаточно написать как в обычном чате: «Ты Муни, разработчик. Общайся коротко, сначала проверяй код, потом предлагай правки». Я соберу черновик профиля, а вы проверите его справа.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("Ваше описание")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    TextEditor(text: $description)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 120)
                        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.7)
                        }
                        .accessibilityIdentifier("agent-description-editor")
                }

                if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 12) {
                        PersonaAvatarView(
                            imageData: nil,
                            name: parsedSeed.name,
                            color: parsedSeed.avatarColor,
                            size: 46
                        )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(parsedSeed.name)
                                .font(.headline)
                            Text("Черновик · авто-выбор модели при исчерпании лимита")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "arrow.right.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                    }
                    .surfaceCard(padding: 13)
                }
            }
            .padding(22)
            .frame(maxWidth: 650)
            .frame(maxWidth: .infinity)
        }
        .background(DetailCanvasBackground())
    }

    private var manualCreator: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Имя и фото")
                        .font(.headline)
                    TextField("Имя агента", text: $name, prompt: Text("Например: Муни"))
                        .textFieldStyle(.roundedBorder)
                    PersonaAvatarEditor(
                        imageData: $avatarImageData,
                        color: $avatarColor,
                        name: name,
                        onChoosePhoto: {
                            importTarget = .avatar
                            isChoosingFile = true
                        }
                    )
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("Инструкции агента")
                        .font(.headline)
                    Text("Роль, характер общения, сильные стороны и правила поведения.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $personalityPrompt)
                        .scrollContentBackground(.hidden)
                        .padding(9)
                        .frame(minHeight: 110)
                        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Модель")
                        .font(.headline)

                    Picker("Выбор", selection: $routingMode) {
                        Text("Авто при лимите").tag(AgentRoutingMode.automatic)
                        Text("Определённый ИИ").tag(AgentRoutingMode.manual)
                    }
                    .pickerStyle(.segmented)

                    if routingMode == .manual {
                        Picker("Провайдер", selection: $agentKind) {
                            ForEach(AgentKind.allCases) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }

                        Picker("Модель", selection: $modelID) {
                            ForEach(capabilities.models) { model in
                                Text(model.title).tag(model.id)
                            }
                        }
                    } else {
                        Label(
                            "Third Hand переключится на следующий доступный CLI только после подтверждённой ошибки лимита.",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .surfaceCard(padding: 14)
            }
            .padding(22)
            .frame(maxWidth: 650)
            .frame(maxWidth: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Рабочая папка")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(repositoryURL?.path(percentEncoded: false) ?? "Не выбрана")
                    .font(.caption)
                    .foregroundStyle(repositoryURL == nil ? .orange : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 330, alignment: .leading)
            }

            Button("Выбрать…") {
                importTarget = .repository
                isChoosingFile = true
            }

            Spacer()

            Button("Отмена") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(mode == .conversation ? "Создать черновик" : "Создать агента") {
                createAgent()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate)
            .accessibilityIdentifier("confirm-create-agent-button")
        }
        .padding(18)
        .background(.bar)
    }

    private func selectDefaultsIfNeeded() {
        if let selectedPath = store.selectedTask?.repositoryPath, !selectedPath.isEmpty {
            repositoryURL = URL(fileURLWithPath: selectedPath, isDirectory: true)
        } else if !defaultRepositoriesFolderPath.isEmpty {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(
                atPath: defaultRepositoriesFolderPath,
                isDirectory: &isDirectory
            ), isDirectory.boolValue {
                repositoryURL = URL(
                    fileURLWithPath: defaultRepositoriesFolderPath,
                    isDirectory: true
                )
            }
        }

        if let available = store.automaticAgentOrder.first(where: { preferred in
            store.agentInstallations.contains { $0.kind == preferred && $0.isAvailable }
        }) {
            agentKind = available
        }
        resetModelSelection()
    }

    private func resetModelSelection() {
        modelID = store.capabilities(for: agentKind).defaultModelID
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            switch importTarget {
            case .avatar:
                avatarImageData = try PersonaAvatarImageProcessor.normalizedImageData(from: url)
            case .repository:
                repositoryURL = url
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    private func createAgent() {
        guard let repositoryURL else { return }
        isCreating = true

        let profile: AgentProfileDraft
        switch mode {
        case .conversation:
            let seed = parsedSeed
            profile = AgentProfileDraft(
                name: seed.name,
                personalityPrompt: seed.prompt,
                avatarEmoji: seed.avatarEmoji,
                avatarImageData: nil,
                avatarColor: seed.avatarColor,
                routingMode: .automatic,
                agentKind: agentKind,
                repositoryPath: repositoryURL.path,
                needsReview: true
            )
        case .manual:
            var configuration = TaskAgentConfiguration()
            if routingMode == .manual, !modelID.isEmpty {
                configuration[.model] = modelID
            }
            profile = AgentProfileDraft(
                name: name,
                personalityPrompt: personalityPrompt,
                avatarEmoji: avatarEmoji,
                avatarImageData: avatarImageData,
                avatarColor: avatarColor,
                routingMode: routingMode,
                agentKind: agentKind,
                configuration: configuration,
                repositoryPath: repositoryURL.path
            )
        }

        Task {
            await store.addAgent(profile: profile)
            dismiss()
        }
    }
}
