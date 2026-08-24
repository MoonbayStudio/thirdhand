import SwiftUI
import UniformTypeIdentifiers

struct TaskDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccessibilityOptions) private var accessibilityOptions
    let task: CodingTask

    @State private var draft = ""
    @State private var draftAttachments: [TaskAttachment] = []
    @State private var isShowingFileImporter = false
    @State private var isCurrentLiveOutputRevealed = false
    @State private var voiceInput = VoiceInputController()
    @State private var dictationBaseDraft = ""
    @State private var selectedSlashCommandID: String?
    @State private var isShowingSlashCommandHelp = false
    @State private var slashCommandHelpGeneration = 0
    @State private var helpCommandTokenID: UUID?
    @State private var commandOptionTokenID: UUID?
    @State private var composerTokens: [InlineComposerToken] = []
    @State private var composerCardHeight: CGFloat = 0
    @AppStorage("showRawTerminalLogs") private var showRawTerminalLogs = false
    @AppStorage(AppPreferenceKeys.voiceInputEnabled)
    private var voiceInputEnabled = true
    @AppStorage(AppPreferenceKeys.voiceRecognitionLanguage)
    private var voiceRecognitionLanguage: VoiceRecognitionLanguage = .automatic
    @AppStorage(AppPreferenceKeys.voiceAddsPunctuation)
    private var voiceAddsPunctuation = true
    @AppStorage(AppPreferenceKeys.voicePrefersOnDeviceRecognition)
    private var voicePrefersOnDeviceRecognition = true
    @AppStorage(AppPreferenceKeys.language)
    private var appLanguage: AppLanguage = .russian
    @FocusState private var isComposerFocused: Bool

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draftAttachments.isEmpty
            || !composerTokens.isEmpty
    }

    private var canSubmit: Bool {
        canSend && !isRepositoryBusy
    }

    private var activeRun: AgentRunState? {
        store.activeRuns[task.id]
    }

    private var isRepositoryBusy: Bool {
        guard task.onboardingStage == nil else { return false }
        return store.isRepositoryBusyForInteraction(task.repositoryPath)
    }

    private var isComposerBlocked: Bool {
        activeRun != nil
            || isRepositoryBusy
            || task.onboardingStage == .introducing
            || task.onboardingStage == .configuring
    }

    private var shouldShowLiveOutput: Bool {
        showRawTerminalLogs || isCurrentLiveOutputRevealed
    }

    private var showsOnboardingTyping: Bool {
        task.onboardingStage == .introducing || task.onboardingStage == .configuring
    }

    private var onboardingTypingID: String {
        "onboarding-typing-\(task.onboardingStage?.rawValue ?? "none")"
    }

    private var autocompletedSlashCommand: ChatSlashCommandDescriptor? {
        guard composerTokens.count == 1,
              let commandToken = composerTokens.first,
              commandToken.utf16Offset == 0
        else {
            return nil
        }
        return ChatSlashCommandDescriptor.all.first {
            $0.name == commandToken.text
        }
    }

    private var slashCommandSuggestions: [ChatSlashCommandDescriptor] {
        guard activeRun == nil,
              task.onboardingStage == nil,
              draftAttachments.isEmpty
        else {
            return []
        }
        return ChatSlashCommandDescriptor.suggestions(for: draft)
    }

    private var presentedSlashCommands: [ChatSlashCommandDescriptor] {
        isShowingSlashCommandHelp
            ? ChatSlashCommandDescriptor.all
            : slashCommandSuggestions
    }

    private var presentedSlashCommandOptions: [ChatSlashCommandOption] {
        guard let commandOptionTokenID,
              composerTokens.count == 1,
              composerTokens.first?.id == commandOptionTokenID,
              let command = autocompletedSlashCommand
        else {
            return []
        }
        return slashCommandOptions(for: command)
    }

    private var slashPaletteItems: [SlashCommandPaletteItem] {
        if !presentedSlashCommandOptions.isEmpty {
            return presentedSlashCommandOptions.map(
                SlashCommandPaletteItem.init(option:)
            )
        }
        return presentedSlashCommands.map(
            SlashCommandPaletteItem.init(command:)
        )
    }

    private var slashPaletteIdentity: String {
        if let commandOptionTokenID {
            return "options-\(commandOptionTokenID)-\(slashCommandHelpGeneration)"
        }
        if isShowingSlashCommandHelp {
            return "help-\(slashCommandHelpGeneration)"
        }
        return "suggestions"
    }

    private var slashPaletteAnimation: Animation? {
        accessibilityOptions.reduceMotion
            ? nil
            : .spring(response: 0.27, dampingFraction: 0.9)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TransparentVSplitView(
                top: messageList.environment(store),
                bottom: composer.environment(store),
                minimumTopHeight: 240,
                minimumBottomHeight: 120,
                idealBottomHeight: 160,
                maximumBottomHeight: 360
            )

            if !slashPaletteItems.isEmpty, composerCardHeight > 0 {
                SlashCommandPalette(
                    items: slashPaletteItems,
                    selectedID: selectedSlashCommandID,
                    onSelect: activateSlashPaletteItem,
                    onHighlight: { selectedSlashCommandID = $0 }
                )
                .id(slashPaletteIdentity)
                .padding(.horizontal, 24)
                .frame(maxWidth: 820)
                .padding(.bottom, composerCardHeight + 21)
                .transition(.asymmetric(
                    insertion: .offset(y: 5).combined(with: .opacity),
                    removal: .offset(y: 5).combined(with: .opacity)
                ))
                .zIndex(10)
            }
        }
        .animation(
            slashPaletteAnimation,
            value: slashPaletteItems.map(\.id)
        )
        .animation(
            slashPaletteAnimation,
            value: isShowingSlashCommandHelp
        )
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                toolbarIdentity
            }

            if let activeRun,
               activeRun.presentsDetailedActivity,
               task.onboardingStage != .configuring {
                ToolbarItem(placement: .primaryAction) {
                    AgentRunCapsule(
                        run: activeRun,
                        output: store.liveAgentOutputs[task.id]
                    )
                }
            }

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
        .background {
            DetailCanvasBackground()
        }
        .onAppear {
            if task.chatMessages.isEmpty {
                isComposerFocused = true
            }
        }
        .onChange(of: task.id) {
            isCurrentLiveOutputRevealed = false
            selectedSlashCommandID = nil
            isShowingSlashCommandHelp = false
            slashCommandHelpGeneration += 1
            helpCommandTokenID = nil
            commandOptionTokenID = nil
            composerTokens = []
            voiceInput.cancel()
            voiceInput.clearTranscript()
            dictationBaseDraft = ""
        }
        .onChange(of: activeRun?.attemptID) {
            isCurrentLiveOutputRevealed = false
        }
        .onChange(of: task.onboardingStage) { _, stage in
            if stage == .awaitingIdentity {
                isComposerFocused = true
            }
        }
        .onChange(of: voiceInput.transcript) { _, transcript in
            guard !transcript.isEmpty else { return }
            draft = composedDraft(base: dictationBaseDraft, transcript: transcript)
        }
        .onChange(of: draft) {
            let suggestions = slashPaletteItems
            if !suggestions.contains(where: { $0.id == selectedSlashCommandID }) {
                selectedSlashCommandID = suggestions.first?.id
            }
        }
        .onChange(of: voiceInput.errorMessage) { _, message in
            guard let message else { return }
            store.lastError = message
        }
        .onChange(of: voiceInputEnabled) { _, enabled in
            if !enabled {
                voiceInput.cancel()
            }
        }
        .onDisappear {
            slashCommandHelpGeneration += 1
            voiceInput.cancel()
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: handleFileSelection
        )
    }

    private var toolbarIdentity: some View {
        HStack(spacing: 9) {
            PersonaAvatarView(
                imageData: task.effectivePersona.avatarImageData,
                name: task.title,
                color: task.effectivePersona.avatarColor,
                size: 30
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 7) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)

                    Text(toolbarStatusTitle)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: 240, alignment: .leading)
        }
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .padding(.vertical, 2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            AppLocalization.string("Агент \(task.title), \(toolbarStatusTitle)")
        )
    }

    private var toolbarStatusTitle: String {
        switch task.onboardingStage {
        case .introducing:
            AppLocalization.string("Знакомится")
        case .awaitingIdentity:
            AppLocalization.string("Ждёт описания")
        case .configuring:
            AppLocalization.string("Настраивается")
        case nil:
            if let activeRun {
                activeRun.presentsDetailedActivity
                    ? AppLocalization.string("Работает")
                    : AppLocalization.string("Печатает")
            } else {
                AppLocalization.string("В сети")
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if task.chatMessages.isEmpty && !showsOnboardingTyping {
                    ContentUnavailableView {
                        Label("Напишите \(task.title)", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Каждый агент помнит свои инструкции, модель и отдельную историю чата.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 420)
                } else {
                    LazyVStack(spacing: 18) {
                        ForEach(task.chatMessages) { message in
                            ChatMessageRow(
                                message: message,
                                agentPersona: task.effectivePersona,
                                agentName: task.title,
                                quickReplies: quickReplies(for: message),
                                onQuickReply: sendQuickReply,
                                onCustomReply: {
                                    isComposerFocused = true
                                }
                            )
                                .id(message.id)
                        }

                        if showsOnboardingTyping {
                            AgentTypingRow(
                                persona: task.effectivePersona,
                                agentName: task.title
                            )
                            .id(onboardingTypingID)
                        } else if let activeRun {
                            if activeRun.presentsDetailedActivity {
                                AgentWorkingRow(
                                    run: activeRun,
                                    liveOutput: store.liveAgentOutputs[task.id],
                                    persona: task.effectivePersona,
                                    agentName: task.title,
                                    showsRawOutput: shouldShowLiveOutput,
                                    onRevealLiveOutput: {
                                        isCurrentLiveOutputRevealed = true
                                    }
                                )
                                .id(activeRun.attemptID)
                            } else {
                                AgentTypingRow(
                                    persona: task.effectivePersona,
                                    agentName: task.title
                                )
                                .id(activeRun.attemptID)
                            }
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 22)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
            }
            .onChange(of: task.chatMessages.count) { _, _ in
                guard let lastMessageID = task.chatMessages.last?.id else { return }
                scrollToBottom(lastMessageID, using: proxy)
            }
            .onChange(of: activeRun) { _, run in
                guard let run else { return }
                scrollToBottom(run.attemptID, using: proxy)
            }
            .onChange(of: task.onboardingStage) { _, stage in
                guard stage == .introducing || stage == .configuring else { return }
                scrollToBottom(onboardingTypingID, using: proxy)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let activeRun,
               activeRun.presentsDetailedActivity,
               task.onboardingStage != .configuring {
                AgentActivityAccessory(
                    run: activeRun,
                    output: store.liveAgentOutputs[task.id]
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                if !draftAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(draftAttachments) { attachment in
                                DraftAttachmentChip(attachment: attachment) {
                                    draftAttachments.removeAll { $0.id == attachment.id }
                                }
                            }
                        }
                    }
                }

                if activeRun == nil, isRepositoryBusy {
                    Label(
                        "Дождитесь завершения агента или проверки в этом репозитории.",
                        systemImage: "hourglass"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                InlineTokenComposerField(
                    text: $draft,
                    tokens: $composerTokens,
                    placeholder: autocompletedSlashCommand == nil
                        ? composerPlaceholder
                        : commandArgumentPlaceholder,
                    isEnabled: !isComposerBlocked,
                    isFocused: isComposerFocused,
                    onFocusChange: { isComposerFocused = $0 },
                    onRecognizeCommand: autocompleteSlashCommand,
                    onSubmit: submitComposer,
                    onMoveSuggestion: moveSlashSelection,
                    onActivateToken: activateComposerToken,
                    onDismissCommandPalette: dismissSlashCommandPalette
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: 24)
                .animation(slashPaletteAnimation, value: autocompletedSlashCommand?.id)

                HStack(alignment: .center, spacing: 8) {
                    Button {
                        isShowingFileImporter = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 27, height: 27)
                            .background(.quaternary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        isComposerBlocked
                            || task.onboardingStage != nil
                            || !composerTokens.isEmpty
                    )
                    .help("Добавить файлы")

                    if voiceInputEnabled {
                        Button(action: toggleVoiceInput) {
                            Image(systemName: voiceInput.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: voiceInput.isRecording ? 10 : 12, weight: .semibold))
                                .foregroundStyle(voiceInput.isRecording ? Color.white : Color.primary)
                                .frame(width: 27, height: 27)
                                .background(
                                    voiceInput.isRecording
                                        ? Color.red
                                        : Color.secondary.opacity(0.12),
                                    in: Circle()
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isComposerBlocked)
                        .help(voiceInput.isRecording ? "Остановить голосовой ввод" : "Голосовой ввод")
                        .accessibilityLabel(
                            voiceInput.isRecording
                                ? "Остановить голосовой ввод"
                                : "Начать голосовой ввод"
                        )
                        .accessibilityValue(voiceInput.isRecording ? "Идёт запись" : "Не записывает")
                        .accessibilityIdentifier("voice-input-button")

                        if voiceInput.isRecording {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 6, height: 6)
                                Text("Слушаю…")
                                    .font(.caption2.weight(.medium))
                                if voiceInput.usesOnDeviceRecognition {
                                    Image(systemName: "desktopcomputer")
                                        .accessibilityLabel("Распознавание на Mac")
                                }
                            }
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .combine)
                        }
                    }

                    Spacer(minLength: 24)

                    AgentConfigurationMenu(task: task)
                        .disabled(isComposerBlocked)

                    if activeRun != nil {
                        Button {
                            Swift.Task { await store.stopAgentRun(taskID: task.id) }
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.red, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Остановить агента")
                    } else {
                        Button(action: sendComposer) {
                            ZStack {
                                Circle()
                                    .fill(
                                        canSubmit
                                            ? Color.accentColor
                                            : Color.secondary.opacity(0.12)
                                    )

                                Image(systemName: "arrow.up")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(canSubmit ? Color.white : Color.secondary)
                                    .offset(y: 0.75)
                            }
                            .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSubmit)
                        .help(
                            isRepositoryBusy
                                ? AppLocalization.string("Сначала дождитесь завершения работы в репозитории")
                                : AppLocalization.string("Отправить сообщение")
                        )
                    }
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 9)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.42), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TaskComposerCardHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
            .onPreferenceChange(TaskComposerCardHeightPreferenceKey.self) { height in
                composerCardHeight = height
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, activeRun == nil ? 14 : 10)
        .padding(.bottom, 16)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func submitComposer() {
        if let option = selectedSlashCommandOption() {
            activateSlashCommandOption(option)
            return
        }

        if let command = selectedSlashCommand() {
            activateSlashCommand(command)
            return
        }

        sendComposer()
    }

    private func sendComposer() {
        if draftAttachments.isEmpty,
           (try? ChatSlashCommandParser.parse(resolvedComposerText)) == .help {
            presentSlashCommandHelp()
            return
        }

        send()
    }

    private func selectedSlashCommand() -> ChatSlashCommandDescriptor? {
        guard presentedSlashCommandOptions.isEmpty else { return nil }
        return presentedSlashCommands.first { $0.id == selectedSlashCommandID }
            ?? presentedSlashCommands.first
    }

    private func selectedSlashCommandOption() -> ChatSlashCommandOption? {
        presentedSlashCommandOptions.first { $0.id == selectedSlashCommandID }
            ?? presentedSlashCommandOptions.first
    }

    private func moveSlashSelection(by offset: Int) -> Bool {
        let suggestions = slashPaletteItems
        guard !suggestions.isEmpty else { return false }
        let currentIndex = selectedSlashCommandID.flatMap { selectedID in
            suggestions.firstIndex(where: { $0.id == selectedID })
        } ?? 0
        let nextIndex = (currentIndex + offset + suggestions.count) % suggestions.count
        selectedSlashCommandID = suggestions[nextIndex].id
        return true
    }

    private func activateSlashPaletteItem(_ itemID: String) {
        if let option = presentedSlashCommandOptions.first(
            where: { $0.id == itemID }
        ) {
            activateSlashCommandOption(option)
            return
        }

        guard let command = presentedSlashCommands.first(
            where: { $0.id == itemID }
        ) else {
            return
        }
        activateSlashCommand(command)
    }

    private func autocompleteSlashCommand(
        _ command: ChatSlashCommandDescriptor,
        replacing replacementRange: NSRange? = nil
    ) -> UUID {
        slashCommandHelpGeneration += 1
        voiceInput.stop()
        voiceInput.clearTranscript()
        dictationBaseDraft = ""
        let range = replacementRange
            ?? ChatSlashCommandDescriptor.activeFragment(in: draft)?.range
            ?? NSRange(location: (draft as NSString).length, length: 0)
        let insertion = InlineComposerContent.insertingToken(
            text: command.name,
            replacing: range,
            in: draft,
            tokens: composerTokens
        )
        composerTokens = insertion.tokens
        draft = insertion.text
        selectedSlashCommandID = nil
        isComposerFocused = true

        if command.name == "/help" {
            presentSlashCommandHelp(for: insertion.tokenID)
        } else if command.argumentKind != .none {
            presentSlashCommandOptions(
                for: insertion.tokenID,
                command: command
            )
        } else {
            dismissSlashCommandPalette()
        }
        return insertion.tokenID
    }

    private func activateSlashCommand(_ command: ChatSlashCommandDescriptor) {
        guard activeRun == nil, !isRepositoryBusy else { return }

        if isShowingSlashCommandHelp,
           let helpCommandTokenID {
            replaceHelpCommandToken(
                helpCommandTokenID,
                with: command
            )
            return
        }

        _ = autocompleteSlashCommand(command)
    }

    private func presentSlashCommandHelp() {
        guard activeRun == nil, task.onboardingStage == nil else { return }

        if let token = composerTokens.first(where: { $0.text == "/help" }) {
            presentSlashCommandHelp(for: token.id)
            return
        }

        guard let helpCommand = ChatSlashCommandDescriptor.all.first(
            where: { $0.name == "/help" }
        ) else {
            return
        }
        _ = autocompleteSlashCommand(helpCommand)
    }

    private func presentSlashCommandHelp(for tokenID: UUID) {
        guard activeRun == nil,
              task.onboardingStage == nil,
              composerTokens.contains(where: {
                  $0.id == tokenID && $0.text == "/help"
              })
        else {
            return
        }

        slashCommandHelpGeneration += 1
        helpCommandTokenID = tokenID
        commandOptionTokenID = nil
        selectedSlashCommandID = ChatSlashCommandDescriptor.all.first?.id
        withAnimation(slashPaletteAnimation) {
            isShowingSlashCommandHelp = true
        }
        isComposerFocused = true
    }

    private func presentSlashCommandOptions(
        for tokenID: UUID,
        command: ChatSlashCommandDescriptor
    ) {
        guard activeRun == nil,
              task.onboardingStage == nil,
              composerTokens.count == 1,
              composerTokens.first?.id == tokenID,
              composerTokens.first?.text == command.name
        else {
            dismissSlashCommandPalette()
            return
        }

        let options = slashCommandOptions(for: command)
        guard !options.isEmpty else {
            dismissSlashCommandPalette()
            return
        }

        slashCommandHelpGeneration += 1
        helpCommandTokenID = nil
        withAnimation(slashPaletteAnimation) {
            isShowingSlashCommandHelp = false
            commandOptionTokenID = tokenID
            selectedSlashCommandID = options.first(where: \.isCurrent)?.id
                ?? options.first?.id
        }
        isComposerFocused = true
    }

    private func slashCommandOptions(
        for command: ChatSlashCommandDescriptor
    ) -> [ChatSlashCommandOption] {
        switch command.argumentKind {
        case .none:
            return []

        case .model:
            switch store.preferredExecutionTarget(for: task) {
            case let .cli(agent):
                let capabilities = store.capabilities(for: agent)
                let models = capabilities.models.map { model in
                    AgentValueOption(
                        model.id,
                        title: model.title,
                        detail: model.detail
                    )
                }
                return ChatSlashCommandOption.modelOptions(
                    models,
                    selectedID: task.agentConfiguration?[.model]
                        ?? capabilities.defaultModelID,
                    sourceTitle: agent.shortName
                )

            case let .api(target):
                let models = store.availableAPITargets
                    .filter { $0.provider == target.provider }
                    .map { apiTarget in
                        AgentValueOption(
                            apiTarget.modelID,
                            title: apiTarget.modelID
                        )
                    }
                return ChatSlashCommandOption.modelOptions(
                    models,
                    selectedID: target.modelID,
                    sourceTitle: target.provider.displayName
                )
            }

        case .session:
            return ChatSlashCommandOption.sessionOptions(
                bindings: task.nativeSessionBindings ?? []
            )
        }
    }

    private func activateSlashCommandOption(
        _ option: ChatSlashCommandOption
    ) {
        guard activeRun == nil,
              !isRepositoryBusy,
              let commandOptionTokenID,
              composerTokens.count == 1,
              composerTokens.first?.id == commandOptionTokenID,
              composerTokens.first?.text == option.commandName,
              presentedSlashCommandOptions.contains(option)
        else {
            dismissSlashCommandPalette()
            return
        }

        voiceInput.stop()
        voiceInput.clearTranscript()
        dictationBaseDraft = ""
        draft = option.argumentText
        dismissSlashCommandPalette()
        isComposerFocused = true
    }

    private func dismissSlashCommandPalette() {
        guard isShowingSlashCommandHelp
                || helpCommandTokenID != nil
                || commandOptionTokenID != nil
        else {
            return
        }
        slashCommandHelpGeneration += 1
        helpCommandTokenID = nil
        commandOptionTokenID = nil
        selectedSlashCommandID = nil
        withAnimation(slashPaletteAnimation) {
            isShowingSlashCommandHelp = false
        }
    }

    private func activateComposerToken(_ tokenID: UUID) {
        guard let token = composerTokens.first(where: { $0.id == tokenID }),
              let command = ChatSlashCommandDescriptor.all.first(
                where: { $0.name == token.text }
              )
        else {
            dismissSlashCommandPalette()
            return
        }

        if command.name == "/help" {
            presentSlashCommandHelp(for: tokenID)
        } else if command.argumentKind != .none {
            presentSlashCommandOptions(for: tokenID, command: command)
        } else {
            dismissSlashCommandPalette()
        }
    }

    private func replaceHelpCommandToken(
        _ tokenID: UUID,
        with command: ChatSlashCommandDescriptor
    ) {
        guard composerTokens.contains(where: {
            $0.id == tokenID && $0.text == "/help"
        }) else {
            dismissSlashCommandPalette()
            return
        }

        composerTokens = InlineComposerContent.replacingToken(
            tokenID,
            with: command.name,
            in: composerTokens
        )
        dismissSlashCommandPalette()
        if command.argumentKind != .none {
            presentSlashCommandOptions(for: tokenID, command: command)
        }
        isComposerFocused = true
    }

    private func send() {
        let text = resolvedComposerText
        guard !text.isEmpty || !draftAttachments.isEmpty,
              activeRun == nil,
              !isRepositoryBusy
        else {
            return
        }

        let attachments = draftAttachments
        voiceInput.stop()
        voiceInput.clearTranscript()
        dictationBaseDraft = ""
        draft = ""
        draftAttachments = []
        composerTokens = []
        dismissSlashCommandPalette()
        isComposerFocused = true

        Swift.Task {
            await store.submitMessage(
                taskID: task.id,
                text: text,
                attachments: attachments
            )
        }
    }

    private func toggleVoiceInput() {
        if voiceInput.isRecording {
            voiceInput.stop()
            return
        }

        dictationBaseDraft = draft
        isComposerFocused = true
        let locale = voiceRecognitionLanguage.locale(appLanguage: appLanguage)

        Swift.Task {
            await voiceInput.start(
                configuration: VoiceInputConfiguration(
                    localeIdentifier: locale.identifier,
                    addsPunctuation: voiceAddsPunctuation,
                    prefersOnDeviceRecognition: voicePrefersOnDeviceRecognition
                )
            )
        }
    }

    private func composedDraft(base: String, transcript: String) -> String {
        guard !base.isEmpty else { return transcript }
        guard let last = base.last, !last.isWhitespace else {
            return base + transcript
        }
        return base + " " + transcript
    }

    private func scrollToBottom<ID: Hashable>(
        _ id: ID,
        using proxy: ScrollViewProxy
    ) {
        if accessibilityOptions.reduceMotion {
            proxy.scrollTo(id, anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private var composerPlaceholder: String {
        switch task.onboardingStage {
        case .introducing:
            AppLocalization.string("Секунду…")
        case .awaitingIdentity:
            AppLocalization.string("Например: ты Муни, спокойный разработчик…")
        case .configuring:
            AppLocalization.string("Собираю профиль…")
        case nil:
            AppLocalization.string("Сообщение для \(task.title)…")
        }
    }

    private var commandArgumentPlaceholder: String {
        switch autocompletedSlashCommand?.name {
        case "/model":
            AppLocalization.string("Введите model-id или нажмите Enter")
        case "/session":
            AppLocalization.string("status, new, forget или resume…")
        case .some(_):
            AppLocalization.string("Enter — выполнить")
        case nil:
            composerPlaceholder
        }
    }

    private var resolvedComposerText: String {
        if composerTokens.count == 1,
           let commandToken = composerTokens.first,
           commandToken.utf16Offset == 0,
           let command = autocompletedSlashCommand {
            let arguments = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            return arguments.isEmpty
                ? command.name
                : "\(command.name) \(arguments)"
        }

        return InlineComposerContent.resolvedText(
            text: draft,
            tokens: composerTokens
        )
    }

    private func quickReplies(for message: TaskMessage) -> [String] {
        guard activeRun == nil,
              !isRepositoryBusy,
              message.role == .agent,
              message.id == task.chatMessages.last?.id
        else {
            return []
        }
        return AgentQuestionSuggestions.choices(from: message.text)
    }

    private func sendQuickReply(_ reply: String) {
        guard activeRun == nil, !isRepositoryBusy else { return }
        Swift.Task {
            await store.submitMessage(
                taskID: task.id,
                text: reply,
                attachments: []
            )
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            var selected = draftAttachments
            var existingPaths = Set(selected.map(\.filePath))

            for url in urls where selected.count < 20 {
                let standardizedURL = url.standardizedFileURL
                guard !existingPaths.contains(standardizedURL.path) else { continue }

                let isAccessing = standardizedURL.startAccessingSecurityScopedResource()
                defer {
                    if isAccessing {
                        standardizedURL.stopAccessingSecurityScopedResource()
                    }
                }

                let values = try? standardizedURL.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .contentTypeKey,
                    .fileSizeKey
                ])
                guard values?.isDirectory != true else { continue }

                let bookmark = try? standardizedURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                selected.append(
                    TaskAttachment(
                        fileName: standardizedURL.lastPathComponent,
                        filePath: standardizedURL.path,
                        contentTypeIdentifier: values?.contentType?.identifier,
                        byteCount: values?.fileSize.map(Int64.init),
                        securityScopedBookmarkData: bookmark
                    )
                )
                existingPaths.insert(standardizedURL.path)
            }

            draftAttachments = selected

        case let .failure(error):
            store.lastError = "Не удалось добавить файлы: \(error.localizedDescription)"
        }
    }

}

private struct TaskComposerCardHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
