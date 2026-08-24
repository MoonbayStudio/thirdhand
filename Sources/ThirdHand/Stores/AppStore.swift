import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
    var tasks: [CodingTask]
    var groupChats: [AgentGroupChat]
    var selection: UUID?
    var selectedFilter: TaskFilter = .all
    var agentInstallations: [AgentInstallation] = AgentKind.allCases.map {
        AgentInstallation(kind: $0, executablePath: nil)
    }
    var agentCapabilities = AgentCapabilityCatalog.fallback
    var activeRuns: [UUID: AgentRunState] = [:]
    var activeGroupRuns: [UUID: GroupChatRunState] = [:]
    var liveAgentOutputs: [UUID: AgentLiveOutput] = [:]
    var activeValidations: [UUID: ValidationExecutionState] = [:]
    var liveGitSnapshots: [UUID: GitSnapshot] = [:]
    var providerUsage: [AgentKind: ProviderUsageSnapshot] = Dictionary(
        uniqueKeysWithValues: AgentKind.allCases.map { ($0, .unknown(for: $0)) }
    )
    var isShowingInspector = true
    var isShowingSettings = false
    var isShowingNewGroupChatSheet = false
    var isRefreshingGit = false
    var isRefreshingUsage = false
    var taskPendingDeletion: UUID?
    var groupChatPendingDeletion: UUID?
    var lastError: String?

    private let persistence: PersistenceService
    private let gitService = GitService()
    private let agentDetector = AgentDetector()
    private let agentCapabilityDetector = AgentCapabilityDetector()
    private let taskOrchestrator = TaskOrchestrator()
    private let validationRecipeDetector = ValidationRecipeDetector()
    private let validationService = ValidationService()
    private let providerUsageService: any ProviderUsageProviding
    private let notificationService: any TaskNotificationSending
    private let handoffCompressor: any AgentHandoffCompressing
    private let conversationResponder: any OpenRouterConversationResponding
    private let apiExecutor: any AIAPIExecuting
    private let preferredAgentOrderProvider: () -> [AgentKind]
    private let usageAutoRefreshInterval: Duration
    private var persistenceAllowsWrites = true
    private var usageAutoRefreshTask: Task<Void, Never>?
    private var activeHandoffCompressionTasks: [
        UUID: Swift.Task<CompressedAgentHandoff?, Error>
    ] = [:]
    private var activeConversationResponseTasks: [
        UUID: Swift.Task<OpenRouterConversationResponse?, Error>
    ] = [:]
    private var activeAPIExecutionTasks: [
        UUID: Swift.Task<AIAPIExecutionResponse, Error>
    ] = [:]
    private var activeGroupConversationResponseTasks: [
        UUID: Swift.Task<OpenRouterConversationResponse?, Error>
    ] = [:]
    private var cancelledGroupChatIDs: Set<UUID> = []
    private var pendingUsageRefresh = false
    private var pendingUsageRefreshClearsInferredExhaustion = false
    private var lastProviderUsageRefreshAt: Date?

    init(
        persistence: PersistenceService = PersistenceService(),
        performAgentDiscovery: Bool = true,
        notificationService: any TaskNotificationSending = SystemTaskNotificationService.shared,
        providerUsageService: any ProviderUsageProviding = ProviderUsageService(),
        usageAutoRefreshInterval: Duration = .seconds(5 * 60),
        preferredAgentOrder: @escaping () -> [AgentKind] = {
            AgentRoutingPreferences.load()
        },
        handoffCompressor: any AgentHandoffCompressing = DisabledAgentHandoffCompressor(),
        conversationResponder: any OpenRouterConversationResponding = DisabledOpenRouterConversationResponder(),
        apiExecutor: any AIAPIExecuting = DisabledAIAPIExecutor()
    ) {
        self.persistence = persistence
        self.notificationService = notificationService
        self.providerUsageService = providerUsageService
        self.handoffCompressor = handoffCompressor
        self.conversationResponder = conversationResponder
        self.apiExecutor = apiExecutor
        self.usageAutoRefreshInterval = usageAutoRefreshInterval
        preferredAgentOrderProvider = preferredAgentOrder
        let loadedState = persistence.loadTasks()
        let loadedGroupState = persistence.loadGroupChats()
        tasks = loadedState.tasks
        groupChats = loadedGroupState.groupChats.map { storedChat in
            var chat = storedChat
            if chat.status == .discussing {
                chat.status = .ready
            }
            return chat
        }
        persistenceAllowsWrites = loadedState.allowsWrites
            && loadedGroupState.allowsWrites
        lastError = [loadedState.warning, loadedGroupState.warning]
            .compactMap { $0 }
            .joined(separator: "\n")
        if lastError?.isEmpty == true {
            lastError = nil
        }
        selection = tasks.first?.id ?? groupChats.first?.id
        resumePendingOnboardingIntroductions()

        if performAgentDiscovery {
            Task {
                let installations = await agentDetector.detect()
                agentInstallations = installations
                agentCapabilities = await agentCapabilityDetector.detect(installations: installations)
                await refreshProviderUsage()
                if let selection, tasks.contains(where: { $0.id == selection }) {
                    await refreshGit(
                        taskID: selection,
                        recordActivity: false
                    )
                }
            }
        }
    }

    var selectedTask: CodingTask? {
        guard let selection else { return nil }
        return tasks.first { $0.id == selection }
    }

    var selectedGroupChat: AgentGroupChat? {
        guard let selection else { return nil }
        return groupChats.first { $0.id == selection }
    }

    var sortedGroupChats: [AgentGroupChat] {
        groupChats.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    var automaticAgentOrder: [AgentKind] {
        preferredAgentOrderProvider()
    }

    var availableAPITargets: [AIAPITarget] {
        apiExecutor.availableTargets()
    }

    var filteredTasks: [CodingTask] {
        tasks
            .filter { task in
                switch selectedFilter {
                case .all: true
                case .running: task.status == .running
                case .needsAttention: task.status == .needsAttention
                case .completed: task.status == .completed
                }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var agents: [CodingTask] {
        tasks.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func effectiveAgent(for task: CodingTask) -> AgentKind {
        if let currentAgent = task.currentAgent {
            return currentAgent
        }

        return AutomaticAgentRouter.candidates(
            for: task,
            installations: agentInstallations,
            preferredOrder: automaticAgentOrder,
            usageSnapshots: providerUsage
        ).first ?? .codex
    }

    func preferredExecutionTarget(for task: CodingTask) -> AgentExecutionTarget {
        if task.effectiveRoutingMode == .manual,
           task.configuredExecutionSource == .api,
           let target = task.configuredAPITarget {
            return .api(target)
        }
        return .cli(effectiveAgent(for: task))
    }

    func executionTargets(for task: CodingTask) -> [AgentExecutionTarget] {
        if task.effectiveRoutingMode == .manual {
            if task.configuredExecutionSource == .api,
               let target = task.configuredAPITarget {
                return [.api(target)]
            }
            return AutomaticAgentRouter.candidates(
                for: task,
                installations: agentInstallations,
                preferredOrder: automaticAgentOrder,
                usageSnapshots: providerUsage
            ).map(AgentExecutionTarget.cli)
        }

        let cliTargets = AutomaticAgentRouter.candidates(
            for: task,
            installations: agentInstallations,
            preferredOrder: automaticAgentOrder,
            usageSnapshots: providerUsage
        ).map(AgentExecutionTarget.cli)
        let apiTargets = apiExecutor.availableTargets().map(AgentExecutionTarget.api)
        return cliTargets + apiTargets
    }

    func displayedGitSnapshot(for task: CodingTask) -> GitSnapshot {
        liveGitSnapshots[task.id] ?? task.gitSnapshot
    }

    func usageSnapshot(
        for agent: AgentKind,
        modelID: String? = nil
    ) -> ProviderUsageSnapshot {
        var snapshot = providerUsage[agent] ?? .unknown(for: agent)
        guard agent == .antigravity, !snapshot.windows.isEmpty else {
            return snapshot
        }

        guard let modelID, !modelID.isEmpty else {
            snapshot.windows = Self.conservativeAntigravityWindows(
                snapshot.windows
            )
            snapshot.detail += " Показан минимум по группам моделей."
            return snapshot
        }

        let normalizedModel = modelID.lowercased()
        let preferredPrefix = normalizedModel.contains("claude")
            || normalizedModel.contains("gpt")
            ? "claude-gpt-"
            : "gemini-"
        snapshot.windows = snapshot.windows.filter {
            $0.id.hasPrefix(preferredPrefix)
        } + snapshot.windows.filter {
            !$0.id.hasPrefix(preferredPrefix)
        }
        return snapshot
    }

    func capabilities(for task: CodingTask) -> AgentCapabilitySet {
        let kind = effectiveAgent(for: task)
        return capabilities(for: kind)
    }

    func capabilities(for kind: AgentKind) -> AgentCapabilitySet {
        return agentCapabilities[kind]
            ?? AgentCapabilityCatalog.fallback[kind]
            ?? AgentCapabilitySet(kind: kind, models: [])
    }

    func parameterDefinitions(for task: CodingTask) -> [AgentParameterDefinition] {
        let capabilities = capabilities(for: task)
        let selectedModelID = task.agentConfiguration?[.model]
        return capabilities.parameters(selectedModelID: selectedModelID)
    }

    func effectiveValue(
        for parameter: AgentParameterDefinition,
        in task: CodingTask
    ) -> String {
        guard let storedValue = task.agentConfiguration?[parameter.id],
              parameter.options.contains(where: { $0.id == storedValue })
        else {
            return parameter.defaultValue
        }
        return storedValue
    }

    func isAgentRunning(taskID: UUID) -> Bool {
        activeRuns[taskID] != nil
    }

    func isRepositoryBusyForInteraction(_ repositoryPath: String) -> Bool {
        isRepositoryBusy(
            repositoryPath,
            excludingValidationTaskID: nil
        )
    }

    func taskCount(for filter: TaskFilter) -> Int {
        switch filter {
        case .all: tasks.count
        case .running: tasks.filter { $0.status == .running }.count
        case .needsAttention: tasks.filter { $0.status == .needsAttention }.count
        case .completed: tasks.filter { $0.status == .completed }.count
        }
    }

    @discardableResult
    func beginAgentCreation(
        greetingDelay: Duration = .milliseconds(850)
    ) -> UUID {
        let taskID = UUID()
        let repositoryPath = suggestedRepositoryPath(for: taskID)
        let preferredAgent = automaticAgentOrder.first(where: { preferred in
            agentInstallations.contains { $0.kind == preferred && $0.isAvailable }
        }) ?? agentInstallations.first(where: \.isAvailable)?.kind ?? .codex

        var task = CodingTask(
            id: taskID,
            title: "Новый агент",
            originalRequest: "",
            repositoryPath: repositoryPath,
            status: .ready,
            currentAgent: preferredAgent,
            routingMode: .automatic,
            steps: [],
            validations: [],
            persona: AgentPersona(
                prompt: "Расскажите в чате, кем должен быть этот агент. Third Hand соберёт инструкции автоматически.",
                avatarColor: .indigo,
                needsReview: true,
                onboardingStage: .introducing
            )
        )
        task.activity.append(
            ActivityEvent(
                title: "Создан черновик агента",
                detail: "Профиль открыт справа, а знакомство началось в чате.",
                systemImage: "person.crop.circle.badge.plus"
            )
        )

        tasks.insert(task, at: 0)
        selection = taskID
        isShowingInspector = true
        persist()
        scheduleOnboardingGreeting(taskID: taskID, delay: greetingDelay)
        return taskID
    }

    func addTask(title: String, repositoryURL: URL) async {
        await addAgent(
            profile: AgentProfileDraft(
                name: title,
                personalityPrompt: "Ты — \(title), внимательный автономный разработчик. Общайся ясно, проверяй результат и честно сообщай о рисках.",
                repositoryPath: repositoryURL.path
            )
        )
    }

    func addAgent(profile: AgentProfileDraft) async {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = profile.personalityPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let repositoryPath = profile.repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty, !repositoryPath.isEmpty else {
            lastError = "Укажите имя, инструкции и рабочую папку агента."
            return
        }

        let storedConfiguration = Self.configuration(for: profile)
        var task = CodingTask(
            title: name,
            originalRequest: "",
            repositoryPath: repositoryPath,
            currentAgent: profile.agentKind,
            routingMode: profile.routingMode,
            agentConfiguration: storedConfiguration.isEmpty ? nil : storedConfiguration,
            persona: AgentPersona(
                prompt: prompt,
                avatarEmoji: profile.avatarEmoji,
                avatarImageData: profile.avatarImageData,
                avatarColor: profile.avatarColor,
                interactionMode: profile.interactionMode,
                needsReview: profile.needsReview
            )
        )
        task.activity.append(
            ActivityEvent(
                title: profile.needsReview ? "Создан черновик агента" : "Агент создан",
                detail: profile.needsReview
                    ? "Профиль собран из описания и ждёт проверки справа."
                    : "Профиль и модель сохранены; можно начинать диалог.",
                systemImage: "person.crop.circle.badge.plus"
            )
        )
        tasks.insert(task, at: 0)
        selection = task.id
        isShowingInspector = true
        persist()
        await refreshGit(taskID: task.id)
        await detectValidationRecipes(taskID: task.id)
    }

    var groupChatEligibleAgents: [CodingTask] {
        agents.filter { $0.onboardingStage == nil }
    }

    func participants(for group: AgentGroupChat) -> [CodingTask] {
        group.participantIDs.compactMap { participantID in
            tasks.first { $0.id == participantID }
        }
    }

    func mentionedParticipants(
        in text: String,
        group: AgentGroupChat
    ) -> [CodingTask] {
        AgentNameMentionResolver.mentionedParticipants(
            in: text,
            participants: participants(for: group)
        )
    }

    @discardableResult
    func createGroupChat(title: String, participantIDs: [UUID]) -> UUID? {
        let participants = participantIDs.compactMap { participantID in
            groupChatEligibleAgents.first { $0.id == participantID }
        }
        let uniqueParticipants = participants.reduce(into: [CodingTask]()) { result, participant in
            guard !result.contains(where: { $0.id == participant.id }) else { return }
            result.append(participant)
        }
        guard uniqueParticipants.count >= 2 else {
            lastError = "Для группового чата выберите минимум двух готовых агентов."
            return nil
        }
        guard uniqueParticipants.count <= 8 else {
            lastError = "В одном групповом чате может быть не больше восьми агентов."
            return nil
        }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = normalizedTitle.isEmpty
            ? uniqueParticipants.map(\.title).joined(separator: ", ")
            : normalizedTitle
        let introduction = GroupChatPromptBuilder.participantIntroduction(uniqueParticipants)
        let group = AgentGroupChat(
            title: resolvedTitle,
            participantIDs: uniqueParticipants.map(\.id),
            messages: [
                GroupChatMessage(role: .system, text: introduction)
            ]
        )
        groupChats.insert(group, at: 0)
        selection = group.id
        isShowingInspector = true
        isShowingNewGroupChatSheet = false
        persist()
        return group.id
    }

    func renameGroupChat(_ groupID: UUID, title: String) {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return }
        mutateGroupChat(groupID) { group in
            group.title = normalizedTitle
        }
    }

    func updateGroupParticipants(_ participantIDs: [UUID], groupID: UUID) {
        guard activeGroupRuns[groupID] == nil,
              let currentGroup = groupChats.first(where: { $0.id == groupID })
        else {
            lastError = "Состав группы нельзя менять во время обсуждения."
            return
        }

        let participants = participantIDs.compactMap { participantID in
            groupChatEligibleAgents.first { $0.id == participantID }
        }
        let uniqueParticipants = participants.reduce(into: [CodingTask]()) { result, participant in
            guard !result.contains(where: { $0.id == participant.id }) else { return }
            result.append(participant)
        }
        guard uniqueParticipants.count >= 2 else {
            lastError = "В групповом чате должно остаться минимум два агента."
            return
        }
        guard uniqueParticipants.count <= 8 else {
            lastError = "В одном групповом чате может быть не больше восьми агентов."
            return
        }

        let previousIDs = Set(currentGroup.participantIDs)
        let nextIDs = Set(uniqueParticipants.map(\.id))
        let added = uniqueParticipants.filter { !previousIDs.contains($0.id) }
        let removedNames = currentGroup.participantIDs
            .filter { !nextIDs.contains($0) }
            .compactMap { removedID in tasks.first(where: { $0.id == removedID })?.title }

        mutateGroupChat(groupID) { group in
            group.participantIDs = uniqueParticipants.map(\.id)
            if !added.isEmpty {
                group.messages.append(
                    GroupChatMessage(
                        role: .system,
                        text: "В чат добавлены: \(added.map(\.title).joined(separator: ", "))."
                    )
                )
            }
            if !removedNames.isEmpty {
                group.messages.append(
                    GroupChatMessage(
                        role: .system,
                        text: "Из чата вышли: \(removedNames.joined(separator: ", "))."
                    )
                )
            }
        }
    }

    @discardableResult
    func updateAgentProfile(_ profile: AgentProfileDraft, for taskID: UUID) -> Bool {
        guard activeRuns[taskID] == nil, activeValidations[taskID] == nil else {
            lastError = "Профиль нельзя менять, пока агент или проверка выполняется."
            return false
        }

        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = profile.personalityPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let repositoryPath = profile.repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty, !repositoryPath.isEmpty else {
            lastError = "Укажите имя, инструкции и рабочую папку агента."
            return false
        }

        let previousPath = tasks.first(where: { $0.id == taskID })?.repositoryPath
        let storedConfiguration = Self.configuration(for: profile)
        mutateTask(taskID) { task in
            task.title = name
            task.repositoryPath = repositoryPath
            task.routingMode = profile.routingMode
            task.currentAgent = profile.agentKind
            task.agentConfiguration = storedConfiguration.isEmpty ? nil : storedConfiguration
            task.persona = AgentPersona(
                prompt: prompt,
                avatarEmoji: profile.avatarEmoji,
                avatarImageData: profile.avatarImageData,
                avatarColor: profile.avatarColor,
                interactionMode: profile.interactionMode,
                needsReview: false
            )
            task.activity.insert(
                ActivityEvent(
                    title: "Профиль агента обновлён",
                    detail: "Имя, инструкции и параметры модели сохранены.",
                    systemImage: "person.crop.circle.badge.checkmark"
                ),
                at: 0
            )
        }

        if previousPath != repositoryPath {
            Task {
                await refreshGit(taskID: taskID)
                await detectValidationRecipes(taskID: taskID, force: true)
            }
        }
        return true
    }

    func submitMessage(
        taskID: UUID,
        text: String,
        attachments: [TaskAttachment]
    ) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !attachments.isEmpty,
              activeRuns[taskID] == nil,
              tasks.contains(where: { $0.id == taskID })
        else {
            return
        }
        guard let submittedTask = tasks.first(where: { $0.id == taskID }) else { return }

        let messageText: String
        if trimmedText.isEmpty {
            let names = attachments.map(\.fileName).joined(separator: ", ")
            messageText = names.isEmpty
                ? "Изучи приложенные файлы."
                : "Изучи приложенные файлы: \(names)."
        } else {
            messageText = trimmedText
        }

        switch submittedTask.onboardingStage {
        case .awaitingIdentity:
            await configureAgentProfile(
                taskID: taskID,
                description: messageText,
                attachments: attachments
            )
            return
        case .introducing, .configuring:
            return
        case nil:
            break
        }

        if attachments.isEmpty, trimmedText.hasPrefix("/") {
            do {
                if let command = try ChatSlashCommandParser.parse(trimmedText) {
                    await executeSlashCommand(command, taskID: taskID)
                }
            } catch {
                appendCommandMessage(
                    (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription,
                    to: taskID
                )
            }
            return
        }

        let interactionMode = submittedTask.effectiveInteractionMode.resolved(
            for: messageText,
            personalityPrompt: submittedTask.effectivePersona.prompt,
            recentMessages: submittedTask.chatMessages
                .filter { $0.role != .system }
                .suffix(6)
                .map(\.text)
        )
        if interactionMode == .workspace {
            guard !isRepositoryBusy(
                submittedTask.repositoryPath,
                excludingValidationTaskID: nil
            ) else {
                lastError = "Сначала дождитесь завершения агента или проверки в этом репозитории."
                return
            }
        }

        mutateTask(taskID) { task in
            var messages = task.messages ?? []
            messages.append(
                TaskMessage(
                    role: .user,
                    text: messageText,
                    attachments: attachments.isEmpty ? nil : attachments
                )
            )
            task.messages = messages
            task.status = .running

            if interactionMode == .workspace, task.originalRequest.isEmpty {
                task.originalRequest = messageText
                task.specification = TaskSpecification(objective: messageText)
                task.activity.insert(
                    ActivityEvent(
                        title: "Исходная задача получена",
                        detail: "Первое сообщение сохранено как исходный запрос Task.",
                        systemImage: "text.bubble"
                    ),
                    at: 0
                )
            }
        }

        guard let task = tasks.first(where: { $0.id == taskID }) else { return }
        if task.effectiveRoutingMode == .automatic,
           interactionMode == .conversation,
           attachments.isEmpty,
           await answerConversationThroughOpenRouter(
               taskID: taskID,
               task: task,
               messageText: messageText
           ) {
            return
        }

        let candidates = executionTargets(for: task)

        guard let firstTarget = candidates.first else {
            appendExecutionError(
                AgentExecutionError.launchFailed(
                    task.effectiveRoutingMode == .automatic
                        ? "В Auto нет доступного CLI или подключённого API. Проверьте раздел API в настройках."
                        : "Выбранный CLI или API не настроен."
                ),
                to: taskID
            )
            return
        }

        var pendingAttemptID = UUID()
        activeRuns[taskID] = AgentRunState(
            attemptID: pendingAttemptID,
            agent: firstTarget.fallbackAgentKind,
            executionTarget: firstTarget,
            interactionMode: interactionMode,
            phase: .preparing,
            startedAt: .now
        )
        liveAgentOutputs[taskID] = .empty
        let monitor: Swift.Task<Void, Never>? = interactionMode == .workspace
            ? Swift.Task { [weak self] in
                await self?.monitorRepository(taskID: taskID)
            }
            : nil

        executionLoop: for (candidateIndex, target) in candidates.enumerated() {
            let agent = target.fallbackAgentKind
            let attemptID = pendingAttemptID
            if activeRuns[taskID]?.attemptID != attemptID {
                activeRuns[taskID] = AgentRunState(
                    attemptID: attemptID,
                    agent: agent,
                    executionTarget: target,
                    interactionMode: interactionMode,
                    phase: .preparing,
                    startedAt: .now
                )
            }

            var preflightSnapshot: GitSnapshot?
            if case .cli = target,
               let currentTask = tasks.first(where: { $0.id == taskID }),
               currentTask.currentAgent != agent {
                let freshSnapshot: GitSnapshot
                if interactionMode == .workspace {
                    freshSnapshot = await gitService.snapshot(
                        at: URL(fileURLWithPath: currentTask.repositoryPath)
                    )
                } else {
                    freshSnapshot = .unavailable
                }
                guard activeRuns[taskID]?.attemptID == attemptID else {
                    break executionLoop
                }
                if interactionMode == .workspace {
                    liveGitSnapshots[taskID] = freshSnapshot
                }
                selectExecutionAgent(
                    agent,
                    for: taskID,
                    snapshot: freshSnapshot,
                    interactionMode: interactionMode
                )
                preflightSnapshot = freshSnapshot
            }
            guard var taskSnapshot = tasks.first(where: { $0.id == taskID }) else {
                break executionLoop
            }
            if interactionMode == .workspace, preflightSnapshot == nil {
                preflightSnapshot = await gitService.snapshot(
                    at: URL(fileURLWithPath: taskSnapshot.repositoryPath)
                )
                guard activeRuns[taskID]?.attemptID == attemptID else {
                    break executionLoop
                }
            }
            if interactionMode == .workspace, let preflightSnapshot {
                liveGitSnapshots[taskID] = preflightSnapshot
                taskSnapshot.gitSnapshot = preflightSnapshot
            }
            let retainedAttachments = Self.retainedAttachments(in: taskSnapshot)

            let prompt: String
            let workingDirectory: String
            let isGitRepository: Bool
            if interactionMode == .workspace {
                let repositoryContext = await gitService.handoffContext(
                    at: URL(fileURLWithPath: taskSnapshot.repositoryPath)
                )
                guard activeRuns[taskID]?.attemptID == attemptID else {
                    break executionLoop
                }
                prompt = TaskEnvelopeBuilder.build(
                    task: taskSnapshot,
                    currentInstruction: messageText,
                    attachments: retainedAttachments,
                    repositoryContext: repositoryContext
                )
                workingDirectory = taskSnapshot.repositoryPath
                isGitRepository = repositoryContext.isGitRepository
            } else {
                workingDirectory = conversationWorkingDirectory(for: taskID)
                prompt = ConversationEnvelopeBuilder.build(
                    task: taskSnapshot,
                    currentInstruction: messageText,
                    attachments: retainedAttachments,
                    includesRecentHistory: !resumesNativeSession(
                        target: target,
                        task: taskSnapshot,
                        interactionMode: interactionMode,
                        workingDirectory: workingDirectory
                    )
                )
                isGitRepository = false
            }

            if activeRuns[taskID]?.phase != .stopping {
                activeRuns[taskID]?.phase = .running
            }

            do {
                let response = try await execute(
                    target: target,
                    attemptID: attemptID,
                    taskID: taskID,
                    task: taskSnapshot,
                    repositoryPath: workingDirectory,
                    prompt: prompt,
                    attachments: retainedAttachments,
                    isGitRepository: isGitRepository,
                    interactionMode: interactionMode
                )
                let responseText = response.text
                guard activeRuns[taskID]?.attemptID == attemptID else {
                    break executionLoop
                }
                if activeRuns[taskID]?.phase == .stopping {
                    await taskOrchestrator.discardPendingCancellation(attemptID: attemptID)
                    appendExecutionError(AgentExecutionError.cancelled, to: taskID)
                    break executionLoop
                }

                let parsedResponse = AgentProgressReportParser.parse(responseText)
                let completionSnapshot: GitSnapshot
                if interactionMode == .workspace {
                    completionSnapshot = await gitService.snapshot(
                        at: URL(fileURLWithPath: taskSnapshot.repositoryPath)
                    )
                } else {
                    completionSnapshot = .unavailable
                }
                guard activeRuns[taskID]?.attemptID == attemptID else {
                    break executionLoop
                }
                if interactionMode == .workspace {
                    liveGitSnapshots[taskID] = completionSnapshot
                }
                mutateTask(taskID) { task in
                    if case let .cli(agent) = target,
                       agent.supportsNativeSessionResume,
                       let sessionID = response.nativeSessionID {
                        Self.storeSessionBinding(
                            sessionID: sessionID,
                            agent: agent,
                            interactionMode: interactionMode,
                            workingDirectory: workingDirectory,
                            modelID: taskSnapshot.agentConfiguration?[.model],
                            in: &task
                        )
                    }
                    if interactionMode == .workspace {
                        task.gitSnapshot = completionSnapshot
                    }
                    var messages = task.messages ?? []
                    messages.append(
                        TaskMessage(
                            role: .agent,
                            text: parsedResponse.displayText,
                            executionSource: target.source,
                            executionTargetName: target.displayName
                        )
                    )
                    task.messages = messages
                    task.status = .ready
                    if interactionMode == .conversation {
                        task.conversationHandoff = nil
                    }
                    if interactionMode == .workspace,
                       let progressReport = parsedResponse.progressReport {
                        let isReadyForReview = Self.applyProgressReport(
                            progressReport,
                            to: &task
                        )
                        if isReadyForReview {
                            task.status = .needsAttention
                        }
                        Self.appendCheckpoint(
                            to: &task,
                            reason: "Завершена попытка с обновлением semantic handoff"
                        )
                    }
                    task.activity.insert(
                        ActivityEvent(
                            title: interactionMode == .conversation
                                ? "Ответ получен"
                                : "Попытка агента завершена",
                            detail: interactionMode == .conversation
                                ? "\(target.displayName) продолжил диалог через \(target.source.title)."
                                : "\(target.displayName) вернул финальный ответ через \(target.source.title).",
                            systemImage: "checkmark.circle"
                        ),
                        at: 0
                    )
                }
                scheduleNotification(
                    taskID: taskID,
                    kind: AgentQuestionSuggestions.requiresUserResponse(
                        from: parsedResponse.displayText
                    ) ? .question : .resultReady
                )
                break executionLoop
            } catch {
                guard activeRuns[taskID]?.attemptID == attemptID else {
                    break executionLoop
                }

                if activeRuns[taskID]?.phase == .stopping {
                    await taskOrchestrator.discardPendingCancellation(attemptID: attemptID)
                    appendExecutionError(AgentExecutionError.cancelled, to: taskID)
                    break executionLoop
                }

                let quotaWasExceeded: Bool
                if let executionError = error as? AgentExecutionError,
                   case .usageLimitExceeded = executionError {
                    if case .cli = target {
                        markProviderExhausted(agent)
                    }
                    quotaWasExceeded = true
                } else if let apiError = error as? AIAPIError {
                    quotaWasExceeded = apiError.isQuotaExceeded
                } else {
                    quotaWasExceeded = false
                }

                if quotaWasExceeded {
                    let nextIndex = candidateIndex + 1
                    let canFailOver = taskSnapshot.effectiveRoutingMode == .automatic
                        && candidates.indices.contains(nextIndex)

                    if canFailOver {
                        let nextTarget = candidates[nextIndex]
                        let nextAgent = nextTarget.fallbackAgentKind
                        let nextAttemptID = UUID()
                        pendingAttemptID = nextAttemptID
                        activeRuns[taskID] = AgentRunState(
                            attemptID: nextAttemptID,
                            agent: nextAgent,
                            executionTarget: nextTarget,
                            interactionMode: interactionMode,
                            phase: .compressingContext,
                            startedAt: .now
                        )
                        let interruptedOutput = liveAgentOutputs[taskID]?.text

                        let freshSnapshot: GitSnapshot
                        if interactionMode == .workspace {
                            freshSnapshot = await gitService.snapshot(
                                at: URL(fileURLWithPath: taskSnapshot.repositoryPath)
                            )
                        } else {
                            freshSnapshot = .unavailable
                        }
                        guard activeRuns[taskID]?.attemptID == nextAttemptID else {
                            break executionLoop
                        }
                        if activeRuns[taskID]?.phase == .stopping {
                            await taskOrchestrator.discardPendingCancellation(
                                attemptID: nextAttemptID
                            )
                            appendExecutionError(AgentExecutionError.cancelled, to: taskID)
                            break executionLoop
                        }
                        if interactionMode == .workspace {
                            liveGitSnapshots[taskID] = freshSnapshot
                        }

                        let handoffTask = tasks.first(where: { $0.id == taskID })
                            ?? taskSnapshot
                        let compressionRequest = OpenRouterHandoffPromptBuilder.build(
                            task: handoffTask,
                            from: agent,
                            to: nextAgent,
                            gitSnapshot: freshSnapshot,
                            lastAgentOutput: interruptedOutput,
                            interactionMode: interactionMode
                        )
                        var compressedHandoff: CompressedAgentHandoff?
                        var compressionFailure: String?
                        let compressionTask = Swift.Task { [handoffCompressor] in
                            try await handoffCompressor.compress(compressionRequest)
                        }
                        activeHandoffCompressionTasks[taskID] = compressionTask
                        do {
                            compressedHandoff = try await compressionTask.value
                        } catch {
                            compressionFailure = String(
                                ((error as? LocalizedError)?.errorDescription
                                    ?? error.localizedDescription)
                                    .prefix(240)
                            )
                        }
                        activeHandoffCompressionTasks[taskID] = nil

                        guard activeRuns[taskID]?.attemptID == nextAttemptID else {
                            break executionLoop
                        }
                        if activeRuns[taskID]?.phase == .stopping {
                            await taskOrchestrator.discardPendingCancellation(
                                attemptID: nextAttemptID
                            )
                            appendExecutionError(AgentExecutionError.cancelled, to: taskID)
                            break executionLoop
                        }
                        activeRuns[taskID]?.phase = .preparing
                        liveAgentOutputs[taskID] = .empty
                        recordAutomaticFailover(
                            taskID: taskID,
                            from: target,
                            to: nextTarget,
                            snapshot: freshSnapshot,
                            interactionMode: interactionMode,
                            compressedHandoff: compressedHandoff,
                            compressionFailure: compressionFailure
                        )
                        continue executionLoop
                    }
                }

                appendExecutionError(error, to: taskID)
                break executionLoop
            }
        }

        monitor?.cancel()
        activeRuns[taskID] = nil
        liveAgentOutputs[taskID] = nil
        liveGitSnapshots[taskID] = nil
        if interactionMode == .workspace {
            await refreshGit(taskID: taskID)
        }
        await refreshProviderUsage()
    }

    func submitGroupMessage(groupID: UUID, text: String) async {
        let messageText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !messageText.isEmpty,
              activeGroupRuns[groupID] == nil,
              let submittedGroup = groupChats.first(where: { $0.id == groupID })
        else {
            return
        }

        let allParticipants = participants(for: submittedGroup)
        guard allParticipants.count >= 2 else {
            lastError = "Добавьте в групповой чат минимум двух доступных агентов."
            return
        }

        let mentioned = AgentNameMentionResolver.mentionedParticipants(
            in: messageText,
            participants: allParticipants
        )
        let speakers = mentioned.isEmpty ? allParticipants : mentioned
        let totalTurns = speakers.count == 1
            ? 1
            : min(speakers.count * 2, 6)
        cancelledGroupChatIDs.remove(groupID)

        mutateGroupChat(groupID) { group in
            group.messages.append(
                GroupChatMessage(role: .user, text: messageText)
            )
            group.status = .discussing
        }

        var successfulTurns = 0
        for turnIndex in 0..<totalTurns {
            guard !cancelledGroupChatIDs.contains(groupID),
                  let currentGroup = groupChats.first(where: { $0.id == groupID })
            else {
                finishCancelledGroupDiscussion(groupID)
                return
            }

            let scheduledSpeaker = speakers[turnIndex % speakers.count]
            guard let speaker = tasks.first(where: { $0.id == scheduledSpeaker.id }) else {
                continue
            }
            let prompt = GroupChatPromptBuilder.discussionPrompt(
                group: currentGroup,
                participants: participants(for: currentGroup),
                speaker: speaker,
                currentUserMessage: messageText,
                turn: turnIndex + 1,
                totalTurns: totalTurns
            )

            do {
                let response = try await performGroupResponse(
                    groupID: groupID,
                    participant: speaker,
                    prompt: prompt,
                    phase: .discussing
                )
                guard !cancelledGroupChatIDs.contains(groupID) else {
                    finishCancelledGroupDiscussion(groupID)
                    return
                }
                let executionTarget = activeGroupRuns[groupID]?.executionTarget
                mutateGroupChat(groupID) { group in
                    group.messages.append(
                        GroupChatMessage(
                            role: .agent,
                            text: response,
                            senderAgentID: speaker.id,
                            senderName: speaker.title,
                            executionSource: executionTarget?.source,
                            executionTargetName: executionTarget?.displayName
                        )
                    )
                }
                successfulTurns += 1
            } catch {
                if groupRunWasCancelled(error, groupID: groupID) {
                    finishCancelledGroupDiscussion(groupID)
                    return
                }
                mutateGroupChat(groupID) { group in
                    group.messages.append(
                        GroupChatMessage(
                            role: .system,
                            text: "\(speaker.title) не смог ответить: \(groupErrorDescription(error))"
                        )
                    )
                }
            }
        }

        guard successfulTurns > 0 else {
            mutateGroupChat(groupID) { $0.status = .needsAttention }
            clearGroupRun(groupID)
            await refreshProviderUsage()
            return
        }

        if speakers.count >= 2,
           successfulTurns >= 2,
           let currentGroup = groupChats.first(where: { $0.id == groupID }),
           let facilitator = tasks.first(where: { $0.id == speakers[0].id }) {
            let summaryPrompt = GroupChatPromptBuilder.summaryPrompt(
                group: currentGroup,
                participants: participants(for: currentGroup),
                facilitator: facilitator,
                currentUserMessage: messageText
            )
            do {
                let summary = try await performGroupResponse(
                    groupID: groupID,
                    participant: facilitator,
                    prompt: summaryPrompt,
                    phase: .summarizing
                )
                guard !cancelledGroupChatIDs.contains(groupID) else {
                    finishCancelledGroupDiscussion(groupID)
                    return
                }
                let executionTarget = activeGroupRuns[groupID]?.executionTarget
                mutateGroupChat(groupID) { group in
                    group.messages.append(
                        GroupChatMessage(
                            role: .summary,
                            text: summary,
                            senderAgentID: facilitator.id,
                            senderName: facilitator.title,
                            executionSource: executionTarget?.source,
                            executionTargetName: executionTarget?.displayName
                        )
                    )
                    group.status = .ready
                }
            } catch {
                if groupRunWasCancelled(error, groupID: groupID) {
                    finishCancelledGroupDiscussion(groupID)
                    return
                }
                mutateGroupChat(groupID) { group in
                    group.messages.append(
                        GroupChatMessage(
                            role: .system,
                            text: "Не удалось подготовить итог обсуждения: \(groupErrorDescription(error))"
                        )
                    )
                    group.status = .needsAttention
                }
            }
        } else {
            mutateGroupChat(groupID) { $0.status = .ready }
        }

        clearGroupRun(groupID)
        await refreshProviderUsage()
    }

    private func performGroupResponse(
        groupID: UUID,
        participant: CodingTask,
        prompt: String,
        phase: GroupChatRunPhase
    ) async throws -> String {
        guard !cancelledGroupChatIDs.contains(groupID) else {
            throw CancellationError()
        }

        var attemptID = UUID()
        let preferredTarget = preferredExecutionTarget(for: participant)
        let preferredAgent = preferredTarget.fallbackAgentKind
        activeGroupRuns[groupID] = GroupChatRunState(
            attemptID: attemptID,
            currentAgentID: participant.id,
            currentAgentName: participant.title,
            currentAgentKind: preferredAgent,
            executionTarget: preferredTarget,
            phase: phase,
            startedAt: .now
        )

        if participant.effectiveRoutingMode == .automatic {
            if let quickTarget = AIAPIPreferences.primaryTarget() {
                activeGroupRuns[groupID] = GroupChatRunState(
                    attemptID: attemptID,
                    currentAgentID: participant.id,
                    currentAgentName: participant.title,
                    currentAgentKind: AgentExecutionTarget.api(quickTarget).fallbackAgentKind,
                    executionTarget: .api(quickTarget),
                    phase: phase,
                    startedAt: .now
                )
            }
            let responseTask = Swift.Task { [conversationResponder] in
                try await conversationResponder.respond(
                    to: OpenRouterConversationRequest(prompt: prompt)
                )
            }
            activeGroupConversationResponseTasks[groupID] = responseTask
            do {
                let response = try await responseTask.value
                activeGroupConversationResponseTasks[groupID] = nil
                guard !cancelledGroupChatIDs.contains(groupID),
                      activeGroupRuns[groupID]?.attemptID == attemptID
                else {
                    throw CancellationError()
                }
                if let response {
                    let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { throw AgentExecutionError.emptyResponse }
                    return text
                }
            } catch {
                activeGroupConversationResponseTasks[groupID] = nil
                if groupRunWasCancelled(error, groupID: groupID) {
                    throw CancellationError()
                }
            }
        }

        let candidates = executionTargets(for: participant)
        guard !candidates.isEmpty else {
            throw AgentExecutionError.launchFailed(
                "Для \(participant.title) не найден доступный CLI или подключённый API."
            )
        }

        for (candidateIndex, target) in candidates.enumerated() {
            guard !cancelledGroupChatIDs.contains(groupID) else {
                throw CancellationError()
            }
            let agent = target.fallbackAgentKind

            attemptID = UUID()
            activeGroupRuns[groupID] = GroupChatRunState(
                attemptID: attemptID,
                currentAgentID: participant.id,
                currentAgentName: participant.title,
                currentAgentKind: agent,
                executionTarget: target,
                phase: phase,
                startedAt: .now
            )
            do {
                let responseText: String
                switch target {
                case let .cli(cliAgent):
                    guard let executablePath = agentInstallations
                        .first(where: { $0.kind == cliAgent })?
                        .executablePath
                    else {
                        throw AgentExecutionError.executableUnavailable(cliAgent)
                    }
                    let request = AgentExecutionRequest(
                        attemptID: attemptID,
                        taskID: groupID,
                        agent: cliAgent,
                        executablePath: executablePath,
                        repositoryPath: conversationWorkingDirectory(for: groupID),
                        prompt: prompt,
                        configuration: resolvedGroupConfiguration(
                            for: participant,
                            agent: cliAgent
                        ),
                        attachments: [],
                        isGitRepository: false
                    )
                    responseText = try await taskOrchestrator.execute(request).text
                case let .api(apiTarget):
                    let apiTask = Swift.Task { [apiExecutor] in
                        try await apiExecutor.execute(
                            AIAPIExecutionRequest(
                                target: apiTarget,
                                prompt: prompt,
                                maximumOutputTokens: 2_048
                            )
                        )
                    }
                    activeAPIExecutionTasks[groupID] = apiTask
                    do {
                        responseText = try await apiTask.value.text
                        activeAPIExecutionTasks[groupID] = nil
                    } catch {
                        activeAPIExecutionTasks[groupID] = nil
                        throw error
                    }
                }
                guard !cancelledGroupChatIDs.contains(groupID),
                      activeGroupRuns[groupID]?.attemptID == attemptID
                else {
                    throw CancellationError()
                }
                let text = AgentProgressReportParser.parse(responseText)
                    .displayText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw AgentExecutionError.emptyResponse }
                return text
            } catch {
                if groupRunWasCancelled(error, groupID: groupID) {
                    throw CancellationError()
                }
                let quotaWasExceeded: Bool
                if let executionError = error as? AgentExecutionError,
                   case .usageLimitExceeded = executionError {
                    markProviderExhausted(agent)
                    quotaWasExceeded = true
                } else if let apiError = error as? AIAPIError {
                    quotaWasExceeded = apiError.isQuotaExceeded
                } else {
                    quotaWasExceeded = false
                }
                if quotaWasExceeded,
                   participant.effectiveRoutingMode == .automatic,
                   candidates.indices.contains(candidateIndex + 1) {
                    continue
                }
                throw error
            }
        }

        throw AgentExecutionError.launchFailed(
            "Ни один настроенный провайдер не смог ответить от имени \(participant.title)."
        )
    }

    private func finishCancelledGroupDiscussion(_ groupID: UUID) {
        mutateGroupChat(groupID) { group in
            group.messages.append(
                GroupChatMessage(
                    role: .system,
                    text: "Обсуждение остановлено. Уже полученные реплики сохранены."
                )
            )
            group.status = .ready
        }
        clearGroupRun(groupID)
    }

    private func groupRunWasCancelled(_ error: Error, groupID: UUID) -> Bool {
        if cancelledGroupChatIDs.contains(groupID) || error is CancellationError {
            return true
        }
        if let executionError = error as? AgentExecutionError,
           case .cancelled = executionError {
            return true
        }
        return false
    }

    private func groupErrorDescription(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func clearGroupRun(_ groupID: UUID) {
        activeGroupConversationResponseTasks[groupID] = nil
        activeAPIExecutionTasks[groupID] = nil
        activeGroupRuns[groupID] = nil
        cancelledGroupChatIDs.remove(groupID)
    }

    private func configureAgentProfile(
        taskID: UUID,
        description: String,
        attachments: [TaskAttachment]
    ) async {
        mutateTask(taskID) { task in
            guard task.onboardingStage == .awaitingIdentity else { return }
            var messages = task.messages ?? []
            messages.append(
                TaskMessage(
                    role: .user,
                    text: description,
                    attachments: attachments.isEmpty ? nil : attachments
                )
            )
            task.messages = messages
            task.status = .running
            task.persona?.onboardingStage = .configuring
            task.activity.insert(
                ActivityEvent(
                    title: "ИИ собирает профиль",
                    detail: "Описание отправлено внутреннему конфигуратору; его ответ не появится в чате.",
                    systemImage: "wand.and.stars"
                ),
                at: 0
            )
        }

        await discoverAgentsForOnboardingIfNeeded()
        guard let taskSnapshot = tasks.first(where: { $0.id == taskID }),
              taskSnapshot.onboardingStage == .configuring
        else {
            return
        }

        let candidates = AutomaticAgentRouter.candidates(
            for: taskSnapshot,
            installations: agentInstallations,
            preferredOrder: automaticAgentOrder,
            usageSnapshots: providerUsage
        )
        guard let firstAgent = candidates.first else {
            applyLocalProfileFallback(
                taskID: taskID,
                description: description,
                reason: "Доступный CLI не найден."
            )
            return
        }

        let prompt = AgentProfileGenerationPromptBuilder.build(
            description: description,
            availableModels: availableModelDescription()
        )
        let workingDirectory = profileGenerationWorkingDirectory(for: taskID)
        var pendingAttemptID = UUID()
        activeRuns[taskID] = AgentRunState(
            attemptID: pendingAttemptID,
            agent: firstAgent,
            interactionMode: .conversation,
            phase: .preparing,
            startedAt: .now
        )

        var configuredProfile: GeneratedAgentProfile?
        var configurationAgent: AgentKind?
        var fallbackReason = "ИИ не смог собрать профиль."
        var wasCancelled = false

        generationLoop: for (candidateIndex, agent) in candidates.enumerated() {
            let attemptID = pendingAttemptID
            activeRuns[taskID] = AgentRunState(
                attemptID: attemptID,
                agent: agent,
                interactionMode: .conversation,
                phase: .running,
                startedAt: .now
            )

            guard let executablePath = agentInstallations
                .first(where: { $0.kind == agent })?
                .executablePath
            else {
                fallbackReason = "CLI для \(agent.shortName) не найден."
                continue
            }

            let request = AgentExecutionRequest(
                attemptID: attemptID,
                taskID: taskID,
                agent: agent,
                executablePath: executablePath,
                repositoryPath: workingDirectory,
                prompt: prompt,
                configuration: profileGenerationConfiguration(for: agent),
                attachments: [],
                isGitRepository: false
            )

            do {
                let response = try await taskOrchestrator.execute(request)
                guard activeRuns[taskID]?.attemptID == attemptID else {
                    wasCancelled = true
                    break generationLoop
                }
                if activeRuns[taskID]?.phase == .stopping {
                    await taskOrchestrator.discardPendingCancellation(attemptID: attemptID)
                    restoreOnboardingAfterCancellation(taskID: taskID)
                    wasCancelled = true
                    break generationLoop
                }

                configuredProfile = try AgentProfileGenerationResponseParser.parse(response.text)
                configurationAgent = agent
                break generationLoop
            } catch let executionError as AgentExecutionError {
                guard activeRuns[taskID]?.attemptID == attemptID else {
                    wasCancelled = true
                    break generationLoop
                }

                if case .cancelled = executionError {
                    await taskOrchestrator.discardPendingCancellation(attemptID: attemptID)
                    restoreOnboardingAfterCancellation(taskID: taskID)
                    wasCancelled = true
                    break generationLoop
                }

                if case .usageLimitExceeded = executionError {
                    markProviderExhausted(agent)
                    let nextIndex = candidateIndex + 1
                    if taskSnapshot.effectiveRoutingMode == .automatic,
                       candidates.indices.contains(nextIndex) {
                        pendingAttemptID = UUID()
                        continue generationLoop
                    }
                }

                fallbackReason = executionError.errorDescription
                    ?? "ИИ не смог собрать профиль."
                break generationLoop
            } catch {
                fallbackReason = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                break generationLoop
            }
        }

        activeRuns[taskID] = nil
        liveAgentOutputs[taskID] = nil

        if let configuredProfile, let configurationAgent {
            applyGeneratedProfile(
                configuredProfile,
                executionAgent: configurationAgent,
                taskID: taskID
            )
        } else if !wasCancelled,
                  tasks.first(where: { $0.id == taskID })?.onboardingStage == .configuring {
            applyLocalProfileFallback(
                taskID: taskID,
                description: description,
                reason: fallbackReason
            )
        }

        await refreshProviderUsage()
    }

    private func applyGeneratedProfile(
        _ profile: GeneratedAgentProfile,
        executionAgent: AgentKind,
        taskID: UUID
    ) {
        let availableKinds = Set(
            agentInstallations.compactMap { $0.isAvailable ? $0.kind : nil }
        )
        let modelAgent = profile.modelID.flatMap { modelID in
            availableKinds.first { kind in
                capabilities(for: kind).models.contains { $0.id == modelID }
            }
        }
        let requestedAgent = profile.agentKind ?? modelAgent
        let availableRequestedAgent = requestedAgent.flatMap {
            availableKinds.contains($0) ? $0 : nil
        }
        let selectedAgent = availableRequestedAgent
            ?? executionAgent
        let requestedModelIsAvailable = profile.modelID.map { modelID in
            capabilities(for: selectedAgent).models.contains { $0.id == modelID }
        } ?? false
        let shouldPinAgent = profile.routingMode == .manual
            && (availableRequestedAgent != nil || requestedModelIsAvailable)

        var configuration = TaskAgentConfiguration()
        if let modelID = profile.modelID,
           capabilities(for: selectedAgent).models.contains(where: { $0.id == modelID }) {
            configuration[.model] = modelID
        }

        mutateTask(taskID) { task in
            let previousPersona = task.effectivePersona
            task.title = profile.name
            task.routingMode = shouldPinAgent ? .manual : .automatic
            task.currentAgent = selectedAgent
            task.agentConfiguration = configuration.isEmpty ? nil : configuration
            task.persona = AgentPersona(
                prompt: profile.personalityPrompt,
                avatarEmoji: previousPersona.avatarEmoji,
                avatarImageData: previousPersona.avatarImageData,
                avatarColor: profile.avatarColor,
                interactionMode: profile.interactionMode,
                needsReview: true
            )
            var messages = task.messages ?? []
            messages.append(
                TaskMessage(
                    role: .system,
                    text: "Профиль настроен. Имя, характер и модель можно проверить и подправить справа."
                )
            )
            task.messages = messages
            task.status = .ready
            task.activity.insert(
                ActivityEvent(
                    title: "Профиль собран ИИ",
                    detail: "Служебный ответ применён к профилю и не добавлен в чат.",
                    systemImage: "person.crop.circle.badge.checkmark"
                ),
                at: 0
            )
        }
    }

    private func applyLocalProfileFallback(
        taskID: UUID,
        description: String,
        reason: String
    ) {
        let profile = AgentProfileGenerationResponseParser.localFallback(from: description)
        mutateTask(taskID) { task in
            let previousPersona = task.effectivePersona
            task.title = profile.name
            task.persona = AgentPersona(
                prompt: profile.personalityPrompt,
                avatarEmoji: previousPersona.avatarEmoji,
                avatarImageData: previousPersona.avatarImageData,
                avatarColor: profile.avatarColor,
                interactionMode: profile.interactionMode,
                needsReview: true
            )
            var messages = task.messages ?? []
            messages.append(
                TaskMessage(
                    role: .system,
                    text: "ИИ сейчас недоступен, поэтому Third Hand собрал черновик локально. Проверьте профиль справа."
                )
            )
            task.messages = messages
            task.status = .ready
            task.activity.insert(
                ActivityEvent(
                    title: "Профиль собран локально",
                    detail: String(reason.prefix(240)),
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                ),
                at: 0
            )
        }
    }

    private func restoreOnboardingAfterCancellation(taskID: UUID) {
        mutateTask(taskID) { task in
            task.persona?.onboardingStage = .awaitingIdentity
            task.status = .ready
            var messages = task.messages ?? []
            messages.append(
                TaskMessage(
                    role: .system,
                    text: "Настройка остановлена. Отправьте описание ещё раз, когда будете готовы."
                )
            )
            task.messages = messages
        }
    }

    func stopAgentRun(taskID: UUID) async {
        guard var run = activeRuns[taskID] else { return }
        run.phase = .stopping
        activeRuns[taskID] = run
        activeConversationResponseTasks[taskID]?.cancel()
        activeAPIExecutionTasks[taskID]?.cancel()
        activeHandoffCompressionTasks[taskID]?.cancel()
        await taskOrchestrator.cancel(taskID: taskID, attemptID: run.attemptID)
    }

    func stopGroupChat(groupID: UUID) async {
        guard let run = activeGroupRuns[groupID] else { return }
        cancelledGroupChatIDs.insert(groupID)
        if let apiTask = activeAPIExecutionTasks[groupID] {
            apiTask.cancel()
        } else if let responseTask = activeGroupConversationResponseTasks[groupID] {
            responseTask.cancel()
        } else {
            await taskOrchestrator.cancel(
                taskID: groupID,
                attemptID: run.attemptID
            )
        }
    }

    func deleteSelectedTask() {
        guard let selection else { return }
        if tasks.contains(where: { $0.id == selection }) {
            requestTaskDeletion(selection)
        } else if groupChats.contains(where: { $0.id == selection }) {
            requestGroupChatDeletion(selection)
        }
    }

    func requestTaskDeletion(_ taskID: UUID) {
        guard tasks.contains(where: { $0.id == taskID }) else { return }
        guard activeRuns[taskID] == nil,
              activeValidations[taskID] == nil,
              !activeGroupRuns.keys.contains(where: { groupID in
                  groupChats.first(where: { $0.id == groupID })?
                      .participantIDs.contains(taskID) == true
              })
        else {
            lastError = "Сначала остановите работающего агента, проверку или групповое обсуждение с его участием."
            return
        }
        taskPendingDeletion = taskID
    }

    func confirmTaskDeletion() {
        guard let taskID = taskPendingDeletion else { return }
        guard activeRuns[taskID] == nil,
              activeValidations[taskID] == nil
        else {
            taskPendingDeletion = nil
            lastError = "Сначала остановите работающего агента или проверку."
            return
        }

        let removedName = tasks.first(where: { $0.id == taskID })?.title ?? "Агент"
        tasks.removeAll { $0.id == taskID }
        for index in groupChats.indices where groupChats[index].participantIDs.contains(taskID) {
            groupChats[index].participantIDs.removeAll { $0 == taskID }
            groupChats[index].messages.append(
                GroupChatMessage(
                    role: .system,
                    text: "\(removedName) удалён из Third Hand и больше не участвует в этом чате."
                )
            )
            if groupChats[index].participantIDs.count < 2 {
                groupChats[index].status = .needsAttention
            }
            groupChats[index].updatedAt = .now
        }
        liveGitSnapshots[taskID] = nil
        if selection == taskID {
            selection = agents.first?.id ?? sortedGroupChats.first?.id
        }
        taskPendingDeletion = nil
        persist()
        Task {
            await notificationService.removeNotifications(taskID: taskID)
        }
    }

    func cancelTaskDeletion() {
        taskPendingDeletion = nil
    }

    func requestGroupChatDeletion(_ groupID: UUID) {
        guard groupChats.contains(where: { $0.id == groupID }) else { return }
        guard activeGroupRuns[groupID] == nil else {
            lastError = "Сначала остановите групповое обсуждение."
            return
        }
        groupChatPendingDeletion = groupID
    }

    func confirmGroupChatDeletion() {
        guard let groupID = groupChatPendingDeletion else { return }
        guard activeGroupRuns[groupID] == nil else {
            groupChatPendingDeletion = nil
            lastError = "Сначала остановите групповое обсуждение."
            return
        }

        groupChats.removeAll { $0.id == groupID }
        if selection == groupID {
            selection = sortedGroupChats.first?.id ?? agents.first?.id
        }
        groupChatPendingDeletion = nil
        persist()
    }

    func cancelGroupChatDeletion() {
        groupChatPendingDeletion = nil
    }

    func startOrResume(_ id: UUID) {
        let task = tasks.first(where: { $0.id == id })
        let automaticCandidate = task.flatMap {
            AutomaticAgentRouter.candidates(
                for: $0,
                installations: agentInstallations,
                preferredOrder: automaticAgentOrder,
                usageSnapshots: providerUsage
            ).first
        }

        mutateTask(id) { task in
            let availableKinds = agentInstallations.filter(\.isAvailable).map(\.kind)
            if task.currentAgent == nil {
                task.currentAgent = automaticCandidate ?? availableKinds.first ?? .codex
            }
            task.status = .running
            task.activity.insert(
                ActivityEvent(
                    title: "Задача переведена в работу",
                    detail: "\(task.currentAgent?.displayName ?? "Агент") выбран. Отправьте сообщение, чтобы запустить новую попытку.",
                    systemImage: "play.fill"
                ),
                at: 0
            )
        }
    }

    func updateSpecification(_ specification: TaskSpecification, for taskID: UUID) {
        guard activeRuns[taskID] == nil,
              activeValidations[taskID] == nil
        else {
            lastError = "Спецификацию нельзя менять, пока выполняется агент или проверка."
            return
        }

        mutateTask(taskID) { task in
            let current = task.effectiveSpecification
            let normalized = TaskSpecification(
                objective: specification.objective,
                requirementUpdates: specification.requirementUpdates,
                constraints: specification.constraints,
                acceptanceCriteria: specification.acceptanceCriteria,
                productDecisions: specification.productDecisions,
                outOfScope: specification.outOfScope,
                openQuestions: specification.openQuestions,
                revision: current.revision,
                updatedAt: current.updatedAt
            )
            guard !normalized.objective.isEmpty,
                  Self.specificationContent(normalized)
                    != Self.specificationContent(current)
            else {
                return
            }

            var updated = normalized
            updated.revision = current.revision + 1
            updated.updatedAt = .now
            task.specification = updated
            task.activity.insert(
                ActivityEvent(
                    title: "Спецификация обновлена",
                    detail: "Сохранена ревизия \(updated.revision). Следующие попытки получат актуальный контракт задачи.",
                    systemImage: "doc.badge.gearshape"
                ),
                at: 0
            )
        }
    }

    func openTaskFromNotification(_ taskID: UUID) {
        guard tasks.contains(where: { $0.id == taskID }) else { return }
        selectedFilter = .all
        selection = taskID
        Task {
            await notificationService.removeNotifications(taskID: taskID)
        }
    }

    func selectAgent(_ kind: AgentKind, for taskID: UUID) {
        guard activeRuns[taskID] == nil else { return }
        mutateTask(taskID) { task in
            task.routingMode = .manual
            if task.currentAgent == kind {
                var configuration = task.agentConfiguration ?? TaskAgentConfiguration()
                configuration[.executionSource] = AgentExecutionSource.cli.rawValue
                task.agentConfiguration = configuration
                return
            }
            let previous = task.currentAgent
            let requiresHandoff = previous != nil && task.status == .running
            Self.applyAgentSelection(
                kind,
                previous: previous,
                requiresHandoff: requiresHandoff,
                to: &task
            )
            var configuration = task.agentConfiguration ?? TaskAgentConfiguration()
            configuration[.executionSource] = AgentExecutionSource.cli.rawValue
            task.agentConfiguration = configuration
        }
    }

    func selectAPI(_ target: AIAPITarget, for taskID: UUID) {
        guard activeRuns[taskID] == nil else { return }
        mutateTask(taskID) { task in
            task.routingMode = .manual
            var configuration = task.agentConfiguration ?? TaskAgentConfiguration()
            configuration[.executionSource] = AgentExecutionSource.api.rawValue
            configuration[.apiProvider] = target.provider.rawValue
            configuration[.apiModel] = target.modelID
            task.agentConfiguration = configuration
            task.activity.insert(
                ActivityEvent(
                    title: "API назначен агенту",
                    detail: "Следующий ответ выполнит \(target.displayName).",
                    systemImage: "key.horizontal"
                ),
                at: 0
            )
        }
    }

    func selectAutomaticRouting(for taskID: UUID) {
        guard activeRuns[taskID] == nil,
              let task = tasks.first(where: { $0.id == taskID })
        else {
            return
        }

        let preferredAgent = AutomaticAgentRouter.candidates(
            routingMode: .automatic,
            currentAgent: task.currentAgent,
            installations: agentInstallations,
            preferredOrder: automaticAgentOrder,
            usageSnapshots: providerUsage,
            antigravityModelID: task.agentConfiguration?[.model]
        ).first

        mutateTask(taskID) { task in
            task.routingMode = .automatic
            guard let preferredAgent, task.currentAgent != preferredAgent else {
                task.activity.insert(
                    ActivityEvent(
                        title: "Включён режим Авто",
                        detail: "Провайдеры будут использоваться в порядке из Settings; переключение происходит только при подтверждённом лимите.",
                        systemImage: "arrow.triangle.2.circlepath"
                    ),
                    at: 0
                )
                return
            }

            let previous = task.currentAgent
            Self.applyAgentSelection(
                preferredAgent,
                previous: previous,
                requiresHandoff: previous != nil,
                to: &task
            )
        }
    }

    func setAgentOption(
        _ option: AgentOptionID,
        to value: String?,
        for taskID: UUID
    ) {
        let fallbackAgent = tasks
            .first(where: { $0.id == taskID })
            .map(effectiveAgent(for:))

        mutateTask(taskID) { task in
            if task.currentAgent == nil {
                task.currentAgent = fallbackAgent
            }

            var configuration = task.agentConfiguration ?? TaskAgentConfiguration()
            configuration[option] = value?.isEmpty == false ? value : nil

            if option == .model {
                configuration[.reasoningEffort] = nil
                configuration[.speedTier] = nil
            }

            task.agentConfiguration = configuration.isEmpty ? nil : configuration
        }
    }

    func resetAgentConfiguration(for taskID: UUID) {
        mutateTask(taskID) { task in
            task.agentConfiguration = nil
        }
    }

    func pause(_ id: UUID) {
        if activeRuns[id] != nil {
            Task { await stopAgentRun(taskID: id) }
            return
        }
        mutateTask(id) { task in
            task.status = .paused
            task.activity.insert(
                ActivityEvent(
                    title: "Задача поставлена на паузу",
                    detail: "Git-состояние сохранено; активный этап не потерян.",
                    systemImage: "pause.fill"
                ),
                at: 0
            )
        }
    }

    func switchAgent(_ id: UUID) {
        guard activeRuns[id] == nil else {
            lastError = "Сначала остановите работающего агента."
            return
        }
        mutateTask(id) { task in
            task.routingMode = .manual
            let available = agentInstallations.filter(\.isAvailable).map(\.kind)
            let candidates = available.isEmpty ? AgentKind.allCases : available
            let currentIndex = task.currentAgent.flatMap { candidates.firstIndex(of: $0) } ?? -1
            let nextIndex = (currentIndex + 1) % candidates.count
            let previous = task.currentAgent
            Self.applyAgentSelection(
                candidates[nextIndex],
                previous: previous,
                requiresHandoff: previous != nil,
                to: &task
            )
            task.status = .running
        }
    }

    func createCheckpoint(_ id: UUID) {
        mutateTask(id) { task in
            Self.appendCheckpoint(to: &task, reason: "Ручной checkpoint")
            task.activity.insert(
                ActivityEvent(
                    title: "Checkpoint сохранён",
                    detail: "Зафиксированы Git snapshot и semantic handoff.",
                    systemImage: "bookmark.fill"
                ),
                at: 0
            )
        }
    }

    func toggleStep(taskID: UUID, stepID: UUID) {
        var becameCompleted = false
        mutateTask(taskID) { task in
            guard let index = task.steps.firstIndex(where: { $0.id == stepID }) else { return }
            task.steps[index].isCompleted.toggle()
            let completed = task.steps.filter(\.isCompleted).map(\.title)
            task.handoff.progress = completed.isEmpty
                ? ["Этапы ещё не завершены."]
                : Array(completed.suffix(4))
            task.handoff.nextStep = task.steps.first(where: { !$0.isCompleted })?.title
                ?? "Проверить результат и завершить задачу."
            task.handoff.updatedAt = .now

            if task.steps.allSatisfy(\.isCompleted) {
                becameCompleted = task.status != .completed
                task.status = .completed
            } else if task.status == .completed {
                task.status = .paused
            }
        }
        if becameCompleted {
            scheduleNotification(taskID: taskID, kind: .taskCompleted)
        }
    }

    func refreshGit(taskID: UUID, recordActivity: Bool = true) async {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return }
        isRefreshingGit = true
        let snapshot = await gitService.snapshot(at: URL(fileURLWithPath: task.repositoryPath))
        liveGitSnapshots[taskID] = nil
        if recordActivity {
            mutateTask(taskID) { updatedTask in
                updatedTask.gitSnapshot = snapshot
                updatedTask.activity.insert(
                    ActivityEvent(
                        title: "Git snapshot обновлён",
                        detail: snapshot.isGitRepository
                            ? "\(snapshot.branch) @ \(snapshot.head), файлов: \(snapshot.changedFiles.count)"
                            : "Папка не распознана как Git-репозиторий.",
                        systemImage: "arrow.clockwise"
                    ),
                    at: 0
                )
            }
        } else if let index = tasks.firstIndex(where: { $0.id == taskID }) {
            tasks[index].gitSnapshot = snapshot
            persist()
        }
        isRefreshingGit = false
    }

    func refreshProviderUsage(clearInferredExhaustion: Bool = false) async {
        if isRefreshingUsage {
            pendingUsageRefresh = true
            pendingUsageRefreshClearsInferredExhaustion =
                pendingUsageRefreshClearsInferredExhaustion
                || clearInferredExhaustion
            return
        }

        isRefreshingUsage = true
        var shouldClearInferredExhaustion = clearInferredExhaustion

        repeat {
            pendingUsageRefresh = false
            pendingUsageRefreshClearsInferredExhaustion = false

            let runningAgents = Set(activeRuns.values.map(\.agent))
            let installations = agentInstallations.filter {
                !runningAgents.contains($0.kind)
            }
            let refreshed = await providerUsageService.snapshots(
                for: installations
            )
            lastProviderUsageRefreshAt = .now

            for kind in AgentKind.allCases {
                guard let snapshot = refreshed[kind] else { continue }
                if snapshot.state == .unknown,
                   let existing = providerUsage[kind],
                   existing.state != .unknown {
                    if shouldClearInferredExhaustion
                        || Date.now.timeIntervalSince(existing.updatedAt) >= 15 * 60 {
                        providerUsage[kind] = snapshot
                        continue
                    }
                    if existing.source == .executionError,
                       !existing.blocksAutomaticRouting() {
                        providerUsage[kind] = snapshot
                        continue
                    }
                    if existing.state == .exhausted,
                       !existing.blocksAutomaticRouting() {
                        providerUsage[kind] = snapshot
                        continue
                    }
                    continue
                }
                providerUsage[kind] = snapshot
            }

            shouldClearInferredExhaustion =
                pendingUsageRefreshClearsInferredExhaustion
        } while pendingUsageRefresh

        isRefreshingUsage = false
    }

    func startUsageAutoRefresh() {
        guard usageAutoRefreshTask == nil else { return }
        let interval = usageAutoRefreshInterval

        if agentInstallations.contains(where: \.isAvailable),
           lastProviderUsageRefreshAt.map({
               Date.now.timeIntervalSince($0) >= 60
           }) ?? true {
            Task { [weak self] in
                await self?.refreshProviderUsage()
            }
        }

        usageAutoRefreshTask = Task { [weak self] in
            while !Swift.Task.isCancelled {
                do {
                    try await Swift.Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Swift.Task.isCancelled else { return }
                Task { [weak self] in
                    await self?.refreshProviderUsage()
                }
            }
        }
    }

    func stopUsageAutoRefresh() {
        usageAutoRefreshTask?.cancel()
        usageAutoRefreshTask = nil
    }

    private static func conservativeAntigravityWindows(
        _ windows: [ProviderUsageWindow]
    ) -> [ProviderUsageWindow] {
        ["weekly", "five-hour"].compactMap { period in
            let candidates = windows.filter {
                $0.id.hasSuffix("-\(period)")
            }
            guard let minimum = candidates.min(by: {
                $0.remainingFraction < $1.remainingFraction
            }) else {
                return nil
            }

            return ProviderUsageWindow(
                id: "all-\(period)",
                title: minimum.title,
                remainingFraction: minimum.remainingFraction,
                resetsAt: minimum.resetsAt
            )
        }
    }

    func detectValidationRecipes(taskID: UUID, force: Bool = false) async {
        guard let task = tasks.first(where: { $0.id == taskID }),
              force || task.validationRecipes == nil
        else {
            return
        }

        let recipes = await validationRecipeDetector.detect(
            at: URL(fileURLWithPath: task.repositoryPath)
        )
        mutateTask(taskID) { task in
            task.validationRecipes = recipes
            let previousByName = Dictionary(
                uniqueKeysWithValues: task.validations.map { ($0.name, $0) }
            )
            task.validations = recipes.map { recipe in
                var run = previousByName[recipe.name]
                    ?? ValidationRun(name: recipe.name)
                run.recipeID = recipe.id
                return run
            }
            task.activity.insert(
                ActivityEvent(
                    title: "Проверки обнаружены",
                    detail: recipes.isEmpty
                        ? "Поддерживаемые build/test recipes не найдены."
                        : recipes.map(\.name).joined(separator: ", "),
                    systemImage: "checklist"
                ),
                at: 0
            )
        }
    }

    @discardableResult
    func runValidation(taskID: UUID, recipeID: UUID) async -> Bool {
        guard let task = tasks.first(where: { $0.id == taskID }),
              let recipe = task.validationRecipes?.first(where: { $0.id == recipeID })
        else {
            lastError = "Validation recipe больше недоступен."
            return false
        }
        guard !isRepositoryBusy(task.repositoryPath, excludingValidationTaskID: nil) else {
            lastError = "Репозиторий занят агентом или другой проверкой."
            return false
        }

        let attemptID = UUID()
        activeValidations[taskID] = ValidationExecutionState(
            attemptID: attemptID,
            recipeID: recipe.id,
            name: recipe.name,
            startedAt: .now,
            output: "",
            wasTruncated: false,
            isStopping: false
        )
        let beforeSnapshot = await gitService.snapshot(
            at: URL(fileURLWithPath: task.repositoryPath)
        )
        guard let reservedValidation = activeValidations[taskID],
              reservedValidation.attemptID == attemptID,
              !reservedValidation.isStopping
        else {
            activeValidations[taskID] = nil
            await validationService.discardPendingCancellation(
                attemptID: attemptID
            )
            return false
        }
        mutateTask(taskID) { task in
            task.gitSnapshot = beforeSnapshot
            Self.updateValidationRun(
                in: &task,
                recipe: recipe
            ) { run in
                run.outcome = .running
                run.summary = "Выполняется: \(recipe.commandDescription)"
                run.startedAt = .now
                run.finishedAt = nil
                run.exitCode = nil
                run.duration = nil
                run.output = nil
                run.gitFingerprint = beforeSnapshot.fingerprint
            }
        }

        do {
            let result = try await validationService.run(
                taskID: taskID,
                attemptID: attemptID,
                recipe: recipe,
                repositoryPath: task.repositoryPath
            ) { [weak self] output in
                await self?.recordLiveValidationOutput(
                    output,
                    taskID: taskID,
                    attemptID: attemptID
                )
            }
            guard activeValidations[taskID]?.attemptID == attemptID else {
                return false
            }

            let afterSnapshot = await gitService.snapshot(
                at: URL(fileURLWithPath: task.repositoryPath)
            )
            let repositoryChanged = beforeSnapshot.fingerprint != afterSnapshot.fingerprint
            mutateTask(taskID) { task in
                task.gitSnapshot = afterSnapshot
                Self.updateValidationRun(
                    in: &task,
                    recipe: recipe
                ) { run in
                    run.outcome = result.exitCode == 0 ? .passed : .failed
                    run.summary = Self.validationSummary(
                        exitCode: result.exitCode,
                        duration: result.duration,
                        repositoryChanged: repositoryChanged
                    )
                    run.finishedAt = .now
                    run.exitCode = result.exitCode
                    run.duration = result.duration
                    run.output = String(result.output.suffix(16_000))
                    run.gitFingerprint = beforeSnapshot.fingerprint
                }
                task.activity.insert(
                    ActivityEvent(
                        title: result.exitCode == 0
                            ? "Проверка пройдена"
                            : "Проверка завершилась ошибкой",
                        detail: "\(recipe.name): exit \(result.exitCode).",
                        systemImage: result.exitCode == 0
                            ? "checkmark.circle.fill"
                            : "xmark.circle.fill"
                    ),
                    at: 0
                )
            }
            activeValidations[taskID] = nil
            if result.exitCode != 0 {
                scheduleNotification(taskID: taskID, kind: .attention)
            }
            return result.exitCode == 0 && !repositoryChanged
        } catch {
            guard activeValidations[taskID]?.attemptID == attemptID else {
                return false
            }
            let wasCancelled: Bool
            if let validationError = error as? ValidationExecutionError,
               case .cancelled = validationError {
                wasCancelled = true
            } else {
                wasCancelled = false
            }
            mutateTask(taskID) { task in
                Self.updateValidationRun(
                    in: &task,
                    recipe: recipe
                ) { run in
                    run.outcome = wasCancelled ? .cancelled : .failed
                    run.summary = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    run.finishedAt = .now
                    run.output = activeValidations[taskID]?.output
                    run.gitFingerprint = beforeSnapshot.fingerprint
                }
                task.activity.insert(
                    ActivityEvent(
                        title: wasCancelled
                            ? "Проверка остановлена"
                            : "Проверка не выполнена",
                        detail: recipe.name,
                        systemImage: wasCancelled
                            ? "stop.circle"
                            : "exclamationmark.triangle"
                    ),
                    at: 0
                )
            }
            activeValidations[taskID] = nil
            if !wasCancelled {
                scheduleNotification(taskID: taskID, kind: .attention)
            }
            return false
        }
    }

    func runAllValidations(taskID: UUID) async {
        guard let recipes = tasks
            .first(where: { $0.id == taskID })?
            .validationRecipes
        else {
            return
        }
        let ordered = recipes.sorted { lhs, rhs in
            validationOrder(lhs.kind) < validationOrder(rhs.kind)
        }
        for recipe in ordered {
            guard await runValidation(taskID: taskID, recipeID: recipe.id) else {
                return
            }
        }
    }

    func stopValidation(taskID: UUID) async {
        guard var state = activeValidations[taskID] else { return }
        state.isStopping = true
        activeValidations[taskID] = state
        await validationService.cancel(
            taskID: taskID,
            attemptID: state.attemptID
        )
    }

    private func resumePendingOnboardingIntroductions() {
        for task in tasks where task.onboardingStage == .introducing {
            scheduleOnboardingGreeting(taskID: task.id, delay: .milliseconds(250))
        }
    }

    private func scheduleOnboardingGreeting(
        taskID: UUID,
        delay: Duration
    ) {
        Swift.Task { [weak self] in
            do {
                try await Swift.Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self else { return }
            deliverOnboardingGreeting(taskID: taskID)
        }
    }

    private func deliverOnboardingGreeting(taskID: UUID) {
        mutateTask(taskID) { task in
            guard task.onboardingStage == .introducing else { return }
            task.persona?.onboardingStage = .awaitingIdentity
            var messages = task.messages ?? []
            if !messages.contains(where: { $0.role == .agent && $0.text == "Я кто?" }) {
                messages.append(TaskMessage(role: .agent, text: "Я кто?"))
            }
            task.messages = messages
        }
    }

    private func suggestedRepositoryPath(for taskID: UUID) -> String {
        let storedDefault = UserDefaults.standard.string(
            forKey: "defaultRepositoriesFolderPath"
        )
        let candidates = [selectedTask?.repositoryPath, storedDefault]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for path in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return path
            }
        }

        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let workspace = support
            .appendingPathComponent("Third Hand", isDirectory: true)
            .appendingPathComponent("Agent Workspaces", isDirectory: true)
            .appendingPathComponent(taskID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        return workspace.path
    }

    private func discoverAgentsForOnboardingIfNeeded() async {
        guard !agentInstallations.contains(where: \.isAvailable) else { return }
        let installations = await agentDetector.detect()
        agentInstallations = installations
        agentCapabilities = await agentCapabilityDetector.detect(
            installations: installations
        )
    }

    private func availableModelDescription() -> String {
        let lines = agentInstallations.compactMap { installation -> String? in
            guard installation.isAvailable else { return nil }
            let modelIDs = capabilities(for: installation.kind).models.map(\.id)
            return "\(installation.kind.rawValue): "
                + (modelIDs.isEmpty ? "default" : modelIDs.joined(separator: ", "))
        }
        return lines.isEmpty ? "Нет доступных CLI." : lines.joined(separator: "\n")
    }

    private func profileGenerationWorkingDirectory(for taskID: UUID) -> String {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let directory = support
            .appendingPathComponent("Third Hand", isDirectory: true)
            .appendingPathComponent("Profile Generation", isDirectory: true)
            .appendingPathComponent(taskID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.path
    }

    private func conversationWorkingDirectory(for taskID: UUID) -> String {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let directory = support
            .appendingPathComponent("Third Hand", isDirectory: true)
            .appendingPathComponent("Conversation Sessions", isDirectory: true)
            .appendingPathComponent(taskID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.path
    }

    private func answerConversationThroughOpenRouter(
        taskID: UUID,
        task: CodingTask,
        messageText: String
    ) async -> Bool {
        let attemptID = UUID()
        let quickTarget = AIAPIPreferences.primaryTarget()
            .map(AgentExecutionTarget.api)
            ?? .cli(task.currentAgent ?? .codex)
        activeRuns[taskID] = AgentRunState(
            attemptID: attemptID,
            agent: quickTarget.fallbackAgentKind,
            executionTarget: quickTarget,
            interactionMode: .conversation,
            phase: .running,
            startedAt: .now
        )
        liveAgentOutputs[taskID] = .empty

        let prompt = ConversationEnvelopeBuilder.build(
            task: task,
            currentInstruction: messageText,
            attachments: []
        )
        let responseTask = Swift.Task { [conversationResponder] in
            try await conversationResponder.respond(
                to: OpenRouterConversationRequest(prompt: prompt)
            )
        }
        activeConversationResponseTasks[taskID] = responseTask

        do {
            guard let response = try await responseTask.value else {
                clearOpenRouterConversationRun(taskID: taskID, attemptID: attemptID)
                return false
            }
            guard activeRuns[taskID]?.attemptID == attemptID else {
                activeConversationResponseTasks[taskID] = nil
                return true
            }
            if activeRuns[taskID]?.phase == .stopping {
                appendExecutionError(AgentExecutionError.cancelled, to: taskID)
                clearOpenRouterConversationRun(taskID: taskID, attemptID: attemptID)
                return true
            }

            mutateTask(taskID) { task in
                var messages = task.messages ?? []
                messages.append(
                    TaskMessage(
                        role: .agent,
                        text: response.text,
                        executionSource: .api,
                        executionTargetName: response.modelID
                    )
                )
                task.messages = messages
                task.status = .ready
                task.conversationHandoff = nil
                task.activity.insert(
                    ActivityEvent(
                        title: "Быстрый ответ получен",
                        detail: "\(response.modelID) ответил через API.",
                        systemImage: "bolt.circle"
                    ),
                    at: 0
                )
            }
            scheduleNotification(
                taskID: taskID,
                kind: AgentQuestionSuggestions.requiresUserResponse(from: response.text)
                    ? .question
                    : .resultReady
            )
            clearOpenRouterConversationRun(taskID: taskID, attemptID: attemptID)
            return true
        } catch {
            let wasStopped = activeRuns[taskID]?.attemptID == attemptID
                && activeRuns[taskID]?.phase == .stopping
            if wasStopped || error is CancellationError {
                if activeRuns[taskID]?.attemptID == attemptID {
                    appendExecutionError(AgentExecutionError.cancelled, to: taskID)
                }
                clearOpenRouterConversationRun(taskID: taskID, attemptID: attemptID)
                return true
            }

            clearOpenRouterConversationRun(taskID: taskID, attemptID: attemptID)
            mutateTask(taskID) { task in
                task.activity.insert(
                    ActivityEvent(
                        title: "Основной API недоступен",
                        detail: "Быстрый маршрут не ответил; продолжаем по очереди Auto.",
                        systemImage: "arrow.triangle.2.circlepath"
                    ),
                    at: 0
                )
            }
            return false
        }
    }

    private func clearOpenRouterConversationRun(
        taskID: UUID,
        attemptID: UUID
    ) {
        activeConversationResponseTasks[taskID] = nil
        guard activeRuns[taskID]?.attemptID == attemptID else { return }
        activeRuns[taskID] = nil
        liveAgentOutputs[taskID] = nil
    }

    private func conversationConfiguration(
        _ base: [String: String],
        for agent: AgentKind
    ) -> [String: String] {
        var configuration = base
        for (key, value) in profileGenerationConfiguration(for: agent) {
            configuration[key] = value
        }
        return configuration
    }

    private func profileGenerationConfiguration(
        for agent: AgentKind
    ) -> [String: String] {
        switch agent {
        case .codex:
            [
                AgentOptionID.sandboxMode.rawValue: "read-only",
                AgentOptionID.approvalPolicy.rawValue: "never"
            ]
        case .claudeCode:
            [AgentOptionID.permissionMode.rawValue: "plan"]
        case .antigravity:
            [
                AgentOptionID.executionMode.rawValue: "plan",
                AgentOptionID.sandboxMode.rawValue: "enabled"
            ]
        case .deepSeek:
            [AgentOptionID.sandboxMode.rawValue: "read-only"]
        }
    }

    private func monitorRepository(taskID: UUID) async {
        while !Swift.Task.isCancelled,
              activeRuns[taskID] != nil,
              let task = tasks.first(where: { $0.id == taskID }) {
            let snapshot = await gitService.snapshot(
                at: URL(fileURLWithPath: task.repositoryPath)
            )
            guard !Swift.Task.isCancelled, activeRuns[taskID] != nil else { return }
            liveGitSnapshots[taskID] = snapshot

            do {
                try await Swift.Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }

    private func recordLiveAgentOutput(
        _ output: AgentLiveOutput,
        taskID: UUID,
        attemptID: UUID
    ) {
        guard activeRuns[taskID]?.attemptID == attemptID else { return }
        liveAgentOutputs[taskID] = output
    }

    private func recordLiveValidationOutput(
        _ output: AgentLiveOutput,
        taskID: UUID,
        attemptID: UUID
    ) {
        guard var state = activeValidations[taskID],
              state.attemptID == attemptID
        else {
            return
        }
        state.output = output.text
        state.wasTruncated = output.wasTruncated
        activeValidations[taskID] = state
    }

    private func selectExecutionAgent(
        _ agent: AgentKind,
        for taskID: UUID,
        snapshot: GitSnapshot,
        interactionMode: AgentInteractionMode
    ) {
        mutateTask(taskID) { task in
            guard task.currentAgent != agent else { return }
            if interactionMode == .workspace {
                task.gitSnapshot = snapshot
            }
            let previous = task.currentAgent
            Self.applyAgentSelection(
                agent,
                previous: previous,
                requiresHandoff: previous != nil,
                interactionMode: interactionMode,
                to: &task
            )
        }
    }

    private func markProviderExhausted(_ agent: AgentKind) {
        providerUsage[agent] = .exhausted(
            for: agent,
            detail: "CLI сообщил, что лимит \(agent.shortName) исчерпан."
        )
    }

    private func recordAutomaticFailover(
        taskID: UUID,
        from previousTarget: AgentExecutionTarget,
        to nextTarget: AgentExecutionTarget,
        snapshot: GitSnapshot,
        interactionMode: AgentInteractionMode,
        compressedHandoff: CompressedAgentHandoff?,
        compressionFailure: String?
    ) {
        mutateTask(taskID) { task in
            let previousAgent = previousTarget.fallbackAgentKind
            let nextAgent = nextTarget.fallbackAgentKind
            let previousName = previousTarget.shortName
            let nextName = nextTarget.shortName
            let isConversation = interactionMode == .conversation
            let portableHandoff = compressedHandoff
                ?? PortableContextBuilder.localFallback(
                    for: task,
                    interactionMode: interactionMode
                )
            if !isConversation {
                task.gitSnapshot = snapshot
            }
            let issue = "\(previousName): лимит исчерпан."

            if case .cli = nextTarget {
                Self.applyAgentSelection(
                    nextAgent,
                    previous: previousAgent,
                    requiresHandoff: true,
                    interactionMode: interactionMode,
                    to: &task
                )
            }

            if isConversation {
                task.conversationHandoff = ConversationHandoff(
                    facts: portableHandoff.decisions,
                    recentContext: portableHandoff.progress,
                    openThreads: portableHandoff.knownIssues,
                    nextReply: portableHandoff.nextStep,
                    updatedAt: .now
                )
            } else if let compressedHandoff {
                if !compressedHandoff.decisions.isEmpty {
                    task.handoff.decisions = compressedHandoff.decisions
                }
                if !compressedHandoff.progress.isEmpty {
                    task.handoff.progress = compressedHandoff.progress
                }
                task.handoff.knownIssues = compressedHandoff.knownIssues
                task.handoff.nextStep = compressedHandoff.nextStep
            }
            task.portableContextCheckpoint = PortableContextBuilder.checkpoint(
                from: portableHandoff,
                task: task,
                interactionMode: interactionMode
            )
            if !isConversation {
                task.handoff.knownIssues.removeAll { $0 == issue }
                task.handoff.knownIssues = Array(
                    (task.handoff.knownIssues + [issue]).suffix(4)
                )
                task.handoff.updatedAt = .now
            }

            var messages = task.messages ?? []
            let handoffDescription: String
            if isConversation, let compressedHandoff {
                handoffDescription = "API-модель \(compressedHandoff.modelID) сжала историю; Авто продолжил диалог через \(nextName)."
            } else if isConversation, compressionFailure != nil {
                handoffDescription = "API-handoff недоступен, поэтому Авто продолжил диалог через \(nextName) с локальным контекстом."
            } else if isConversation {
                handoffDescription = "Авто продолжил диалог через \(nextName)."
            } else if let compressedHandoff {
                handoffDescription = "API-модель \(compressedHandoff.modelID) сжала контекст; Авто передал задачу \(nextName)."
            } else if compressionFailure != nil {
                handoffDescription = "API-handoff недоступен, поэтому локальный handoff передал задачу \(nextName)."
            } else {
                handoffDescription = "Авто передал задачу \(nextName); следующий исполнитель получил актуальный контекст."
            }
            messages.append(
                TaskMessage(
                    role: .system,
                    text: "Лимит \(previousName) исчерпан. \(handoffDescription)"
                )
            )
            task.messages = messages
            task.status = .running
            task.activity.insert(
                ActivityEvent(
                    title: compressedHandoff == nil
                        ? "Auto failover"
                        : "Бесшовный handoff",
                        detail: {
                            if let compressedHandoff {
                                return "\(previousName) → \(nextName). Контекст сжала \(compressedHandoff.modelID)."
                            }
                            if let compressionFailure {
                                return "\(previousName) → \(nextName). Локальный handoff: \(compressionFailure)"
                            }
                            return "\(previousName) → \(nextName) после подтверждённой ошибки лимита."
                        }(),
                    systemImage: "arrow.triangle.2.circlepath"
                ),
                at: 0
            )
        }
    }

    private func executeSlashCommand(
        _ command: ChatSlashCommand,
        taskID: UUID
    ) async {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return }

        switch command {
        case .help:
            return

        case .context:
            appendCommandMessage(contextDescription(for: task), to: taskID)

        case .compact:
            await createPortableCheckpoint(
                taskID: taskID,
                resetsNativeSessions: true
            )

        case .handoff:
            await createPortableCheckpoint(
                taskID: taskID,
                resetsNativeSessions: false
            )

        case let .model(requestedModel):
            executeModelCommand(
                requestedModel,
                taskID: taskID,
                task: task
            )

        case let .session(sessionCommand):
            executeSessionCommand(
                sessionCommand,
                taskID: taskID,
                task: task
            )
        }
    }

    private func executeModelCommand(
        _ requestedModel: String?,
        taskID: UUID,
        task: CodingTask
    ) {
        switch preferredExecutionTarget(for: task) {
        case let .api(target):
            let models = availableAPITargets
                .filter { $0.provider == target.provider }
                .map(\.modelID)
            guard let requestedModel else {
                appendCommandMessage(
                    "Текущая модель: \(target.displayName).\nДоступно: \(models.isEmpty ? "список моделей не загружен" : models.joined(separator: ", ")).",
                    to: taskID
                )
                return
            }
            guard let selected = models.first(where: {
                $0.caseInsensitiveCompare(requestedModel) == .orderedSame
            }) else {
                appendCommandMessage(
                    "Модель «\(requestedModel)» не найдена для \(target.provider.displayName). Введите /model, чтобы увидеть список.",
                    to: taskID
                )
                return
            }
            setAgentOption(.apiModel, to: selected, for: taskID)
            appendCommandMessage(
                "Модель API изменена: \(target.provider.displayName) · \(selected).",
                to: taskID
            )

        case let .cli(agent):
            let capabilitySet = capabilities(for: agent)
            let currentModel = task.agentConfiguration?[.model]
                ?? capabilitySet.defaultModelID
            guard let requestedModel else {
                let options = capabilitySet.models.map(\.id)
                appendCommandMessage(
                    "Текущая модель \(agent.shortName): \(currentModel.isEmpty ? "управляется CLI" : currentModel).\nДоступно: \(options.isEmpty ? "CLI не публикует список моделей" : options.joined(separator: ", ")).",
                    to: taskID
                )
                return
            }
            guard let selected = capabilitySet.models.first(where: { model in
                model.id.caseInsensitiveCompare(requestedModel) == .orderedSame
                    || model.title.caseInsensitiveCompare(requestedModel) == .orderedSame
            }) else {
                appendCommandMessage(
                    "Модель «\(requestedModel)» не найдена для \(agent.shortName). Введите /model, чтобы увидеть список.",
                    to: taskID
                )
                return
            }
            setAgentOption(.model, to: selected.id, for: taskID)
            appendCommandMessage(
                "Модель \(agent.shortName) изменена на \(selected.title). Существующая нативная сессия будет продолжена с новым параметром модели.",
                to: taskID
            )
        }
    }

    private func executeSessionCommand(
        _ command: ChatSessionCommand,
        taskID: UUID,
        task: CodingTask
    ) {
        guard case let .cli(agent) = preferredExecutionTarget(for: task) else {
            appendCommandMessage(
                "Текущий исполнитель работает через API. Нативный CLI resume не используется; непрерывность обеспечивает checkpoint в state.json.",
                to: taskID
            )
            return
        }
        guard agent.supportsNativeSessionResume else {
            appendCommandMessage(
                "\(agent.shortName) в текущем headless-режиме Third Hand не предоставляет совместимый resume. Используйте /compact или /handoff: переносимый checkpoint сохраняется в state.json.",
                to: taskID
            )
            return
        }

        let interactionMode = commandInteractionMode(for: task)
        let scope = AgentSessionScope(interactionMode: interactionMode)
        let workingDirectory = workingDirectory(
            for: task,
            interactionMode: interactionMode
        )
        let binding = Self.sessionBinding(
            in: task,
            agent: agent,
            scope: scope,
            workingDirectory: workingDirectory
        )

        switch command {
        case .status:
            let current = binding.map {
                "Активная сессия \(agent.shortName) [\(scope.title)]: \($0.sessionID)\nМодель: \($0.modelID ?? "по умолчанию")\nОбновлена: \($0.updatedAt.formatted(date: .abbreviated, time: .shortened))"
            } ?? "Для \(agent.shortName) [\(scope.title)] ещё нет привязанной нативной сессии. Следующее сообщение создаст её автоматически."
            let otherBindings = (task.nativeSessionBindings ?? [])
                .filter { $0.sessionID != binding?.sessionID }
                .map { "- \($0.agent.shortName) [\($0.scope.title)]: \($0.sessionID)" }
            appendCommandMessage(
                otherBindings.isEmpty
                    ? current
                    : current + "\n\nДругие сохранённые сессии:\n" + otherBindings.joined(separator: "\n"),
                to: taskID
            )

        case .new:
            clearSessionBindings(
                taskID: taskID,
                agent: agent,
                scope: scope
            )
            appendCommandMessage(
                "Привязка \(agent.shortName) [\(scope.title)] сброшена. Следующее сообщение начнёт новую нативную сессию; локальная история и checkpoint сохранены.",
                to: taskID
            )

        case .forget:
            clearSessionBindings(
                taskID: taskID,
                agent: agent,
                scope: scope
            )
            appendCommandMessage(
                "Third Hand забыл привязку \(agent.shortName) [\(scope.title)]. Файлы сессии самого CLI не удалялись.",
                to: taskID
            )

        case let .resume(sessionID):
            mutateTask(taskID) { updatedTask in
                Self.storeSessionBinding(
                    sessionID: sessionID,
                    agent: agent,
                    interactionMode: interactionMode,
                    workingDirectory: workingDirectory,
                    modelID: updatedTask.agentConfiguration?[.model],
                    in: &updatedTask
                )
            }
            appendCommandMessage(
                "Привязана сессия \(agent.shortName): \(sessionID). Следующее сообщение будет отправлено через native resume.",
                to: taskID
            )
        }
    }

    private func createPortableCheckpoint(
        taskID: UUID,
        resetsNativeSessions: Bool
    ) async {
        guard activeRuns[taskID] == nil,
              let task = tasks.first(where: { $0.id == taskID })
        else {
            return
        }
        let interactionMode = commandInteractionMode(for: task)
        let target = preferredExecutionTarget(for: task)
        let attemptID = UUID()
        activeRuns[taskID] = AgentRunState(
            attemptID: attemptID,
            agent: target.fallbackAgentKind,
            executionTarget: target,
            interactionMode: interactionMode,
            phase: .compressingContext,
            startedAt: .now
        )
        liveAgentOutputs[taskID] = .empty

        let request = PortableContextBuilder.compressionRequest(
            for: task,
            interactionMode: interactionMode,
            agent: target.fallbackAgentKind
        )
        let compressionTask = Swift.Task { [handoffCompressor] in
            try await handoffCompressor.compress(request)
        }
        activeHandoffCompressionTasks[taskID] = compressionTask

        var usedLocalFallback = false
        let compressed: CompressedAgentHandoff
        do {
            if let remote = try await compressionTask.value {
                compressed = remote
            } else {
                usedLocalFallback = true
                compressed = PortableContextBuilder.localFallback(
                    for: task,
                    interactionMode: interactionMode
                )
            }
        } catch is CancellationError {
            activeHandoffCompressionTasks[taskID] = nil
            await taskOrchestrator.discardPendingCancellation(attemptID: attemptID)
            activeRuns[taskID] = nil
            liveAgentOutputs[taskID] = nil
            appendCommandMessage("Сжатие контекста остановлено.", to: taskID)
            return
        } catch {
            usedLocalFallback = true
            compressed = PortableContextBuilder.localFallback(
                for: task,
                interactionMode: interactionMode
            )
        }
        activeHandoffCompressionTasks[taskID] = nil

        guard activeRuns[taskID]?.attemptID == attemptID,
              activeRuns[taskID]?.phase != .stopping
        else {
            await taskOrchestrator.discardPendingCancellation(attemptID: attemptID)
            activeRuns[taskID] = nil
            liveAgentOutputs[taskID] = nil
            appendCommandMessage("Сжатие контекста остановлено.", to: taskID)
            return
        }

        let latestTask = tasks.first(where: { $0.id == taskID }) ?? task
        let checkpoint = PortableContextBuilder.checkpoint(
            from: compressed,
            task: latestTask,
            interactionMode: interactionMode
        )
        mutateTask(taskID) { updatedTask in
            updatedTask.portableContextCheckpoint = checkpoint
            if interactionMode == .conversation {
                updatedTask.conversationHandoff = nil
            } else {
                updatedTask.handoff.decisions = compressed.decisions
                updatedTask.handoff.progress = compressed.progress
                updatedTask.handoff.knownIssues = compressed.knownIssues
                updatedTask.handoff.nextStep = compressed.nextStep
                updatedTask.handoff.updatedAt = .now
            }
            if resetsNativeSessions {
                let scope = AgentSessionScope(interactionMode: interactionMode)
                updatedTask.nativeSessionBindings?.removeAll { $0.scope == scope }
                if updatedTask.nativeSessionBindings?.isEmpty == true {
                    updatedTask.nativeSessionBindings = nil
                }
            }
            var messages = updatedTask.messages ?? []
            let source = usedLocalFallback ? "локально" : "через \(compressed.modelID)"
            let effect = resetsNativeSessions
                ? " Следующее сообщение начнёт чистую нативную сессию."
                : " Checkpoint готов для handoff без разрыва текущей сессии."
            messages.append(
                TaskMessage(
                    role: .system,
                    text: "Контекст сжат \(source): \(checkpoint.sourceMessageCount) сообщений, примерно \(checkpoint.estimatedOriginalTokens.formatted()) токенов исходной истории.\(effect)"
                )
            )
            updatedTask.messages = messages
            updatedTask.activity.insert(
                ActivityEvent(
                    title: resetsNativeSessions ? "Контекст сжат" : "Handoff подготовлен",
                    detail: "Checkpoint сохранён в state.json (\(source)).",
                    systemImage: "arrow.triangle.2.circlepath"
                ),
                at: 0
            )
        }
        activeRuns[taskID] = nil
        liveAgentOutputs[taskID] = nil
    }

    private func contextDescription(for task: CodingTask) -> String {
        let interactionMode = commandInteractionMode(for: task)
        let scope = AgentSessionScope(interactionMode: interactionMode)
        let target = preferredExecutionTarget(for: task)
        let history = task.chatMessages.filter { $0.role != .system }
        let checkpoint = task.portableContextCheckpoint.flatMap {
            $0.scope == scope ? $0 : nil
        }

        let contextLines: [String]
        if interactionMode == .conversation {
            let inspection = ConversationEnvelopeBuilder.inspect(task: task)
            contextLines = [
                "Режим: \(scope.title)",
                "История в приложении: \(inspection.totalMessages) сообщений",
                "В следующий stateless prompt: \(inspection.includedMessages) сообщений; скрыто checkpoint/лимитом: \(inspection.omittedMessages)",
                "Оценка prompt-контекста: ~\(inspection.estimatedTokens.formatted()) токенов (\(inspection.estimatedCharacters.formatted()) символов)"
            ]
        } else {
            let semanticCharacters = (
                task.handoff.decisions
                    + task.handoff.progress
                    + task.handoff.knownIssues
            ).reduce(task.handoff.nextStep.count) { $0 + $1.count }
            contextLines = [
                "Режим: \(scope.title)",
                "История в приложении: \(history.count) сообщений",
                "В workspace prompt передаётся semantic handoff и актуальный Git-контекст, а не полный transcript",
                "Semantic handoff: ~\(max(1, semanticCharacters / 4).formatted()) токенов"
            ]
        }

        let sessionLine: String
        switch target {
        case let .cli(agent) where agent.supportsNativeSessionResume:
            let workingDirectory = workingDirectory(
                for: task,
                interactionMode: interactionMode
            )
            if let binding = Self.sessionBinding(
                in: task,
                agent: agent,
                scope: scope,
                workingDirectory: workingDirectory
            ) {
                sessionLine = "Native resume: \(agent.shortName) · \(binding.sessionID)"
            } else {
                sessionLine = "Native resume: \(agent.shortName), сессия будет создана при следующем сообщении"
            }
        case let .cli(agent):
            sessionLine = "Native resume: \(agent.shortName) headless не поддерживается; используется checkpoint"
        case let .api(apiTarget):
            sessionLine = "Исполнитель: \(apiTarget.displayName) API; используется checkpoint"
        }

        let checkpointLine = checkpoint.map {
            "Checkpoint: \($0.sourceMessageCount) сообщений до \($0.createdAt.formatted(date: .abbreviated, time: .shortened)); источник: \($0.modelID ?? "локальный")"
        } ?? "Checkpoint: ещё не создан"
        return (contextLines + [
            checkpointLine,
            sessionLine,
            "Постоянное хранилище: \(persistence.taskStatePath)"
        ]).joined(separator: "\n")
    }

    private func commandInteractionMode(for task: CodingTask) -> AgentInteractionMode {
        guard task.effectiveInteractionMode == .automatic else {
            return task.effectiveInteractionMode
        }
        guard let latestUserMessage = task.chatMessages.last(where: { $0.role == .user })?.text else {
            return AgentInteractionMode.inferred(
                from: task.effectivePersona.prompt
            )
        }
        return task.effectiveInteractionMode.resolved(
            for: latestUserMessage,
            personalityPrompt: task.effectivePersona.prompt,
            recentMessages: task.chatMessages
                .filter { $0.role != .system }
                .suffix(6)
                .map(\.text)
        )
    }

    private func workingDirectory(
        for task: CodingTask,
        interactionMode: AgentInteractionMode
    ) -> String {
        interactionMode == .workspace
            ? task.repositoryPath
            : conversationWorkingDirectory(for: task.id)
    }

    private func appendCommandMessage(_ text: String, to taskID: UUID) {
        mutateTask(taskID) { task in
            var messages = task.messages ?? []
            messages.append(TaskMessage(role: .system, text: text))
            task.messages = messages
        }
    }

    private func clearSessionBindings(
        taskID: UUID,
        agent: AgentKind,
        scope: AgentSessionScope
    ) {
        mutateTask(taskID) { task in
            task.nativeSessionBindings?.removeAll {
                $0.agent == agent && $0.scope == scope
            }
            if task.nativeSessionBindings?.isEmpty == true {
                task.nativeSessionBindings = nil
            }
        }
    }

    private static func sessionBinding(
        in task: CodingTask,
        agent: AgentKind,
        scope: AgentSessionScope,
        workingDirectory: String
    ) -> AgentSessionBinding? {
        let normalizedDirectory = normalizedSessionDirectory(workingDirectory)
        return task.nativeSessionBindings?.first {
            $0.agent == agent
                && $0.scope == scope
                && normalizedSessionDirectory($0.workingDirectory) == normalizedDirectory
        }
    }

    private static func storeSessionBinding(
        sessionID: String,
        agent: AgentKind,
        interactionMode: AgentInteractionMode,
        workingDirectory: String,
        modelID: String?,
        in task: inout CodingTask
    ) {
        let normalizedID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }
        let scope = AgentSessionScope(interactionMode: interactionMode)
        var bindings = task.nativeSessionBindings ?? []
        if let index = bindings.firstIndex(where: {
            $0.agent == agent && $0.scope == scope
        }) {
            let createdAt = bindings[index].createdAt
            bindings[index] = AgentSessionBinding(
                agent: agent,
                scope: scope,
                sessionID: normalizedID,
                workingDirectory: normalizedSessionDirectory(workingDirectory),
                modelID: modelID,
                createdAt: createdAt,
                updatedAt: .now
            )
        } else {
            bindings.append(
                AgentSessionBinding(
                    agent: agent,
                    scope: scope,
                    sessionID: normalizedID,
                    workingDirectory: normalizedSessionDirectory(workingDirectory),
                    modelID: modelID
                )
            )
        }
        task.nativeSessionBindings = bindings
    }

    private static func normalizedSessionDirectory(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func mutateTask(_ id: UUID, mutation: (inout CodingTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutation(&tasks[index])
        tasks[index].updatedAt = .now
        persist()
    }

    private func mutateGroupChat(
        _ id: UUID,
        mutation: (inout AgentGroupChat) -> Void
    ) {
        guard let index = groupChats.firstIndex(where: { $0.id == id }) else { return }
        mutation(&groupChats[index])
        groupChats[index].updatedAt = .now
        persist()
    }

    private func persist() {
        guard persistenceAllowsWrites else {
            lastError = "Сохранение заблокировано: сначала восстановите или переместите повреждённый state.json."
            return
        }
        do {
            try persistence.saveTasks(tasks)
            try persistence.saveGroupChats(groupChats)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func resolvedConfiguration(for task: CodingTask) -> [String: String] {
        Dictionary(uniqueKeysWithValues: parameterDefinitions(for: task).map { parameter in
            (parameter.id.rawValue, effectiveValue(for: parameter, in: task))
        })
    }

    private func execute(
        target: AgentExecutionTarget,
        attemptID: UUID,
        taskID: UUID,
        task: CodingTask,
        repositoryPath: String,
        prompt: String,
        attachments: [TaskAttachment],
        isGitRepository: Bool,
        interactionMode: AgentInteractionMode
    ) async throws -> AgentExecutionResponse {
        switch target {
        case let .cli(agent):
            guard let executablePath = agentInstallations
                .first(where: { $0.kind == agent })?
                .executablePath
            else {
                throw AgentExecutionError.executableUnavailable(agent)
            }

            var configuration = resolvedConfiguration(for: task)
            if interactionMode == .conversation {
                configuration = conversationConfiguration(configuration, for: agent)
            }
            let request = AgentExecutionRequest(
                attemptID: attemptID,
                taskID: taskID,
                agent: agent,
                executablePath: executablePath,
                repositoryPath: repositoryPath,
                prompt: prompt,
                configuration: configuration,
                attachments: attachments,
                isGitRepository: isGitRepository,
                nativeSession: nativeSessionDirective(
                    agent: agent,
                    task: task,
                    interactionMode: interactionMode,
                    workingDirectory: repositoryPath
                )
            )
            let response = try await taskOrchestrator.execute(request) { [weak self] output in
                await self?.recordLiveAgentOutput(
                    output,
                    taskID: taskID,
                    attemptID: attemptID
                )
            }
            return response

        case let .api(apiTarget):
            let responseTask = Swift.Task { [apiExecutor] in
                try await apiExecutor.execute(
                    AIAPIExecutionRequest(
                        target: apiTarget,
                        prompt: prompt,
                        maximumOutputTokens: interactionMode == .workspace ? 4_096 : 2_048
                    )
                )
            }
            activeAPIExecutionTasks[taskID] = responseTask
            do {
                let response = try await responseTask.value
                activeAPIExecutionTasks[taskID] = nil
                return AgentExecutionResponse(
                    text: response.text,
                    exitCode: 0,
                    nativeSessionID: nil
                )
            } catch {
                activeAPIExecutionTasks[taskID] = nil
                throw error
            }
        }
    }

    private func nativeSessionDirective(
        agent: AgentKind,
        task: CodingTask,
        interactionMode: AgentInteractionMode,
        workingDirectory: String
    ) -> AgentNativeSessionDirective {
        guard agent.supportsNativeSessionResume else { return .disabled }
        let scope = AgentSessionScope(interactionMode: interactionMode)
        if let binding = Self.sessionBinding(
            in: task,
            agent: agent,
            scope: scope,
            workingDirectory: workingDirectory
        ) {
            return .resume(id: binding.sessionID)
        }

        if agent == .claudeCode {
            return .start(preferredID: UUID().uuidString.lowercased())
        }
        return .start()
    }

    private func resumesNativeSession(
        target: AgentExecutionTarget,
        task: CodingTask,
        interactionMode: AgentInteractionMode,
        workingDirectory: String
    ) -> Bool {
        guard case let .cli(agent) = target,
              agent.supportsNativeSessionResume
        else {
            return false
        }
        return Self.sessionBinding(
            in: task,
            agent: agent,
            scope: AgentSessionScope(interactionMode: interactionMode),
            workingDirectory: workingDirectory
        ) != nil
    }

    private func resolvedGroupConfiguration(
        for participant: CodingTask,
        agent: AgentKind
    ) -> [String: String] {
        let capabilitySet = capabilities(for: agent)
        let usesStoredValues = participant.currentAgent == agent
        let selectedModelID = usesStoredValues
            ? participant.agentConfiguration?[.model]
            : nil
        let definitions = capabilitySet.parameters(selectedModelID: selectedModelID)
        let base = Dictionary(uniqueKeysWithValues: definitions.map { parameter in
            let storedValue = usesStoredValues
                ? participant.agentConfiguration?[parameter.id]
                : nil
            let value = storedValue.flatMap { candidate in
                parameter.options.contains(where: { $0.id == candidate })
                    ? candidate
                    : nil
            } ?? parameter.defaultValue
            return (parameter.id.rawValue, value)
        })
        return conversationConfiguration(base, for: agent)
    }

    private func appendExecutionError(_ error: Error, to taskID: UUID) {
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        let wasCancelled: Bool
        if let executionError = error as? AgentExecutionError,
           case .cancelled = executionError {
            wasCancelled = true
        } else {
            wasCancelled = false
        }

        mutateTask(taskID) { task in
            var messages = task.messages ?? []
            messages.append(TaskMessage(role: .system, text: message))
            task.messages = messages
            task.status = wasCancelled ? .paused : .needsAttention
            task.activity.insert(
                ActivityEvent(
                    title: wasCancelled ? "Попытка остановлена" : "Ошибка запуска агента",
                    detail: message,
                    systemImage: wasCancelled ? "stop.circle" : "exclamationmark.triangle"
                ),
                at: 0
            )
        }
        if !wasCancelled {
            scheduleNotification(taskID: taskID, kind: .attention)
        }
    }

    private static func appendCheckpoint(to task: inout CodingTask, reason: String) {
        task.checkpoints.append(
            TaskCheckpoint(
                id: UUID(),
                sequence: task.checkpoints.count + 1,
                createdAt: .now,
                gitHead: task.gitSnapshot.head,
                changedFileCount: task.gitSnapshot.changedFiles.count,
                reason: reason
            )
        )
    }

    @discardableResult
    private static func applyProgressReport(
        _ report: AgentProgressReport,
        to task: inout CodingTask
    ) -> Bool {
        if !report.decisions.isEmpty {
            task.handoff.decisions = report.decisions
        }
        if !report.progress.isEmpty {
            task.handoff.progress = report.progress
        }
        task.handoff.knownIssues = report.knownIssues
        if !report.nextStep.isEmpty {
            task.handoff.nextStep = report.nextStep
        }
        task.handoff.updatedAt = .now

        let completedTitles = Set(report.completedSteps)
        if !completedTitles.isEmpty {
            for index in task.steps.indices where completedTitles.contains(task.steps[index].title) {
                task.steps[index].isCompleted = true
            }
        }
        return !task.steps.isEmpty && task.steps.allSatisfy(\.isCompleted)
    }

    private static func retainedAttachments(in task: CodingTask) -> [TaskAttachment] {
        var seenPaths: Set<String> = []
        var retained: [TaskAttachment] = []

        for attachment in task.chatMessages
            .flatMap({ $0.attachments ?? [] })
            .reversed() {
            let key = URL(fileURLWithPath: attachment.filePath)
                .standardizedFileURL
                .path
            guard seenPaths.insert(key).inserted else { continue }
            retained.append(attachment)
            if retained.count == 20 { break }
        }

        return Array(retained.reversed())
    }

    private static func specificationContent(
        _ specification: TaskSpecification
    ) -> [String] {
        [
            specification.objective,
            specification.requirementUpdates.joined(separator: "\u{1F}"),
            specification.constraints.joined(separator: "\u{1F}"),
            specification.acceptanceCriteria.joined(separator: "\u{1F}"),
            specification.productDecisions.joined(separator: "\u{1F}"),
            specification.outOfScope.joined(separator: "\u{1F}"),
            specification.openQuestions.joined(separator: "\u{1F}")
        ]
    }

    private static func updateValidationRun(
        in task: inout CodingTask,
        recipe: ValidationRecipe,
        update: (inout ValidationRun) -> Void
    ) {
        let index: Int
        if let existingIndex = task.validations.firstIndex(where: {
            $0.recipeID == recipe.id || $0.name == recipe.name
        }) {
            index = existingIndex
        } else {
            task.validations.append(
                ValidationRun(name: recipe.name, recipeID: recipe.id)
            )
            index = task.validations.index(before: task.validations.endIndex)
        }
        task.validations[index].recipeID = recipe.id
        update(&task.validations[index])
    }

    private static func validationSummary(
        exitCode: Int32,
        duration: TimeInterval,
        repositoryChanged: Bool
    ) -> String {
        let formattedDuration = duration.formatted(
            .number.precision(.fractionLength(1))
        )
        let base = "exit \(exitCode) · \(formattedDuration) с"
        return repositoryChanged
            ? "\(base) · репозиторий изменился, результат устарел"
            : base
    }

    private func isRepositoryBusy(
        _ repositoryPath: String,
        excludingValidationTaskID: UUID?
    ) -> Bool {
        let target = canonicalRepositoryPath(repositoryPath)
        let agentOwnsRepository = activeRuns.contains { entry in
            let (taskID, run) = entry
            guard run.interactionMode == .workspace else { return false }
            return tasks.first(where: { $0.id == taskID })
                .map { canonicalRepositoryPath($0.repositoryPath) }
                == target
        }
        let validationOwnsRepository = activeValidations.keys.contains { taskID in
            guard taskID != excludingValidationTaskID else { return false }
            return tasks.first(where: { $0.id == taskID })
                .map { canonicalRepositoryPath($0.repositoryPath) }
                == target
        }
        return agentOwnsRepository || validationOwnsRepository
    }

    private func canonicalRepositoryPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private func validationOrder(_ kind: ValidationRecipeKind) -> Int {
        switch kind {
        case .build: 0
        case .test: 1
        case .custom: 2
        }
    }

    private func scheduleNotification(
        taskID: UUID,
        kind: TaskNotificationKind
    ) {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return }
        let event = TaskNotificationEvent(
            taskID: task.id,
            taskTitle: task.title,
            kind: kind
        )
        Task {
            await notificationService.post(event)
        }
    }

    private static func configuration(
        for profile: AgentProfileDraft
    ) -> TaskAgentConfiguration {
        var configuration = profile.configuration
        configuration[.executionSource] = profile.executionSource.rawValue
        configuration[.apiProvider] = profile.apiProvider.rawValue
        let apiModelID = profile.apiModelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        configuration[.apiModel] = apiModelID.isEmpty ? nil : apiModelID
        return configuration
    }

    private static func applyAgentSelection(
        _ kind: AgentKind,
        previous: AgentKind?,
        requiresHandoff: Bool,
        interactionMode: AgentInteractionMode? = nil,
        to task: inout CodingTask
    ) {
        let isConversation = (interactionMode ?? task.effectiveInteractionMode) == .conversation
        task.currentAgent = kind
        task.agentConfiguration = nil

        if requiresHandoff, !isConversation {
            appendCheckpoint(to: &task, reason: "Передача другому агенту")
            task.handoff.nextStep = "Сначала провести аудит текущего diff, затем продолжить незавершённый этап."
            task.handoff.updatedAt = .now
        }

        task.activity.insert(
            ActivityEvent(
                title: previous == nil ? "Агент выбран" : "Агент переключён",
                detail: {
                    if requiresHandoff, isConversation {
                        return "\(previous?.shortName ?? "Нет агента") → \(kind.shortName). Диалог продолжится с сохранённой историей."
                    }
                    if requiresHandoff {
                        return "\(previous?.shortName ?? "Нет агента") → \(kind.shortName). Создан checkpoint и требуется аудит diff."
                    }
                    return isConversation
                        ? "Для диалога выбран \(kind.displayName)."
                        : "Для задачи выбран \(kind.displayName)."
                }(),
                systemImage: previous == nil ? "person.crop.circle.badge.checkmark" : "arrow.triangle.2.circlepath"
            ),
            at: 0
        )
    }
}
