import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
    var tasks: [CodingTask]
    var selection: UUID?
    var selectedFilter: TaskFilter = .all
    var agentInstallations: [AgentInstallation] = AgentKind.allCases.map {
        AgentInstallation(kind: $0, executablePath: nil)
    }
    var agentCapabilities = AgentCapabilityCatalog.fallback
    var activeRuns: [UUID: AgentRunState] = [:]
    var liveAgentOutputs: [UUID: AgentLiveOutput] = [:]
    var activeValidations: [UUID: ValidationExecutionState] = [:]
    var liveGitSnapshots: [UUID: GitSnapshot] = [:]
    var providerUsage: [AgentKind: ProviderUsageSnapshot] = Dictionary(
        uniqueKeysWithValues: AgentKind.allCases.map { ($0, .unknown(for: $0)) }
    )
    var isShowingInspector = true
    var isShowingSettings = false
    var isRefreshingGit = false
    var isRefreshingUsage = false
    var taskPendingDeletion: UUID?
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
    private let preferredAgentOrderProvider: () -> [AgentKind]
    private let usageAutoRefreshInterval: Duration
    private var persistenceAllowsWrites = true
    private var usageAutoRefreshTask: Task<Void, Never>?
    private var activeHandoffCompressionTasks: [
        UUID: Swift.Task<CompressedAgentHandoff?, Error>
    ] = [:]
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
        handoffCompressor: any AgentHandoffCompressing = DisabledAgentHandoffCompressor()
    ) {
        self.persistence = persistence
        self.notificationService = notificationService
        self.providerUsageService = providerUsageService
        self.handoffCompressor = handoffCompressor
        self.usageAutoRefreshInterval = usageAutoRefreshInterval
        preferredAgentOrderProvider = preferredAgentOrder
        let loadedState = persistence.loadTasks()
        tasks = loadedState.tasks
        persistenceAllowsWrites = loadedState.allowsWrites
        lastError = loadedState.warning
        selection = tasks.first?.id
        resumePendingOnboardingIntroductions()

        if performAgentDiscovery {
            Task {
                let installations = await agentDetector.detect()
                agentInstallations = installations
                agentCapabilities = await agentCapabilityDetector.detect(installations: installations)
                await refreshProviderUsage()
                if let selection {
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

    var automaticAgentOrder: [AgentKind] {
        preferredAgentOrderProvider()
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

        var task = CodingTask(
            title: name,
            originalRequest: "",
            repositoryPath: repositoryPath,
            currentAgent: profile.agentKind,
            routingMode: profile.routingMode,
            agentConfiguration: profile.configuration.isEmpty ? nil : profile.configuration,
            persona: AgentPersona(
                prompt: prompt,
                avatarEmoji: profile.avatarEmoji,
                avatarImageData: profile.avatarImageData,
                avatarColor: profile.avatarColor,
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
        mutateTask(taskID) { task in
            task.title = name
            task.repositoryPath = repositoryPath
            task.routingMode = profile.routingMode
            task.currentAgent = profile.agentKind
            task.agentConfiguration = profile.configuration.isEmpty ? nil : profile.configuration
            task.persona = AgentPersona(
                prompt: prompt,
                avatarEmoji: profile.avatarEmoji,
                avatarImageData: profile.avatarImageData,
                avatarColor: profile.avatarColor,
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

        guard !isRepositoryBusy(
            submittedTask.repositoryPath,
            excludingValidationTaskID: nil
        ) else {
            lastError = "Сначала дождитесь завершения агента или проверки в этом репозитории."
            return
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

            if task.originalRequest.isEmpty {
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
        let candidates = AutomaticAgentRouter.candidates(
            for: task,
            installations: agentInstallations,
            preferredOrder: automaticAgentOrder,
            usageSnapshots: providerUsage
        )

        guard let firstAgent = candidates.first else {
            appendExecutionError(
                AgentExecutionError.launchFailed(
                    task.effectiveRoutingMode == .automatic
                        ? "В Auto нет доступного агента с оставшимся лимитом. Проверьте CLI и порядок провайдеров в Settings."
                        : "Ни один официальный CLI не найден."
                ),
                to: taskID
            )
            return
        }

        var pendingAttemptID = UUID()
        activeRuns[taskID] = AgentRunState(
            attemptID: pendingAttemptID,
            agent: firstAgent,
            phase: .preparing,
            startedAt: .now
        )
        liveAgentOutputs[taskID] = .empty
        let monitor = Swift.Task { [weak self] in
            await self?.monitorRepository(taskID: taskID)
        }

        executionLoop: for (candidateIndex, agent) in candidates.enumerated() {
            let attemptID = pendingAttemptID
            if activeRuns[taskID]?.attemptID != attemptID {
                activeRuns[taskID] = AgentRunState(
                    attemptID: attemptID,
                    agent: agent,
                    phase: .preparing,
                    startedAt: .now
                )
            }

            guard let executablePath = agentInstallations
                .first(where: { $0.kind == agent })?
                .executablePath
            else {
                appendExecutionError(
                    AgentExecutionError.executableUnavailable(agent),
                    to: taskID
                )
                break executionLoop
            }

            var preflightSnapshot: GitSnapshot?
            if let currentTask = tasks.first(where: { $0.id == taskID }),
               currentTask.currentAgent != agent {
                let freshSnapshot = await gitService.snapshot(
                    at: URL(fileURLWithPath: currentTask.repositoryPath)
                )
                guard activeRuns[taskID]?.attemptID == attemptID else {
                    break executionLoop
                }
                liveGitSnapshots[taskID] = freshSnapshot
                selectExecutionAgent(agent, for: taskID, snapshot: freshSnapshot)
                preflightSnapshot = freshSnapshot
            }
            guard var taskSnapshot = tasks.first(where: { $0.id == taskID }) else {
                break executionLoop
            }
            if preflightSnapshot == nil {
                preflightSnapshot = await gitService.snapshot(
                    at: URL(fileURLWithPath: taskSnapshot.repositoryPath)
                )
                guard activeRuns[taskID]?.attemptID == attemptID else {
                    break executionLoop
                }
            }
            guard let preflightSnapshot else {
                break executionLoop
            }
            liveGitSnapshots[taskID] = preflightSnapshot
            taskSnapshot.gitSnapshot = preflightSnapshot
            let retainedAttachments = Self.retainedAttachments(in: taskSnapshot)

            let repositoryContext = await gitService.handoffContext(
                at: URL(fileURLWithPath: taskSnapshot.repositoryPath)
            )
            guard activeRuns[taskID]?.attemptID == attemptID else {
                break executionLoop
            }

            let prompt = TaskEnvelopeBuilder.build(
                task: taskSnapshot,
                currentInstruction: messageText,
                attachments: retainedAttachments,
                repositoryContext: repositoryContext
            )
            let configuration = resolvedConfiguration(for: taskSnapshot)
            if activeRuns[taskID]?.phase != .stopping {
                activeRuns[taskID]?.phase = .running
            }

            let request = AgentExecutionRequest(
                attemptID: attemptID,
                taskID: taskID,
                agent: agent,
                executablePath: executablePath,
                repositoryPath: taskSnapshot.repositoryPath,
                prompt: prompt,
                configuration: configuration,
                attachments: retainedAttachments,
                isGitRepository: repositoryContext.isGitRepository
            )

            do {
                let response = try await taskOrchestrator.execute(request) { [weak self] output in
                    await self?.recordLiveAgentOutput(
                        output,
                        taskID: taskID,
                        attemptID: attemptID
                    )
                }
                guard activeRuns[taskID]?.attemptID == attemptID else {
                    break executionLoop
                }
                if activeRuns[taskID]?.phase == .stopping {
                    await taskOrchestrator.discardPendingCancellation(attemptID: attemptID)
                    appendExecutionError(AgentExecutionError.cancelled, to: taskID)
                    break executionLoop
                }

                let parsedResponse = AgentProgressReportParser.parse(response.text)
                let completionSnapshot = await gitService.snapshot(
                    at: URL(fileURLWithPath: taskSnapshot.repositoryPath)
                )
                guard activeRuns[taskID]?.attemptID == attemptID else {
                    break executionLoop
                }
                liveGitSnapshots[taskID] = completionSnapshot
                mutateTask(taskID) { task in
                    task.gitSnapshot = completionSnapshot
                    var messages = task.messages ?? []
                    messages.append(
                        TaskMessage(role: .agent, text: parsedResponse.displayText)
                    )
                    task.messages = messages
                    task.status = .ready
                    if let progressReport = parsedResponse.progressReport {
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
                            title: "Попытка агента завершена",
                            detail: "\(agent.displayName) вернул финальный ответ.",
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
            } catch let executionError as AgentExecutionError {
                guard activeRuns[taskID]?.attemptID == attemptID else {
                    break executionLoop
                }

                if activeRuns[taskID]?.phase == .stopping {
                    await taskOrchestrator.discardPendingCancellation(attemptID: attemptID)
                    appendExecutionError(AgentExecutionError.cancelled, to: taskID)
                    break executionLoop
                }

                if case .usageLimitExceeded = executionError {
                    markProviderExhausted(agent)
                    let nextIndex = candidateIndex + 1
                    let canFailOver = taskSnapshot.effectiveRoutingMode == .automatic
                        && candidates.indices.contains(nextIndex)

                    if canFailOver {
                        let nextAgent = candidates[nextIndex]
                        let nextAttemptID = UUID()
                        pendingAttemptID = nextAttemptID
                        activeRuns[taskID] = AgentRunState(
                            attemptID: nextAttemptID,
                            agent: nextAgent,
                            phase: .compressingContext,
                            startedAt: .now
                        )
                        let interruptedOutput = liveAgentOutputs[taskID]?.text

                        let freshSnapshot = await gitService.snapshot(
                            at: URL(fileURLWithPath: taskSnapshot.repositoryPath)
                        )
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
                        liveGitSnapshots[taskID] = freshSnapshot

                        let handoffTask = tasks.first(where: { $0.id == taskID })
                            ?? taskSnapshot
                        let compressionRequest = OpenRouterHandoffPromptBuilder.build(
                            task: handoffTask,
                            from: agent,
                            to: nextAgent,
                            gitSnapshot: freshSnapshot,
                            lastAgentOutput: interruptedOutput
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
                            from: agent,
                            to: nextAgent,
                            snapshot: freshSnapshot,
                            compressedHandoff: compressedHandoff,
                            compressionFailure: compressionFailure
                        )
                        continue executionLoop
                    }
                }

                appendExecutionError(executionError, to: taskID)
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
                appendExecutionError(error, to: taskID)
                break executionLoop
            }
        }

        monitor.cancel()
        activeRuns[taskID] = nil
        liveAgentOutputs[taskID] = nil
        liveGitSnapshots[taskID] = nil
        await refreshGit(taskID: taskID)
        await refreshProviderUsage()
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
        activeHandoffCompressionTasks[taskID]?.cancel()
        await taskOrchestrator.cancel(taskID: taskID, attemptID: run.attemptID)
    }

    func deleteSelectedTask() {
        guard let selection else { return }
        requestTaskDeletion(selection)
    }

    func requestTaskDeletion(_ taskID: UUID) {
        guard tasks.contains(where: { $0.id == taskID }) else { return }
        guard activeRuns[taskID] == nil,
              activeValidations[taskID] == nil
        else {
            lastError = "Сначала остановите работающего агента или проверку."
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

        tasks.removeAll { $0.id == taskID }
        liveGitSnapshots[taskID] = nil
        if selection == taskID {
            selection = agents.first?.id
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
            guard task.currentAgent != kind else { return }
            let previous = task.currentAgent
            let requiresHandoff = previous != nil && task.status == .running
            Self.applyAgentSelection(
                kind,
                previous: previous,
                requiresHandoff: requiresHandoff,
                to: &task
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
        snapshot: GitSnapshot
    ) {
        mutateTask(taskID) { task in
            guard task.currentAgent != agent else { return }
            task.gitSnapshot = snapshot
            let previous = task.currentAgent
            Self.applyAgentSelection(
                agent,
                previous: previous,
                requiresHandoff: previous != nil,
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
        from previousAgent: AgentKind,
        to nextAgent: AgentKind,
        snapshot: GitSnapshot,
        compressedHandoff: CompressedAgentHandoff?,
        compressionFailure: String?
    ) {
        mutateTask(taskID) { task in
            task.gitSnapshot = snapshot
            let issue = "\(previousAgent.shortName): лимит исчерпан."

            Self.applyAgentSelection(
                nextAgent,
                previous: previousAgent,
                requiresHandoff: true,
                to: &task
            )

            if let compressedHandoff {
                if !compressedHandoff.decisions.isEmpty {
                    task.handoff.decisions = compressedHandoff.decisions
                }
                if !compressedHandoff.progress.isEmpty {
                    task.handoff.progress = compressedHandoff.progress
                }
                task.handoff.knownIssues = compressedHandoff.knownIssues
                task.handoff.nextStep = compressedHandoff.nextStep
            }
            task.handoff.knownIssues.removeAll { $0 == issue }
            task.handoff.knownIssues = Array(
                (task.handoff.knownIssues + [issue]).suffix(4)
            )
            task.handoff.updatedAt = .now

            var messages = task.messages ?? []
            let handoffDescription: String
            if let compressedHandoff {
                handoffDescription = "OpenRouter (\(compressedHandoff.modelID)) сжал контекст; Авто передал задачу \(nextAgent.shortName)."
            } else if compressionFailure != nil {
                handoffDescription = "OpenRouter недоступен, поэтому локальный handoff передал задачу \(nextAgent.shortName)."
            } else {
                handoffDescription = "Авто передал задачу \(nextAgent.shortName); новый агент сначала проверит текущий Git diff."
            }
            messages.append(
                TaskMessage(
                    role: .system,
                    text: "Лимит \(previousAgent.shortName) исчерпан. \(handoffDescription)"
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
                            return "\(previousAgent.shortName) → \(nextAgent.shortName). Контекст сжал \(compressedHandoff.modelID)."
                        }
                        if let compressionFailure {
                            return "\(previousAgent.shortName) → \(nextAgent.shortName). Локальный handoff: \(compressionFailure)"
                        }
                        return "\(previousAgent.shortName) → \(nextAgent.shortName) после подтверждённой ошибки лимита."
                    }(),
                    systemImage: "arrow.triangle.2.circlepath"
                ),
                at: 0
            )
        }
    }

    private func mutateTask(_ id: UUID, mutation: (inout CodingTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutation(&tasks[index])
        tasks[index].updatedAt = .now
        persist()
    }

    private func persist() {
        guard persistenceAllowsWrites else {
            lastError = "Сохранение заблокировано: сначала восстановите или переместите повреждённый state.json."
            return
        }
        do {
            try persistence.saveTasks(tasks)
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
        let agentOwnsRepository = activeRuns.keys.contains { taskID in
            tasks.first(where: { $0.id == taskID })
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

    private static func applyAgentSelection(
        _ kind: AgentKind,
        previous: AgentKind?,
        requiresHandoff: Bool,
        to task: inout CodingTask
    ) {
        task.currentAgent = kind
        task.agentConfiguration = nil

        if requiresHandoff {
            appendCheckpoint(to: &task, reason: "Передача другому агенту")
            task.handoff.nextStep = "Сначала провести аудит текущего diff, затем продолжить незавершённый этап."
            task.handoff.updatedAt = .now
        }

        task.activity.insert(
            ActivityEvent(
                title: previous == nil ? "Агент выбран" : "Агент переключён",
                detail: requiresHandoff
                    ? "\(previous?.shortName ?? "Нет агента") → \(kind.shortName). Создан checkpoint и требуется аудит diff."
                    : "Для задачи выбран \(kind.displayName).",
                systemImage: previous == nil ? "person.crop.circle.badge.checkmark" : "arrow.triangle.2.circlepath"
            ),
            at: 0
        )
    }
}
