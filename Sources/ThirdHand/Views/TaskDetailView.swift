import SwiftUI
import UniformTypeIdentifiers

struct TaskDetailView: View {
    @Environment(AppStore.self) private var store
    let task: CodingTask

    @State private var draft = ""
    @State private var draftAttachments: [TaskAttachment] = []
    @State private var isShowingFileImporter = false
    @State private var isCurrentLiveOutputRevealed = false
    @AppStorage("showRawTerminalLogs") private var showRawTerminalLogs = false
    @FocusState private var isComposerFocused: Bool

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draftAttachments.isEmpty
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

    var body: some View {
        TransparentVSplitView(
            top: messageList.environment(store),
            bottom: composer.environment(store),
            minimumTopHeight: 240,
            minimumBottomHeight: 120,
            idealBottomHeight: 160,
            maximumBottomHeight: 360
        )
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                toolbarIdentity
            }

            if let activeRun, task.onboardingStage != .configuring {
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
        }
        .onChange(of: activeRun?.attemptID) {
            isCurrentLiveOutputRevealed = false
        }
        .onChange(of: task.onboardingStage) { _, stage in
            if stage == .awaitingIdentity {
                isComposerFocused = true
            }
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
            "Агент " + task.title + ", " + toolbarStatusTitle
        )
    }

    private var toolbarStatusTitle: String {
        switch task.onboardingStage {
        case .introducing:
            "Знакомится"
        case .awaitingIdentity:
            "Ждёт описания"
        case .configuring:
            "Настраивается"
        case nil:
            activeRun == nil ? "В сети" : "Работает"
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
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastMessageID, anchor: .bottom)
                }
            }
            .onChange(of: activeRun) { _, run in
                guard let run else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(run.attemptID, anchor: .bottom)
                }
            }
            .onChange(of: task.onboardingStage) { _, stage in
                guard stage == .introducing || stage == .configuring else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(onboardingTypingID, anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let activeRun, task.onboardingStage != .configuring {
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

                TextField(
                    composerPlaceholder,
                    text: $draft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...7)
                .focused($isComposerFocused)
                .disabled(isComposerBlocked)
                .onSubmit(send)

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
                    .disabled(isComposerBlocked || task.onboardingStage != nil)
                    .help("Добавить файлы")

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
                        Button(action: send) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(canSubmit ? Color.white : Color.secondary)
                                .frame(width: 28, height: 28)
                                .background(canSubmit ? Color.accentColor : Color.secondary.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSubmit)
                        .help(
                            isRepositoryBusy
                                ? "Сначала дождитесь завершения работы в репозитории"
                                : "Отправить сообщение"
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
        }
        .padding(.horizontal, 24)
        .padding(.top, activeRun == nil ? 14 : 10)
        .padding(.bottom, 16)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draftAttachments.isEmpty,
              activeRun == nil,
              !isRepositoryBusy
        else {
            return
        }

        let attachments = draftAttachments
        draft = ""
        draftAttachments = []
        isComposerFocused = true

        Swift.Task {
            await store.submitMessage(
                taskID: task.id,
                text: text,
                attachments: attachments
            )
        }
    }

    private var composerPlaceholder: String {
        switch task.onboardingStage {
        case .introducing:
            "Секунду…"
        case .awaitingIdentity:
            "Например: ты Муни, спокойный разработчик…"
        case .configuring:
            "Собираю профиль…"
        case nil:
            "Сообщение для \(task.title)…"
        }
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
