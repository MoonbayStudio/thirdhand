import Foundation

enum TaskStatus: String, Codable, CaseIterable, Identifiable {
    case ready
    case running
    case paused
    case needsAttention
    case completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ready: AppLocalization.string("Готова")
        case .running: AppLocalization.string("В работе")
        case .paused: AppLocalization.string("На паузе")
        case .needsAttention: AppLocalization.string("Нужно внимание")
        case .completed: AppLocalization.string("Завершена")
        }
    }

    var systemImage: String {
        switch self {
        case .ready: "circle.dotted"
        case .running: "play.circle.fill"
        case .paused: "pause.circle.fill"
        case .needsAttention: "exclamationmark.circle.fill"
        case .completed: "checkmark.circle.fill"
        }
    }
}

enum TaskFilter: String, CaseIterable, Identifiable {
    case all
    case running
    case needsAttention
    case completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: AppLocalization.string("Все задачи")
        case .running: AppLocalization.string("В работе")
        case .needsAttention: AppLocalization.string("Нужно внимание")
        case .completed: AppLocalization.string("Завершённые")
        }
    }

    var systemImage: String {
        switch self {
        case .all: "tray.full"
        case .running: "bolt.fill"
        case .needsAttention: "bell.badge"
        case .completed: "checkmark.seal"
        }
    }
}

enum SidebarDestination: Hashable {
    case filter(TaskFilter)
    case task(UUID)
}

enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claudeCode
    case antigravity
    case deepSeek

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex CLI"
        case .claudeCode: "Claude Code"
        case .antigravity: "Antigravity"
        case .deepSeek: "DeepSeek Harness"
        }
    }

    var commandNames: [String] {
        switch self {
        case .codex: ["codex"]
        case .claudeCode: ["claude"]
        case .antigravity: ["agy", "antigravity"]
        case .deepSeek: ["/opt/homebrew/bin/dsh", "dsh"]
        }
    }

    var shortName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude"
        case .antigravity: "Antigravity"
        case .deepSeek: "DeepSeek"
        }
    }

    var supportsNativeSessionResume: Bool {
        switch self {
        case .codex, .claudeCode: true
        case .antigravity, .deepSeek: false
        }
    }
}

enum AgentRoutingMode: String, Codable, Hashable, Sendable {
    case manual
    case automatic

    var title: String {
        switch self {
        case .manual: AppLocalization.string("Вручную")
        case .automatic: AppLocalization.string("Авто")
        }
    }
}

enum AgentInteractionMode: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case automatic
    case conversation
    case workspace

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: AppLocalization.string("Авто")
        case .conversation: AppLocalization.string("Общение")
        case .workspace: AppLocalization.string("Проект")
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            AppLocalization.string("Простые реплики остаются диалогом, а работа с кодом и проектом получает Git-контекст.")
        case .conversation:
            AppLocalization.string("Обычный диалог с памятью чата. Git и файлы проекта не используются.")
        case .workspace:
            AppLocalization.string("Агент получает задачу, рабочую папку, Git-контекст и протокол проверок.")
        }
    }

    static func inferred(from personalityPrompt: String) -> Self {
        let normalized = personalityPrompt.lowercased()
        let workspacePersonaMarkers = [
            "разработчик", "программист", "инженер по", "тестировщик",
            "devops", "developer", "programmer", "software engineer",
            "работай с кодом", "работай с репозитори", "coding agent"
        ]
        return workspacePersonaMarkers.contains(where: normalized.contains)
            ? .workspace
            : .conversation
    }

    func resolved(
        for message: String,
        personalityPrompt: String,
        recentMessages: [String] = []
    ) -> Self {
        guard self == .automatic else { return self }

        let normalized = " " + message.lowercased() + " "
        let workspaceIntentMarkers = [
            "репозитор", " github", " git ", "код", "исходник",
            "файл проекта", "рабочая папка", "компил", "сборк", "тест",
            "баг", "рефактор", "коммит", "pull request", "пулл-реквест",
            "xcode", "swiftui", " swift ", "typescript", "javascript",
            " python ", "frontend", "backend", " api ", " апи "
        ]
        if workspaceIntentMarkers.contains(where: normalized.contains) {
            return .workspace
        }

        let casualMarkers = [
            "привет", "здравств", "хей", "как дела", "как ты", "что нового",
            "что делаешь", "как настроение", "доброе утро", "добрый день",
            "добрый вечер", "поговорим", "давай поговор", "расскажи о себе",
            "расскажи шут", "мне грустно", "спасибо", "благодар", "hello",
            " hi ", " hey ", "how are you", "thank you"
        ]
        if casualMarkers.contains(where: normalized.contains) {
            return .conversation
        }

        let workspaceActionMarkers = [
            "сделай", "исправ", "почин", "поправ", "измени", "добав",
            "удали", "убери", "выровн", "увелич", "уменьш", "реализ",
            "запусти", "проверь", "продолж", "перепиш", "напиши функ",
            "implement", "continue", "inspect", "review", "refactor",
            "fix ", "change ", "update ", "create ", "add ", "remove ",
            "run "
        ]
        let recentContext = recentMessages
            .suffix(6)
            .joined(separator: " ")
            .lowercased()
        let hasRecentWorkspaceContext = workspaceIntentMarkers.contains {
            recentContext.contains($0.trimmingCharacters(in: .whitespaces))
        }
        if workspaceActionMarkers.contains(where: normalized.contains),
           Self.inferred(from: personalityPrompt) == .workspace
            || hasRecentWorkspaceContext {
            return .workspace
        }

        return .conversation
    }
}

struct AgentOptionID: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let model = Self(rawValue: "model")
    static let reasoningEffort = Self(rawValue: "reasoningEffort")
    static let speedTier = Self(rawValue: "speedTier")
    static let approvalPolicy = Self(rawValue: "approvalPolicy")
    static let permissionMode = Self(rawValue: "permissionMode")
    static let executionMode = Self(rawValue: "executionMode")
    static let sandboxMode = Self(rawValue: "sandboxMode")
    static let executionSource = Self(rawValue: "executionSource")
    static let apiProvider = Self(rawValue: "apiProvider")
    static let apiModel = Self(rawValue: "apiModel")
}

struct TaskAgentConfiguration: Codable, Hashable, Sendable {
    var values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    subscript(option: AgentOptionID) -> String? {
        get { values[option.rawValue] }
        set { values[option.rawValue] = newValue }
    }

    var isEmpty: Bool {
        values.isEmpty
    }
}

enum AgentAvatarColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case indigo
    case blue
    case teal
    case green
    case orange
    case pink

    var id: String { rawValue }
}

enum AgentOnboardingStage: String, Codable, Hashable, Sendable {
    case introducing
    case awaitingIdentity
    case configuring
}

struct AgentPersona: Codable, Hashable, Sendable {
    var prompt: String
    var avatarEmoji: String
    var avatarImageData: Data?
    var avatarColor: AgentAvatarColor
    var interactionMode: AgentInteractionMode?
    var needsReview: Bool
    var onboardingStage: AgentOnboardingStage?

    init(
        prompt: String,
        avatarEmoji: String = "🤖",
        avatarImageData: Data? = nil,
        avatarColor: AgentAvatarColor = .indigo,
        interactionMode: AgentInteractionMode? = nil,
        needsReview: Bool = false,
        onboardingStage: AgentOnboardingStage? = nil
    ) {
        self.prompt = prompt
        self.avatarEmoji = avatarEmoji
        self.avatarImageData = avatarImageData
        self.avatarColor = avatarColor
        self.interactionMode = interactionMode
        self.needsReview = needsReview
        self.onboardingStage = onboardingStage
    }
}

struct AgentProfileDraft: Hashable, Sendable {
    var name: String
    var personalityPrompt: String
    var avatarEmoji: String
    var avatarImageData: Data?
    var avatarColor: AgentAvatarColor
    var interactionMode: AgentInteractionMode
    var routingMode: AgentRoutingMode
    var agentKind: AgentKind
    var executionSource: AgentExecutionSource
    var apiProvider: AIAPIProvider
    var apiModelID: String
    var configuration: TaskAgentConfiguration
    var repositoryPath: String
    var needsReview: Bool

    init(
        name: String,
        personalityPrompt: String,
        avatarEmoji: String = "🤖",
        avatarImageData: Data? = nil,
        avatarColor: AgentAvatarColor = .indigo,
        interactionMode: AgentInteractionMode = .automatic,
        routingMode: AgentRoutingMode = .automatic,
        agentKind: AgentKind = .codex,
        executionSource: AgentExecutionSource = .cli,
        apiProvider: AIAPIProvider = .openRouter,
        apiModelID: String = "",
        configuration: TaskAgentConfiguration = TaskAgentConfiguration(),
        repositoryPath: String,
        needsReview: Bool = false
    ) {
        self.name = name
        self.personalityPrompt = personalityPrompt
        self.avatarEmoji = avatarEmoji
        self.avatarImageData = avatarImageData
        self.avatarColor = avatarColor
        self.interactionMode = interactionMode
        self.routingMode = routingMode
        self.agentKind = agentKind
        self.executionSource = executionSource
        self.apiProvider = apiProvider
        self.apiModelID = apiModelID
        self.configuration = configuration
        self.repositoryPath = repositoryPath
        self.needsReview = needsReview
    }

    init(task: CodingTask, fallbackAgent: AgentKind = .codex) {
        let persona = task.effectivePersona
        self.init(
            name: task.title,
            personalityPrompt: persona.prompt,
            avatarEmoji: persona.avatarEmoji,
            avatarImageData: persona.avatarImageData,
            avatarColor: persona.avatarColor,
            interactionMode: task.effectiveInteractionMode,
            routingMode: task.effectiveRoutingMode,
            agentKind: task.currentAgent ?? fallbackAgent,
            executionSource: task.configuredExecutionSource,
            apiProvider: task.configuredAPIProvider ?? AIAPIPreferences.preferredProvider(),
            apiModelID: task.configuredAPIModelID
                ?? task.configuredAPIProvider.map { AIAPIPreferences.primaryModelID(for: $0) }
                ?? "",
            configuration: task.agentConfiguration ?? TaskAgentConfiguration(),
            repositoryPath: task.repositoryPath,
            needsReview: persona.needsReview
        )
    }
}

struct AgentInstallation: Identifiable, Codable, Hashable, Sendable {
    var id: AgentKind { kind }
    let kind: AgentKind
    var executablePath: String?
    var isAvailable: Bool { executablePath != nil }
}

struct TaskStep: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var isCompleted: Bool

    init(id: UUID = UUID(), title: String, isCompleted: Bool = false) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
    }
}

struct ChangedFile: Identifiable, Codable, Hashable {
    var id: String { status + path }
    let status: String
    let path: String
    var additions: Int?
    var deletions: Int?

    init(
        status: String,
        path: String,
        additions: Int? = nil,
        deletions: Int? = nil
    ) {
        self.status = status
        self.path = path
        self.additions = additions
        self.deletions = deletions
    }
}

struct GitSnapshot: Codable, Hashable {
    var branch: String
    var head: String
    var changedFiles: [ChangedFile]
    var diffStat: String
    var capturedAt: Date
    var isGitRepository: Bool
    var errorMessage: String?
    var additions: Int?
    var deletions: Int?
    var fingerprint: String? = nil

    var lineAdditions: Int { additions ?? 0 }
    var lineDeletions: Int { deletions ?? 0 }

    static let unavailable = GitSnapshot(
        branch: "—",
        head: "—",
        changedFiles: [],
        diffStat: "Git snapshot ещё не получен",
        capturedAt: .now,
        isGitRepository: false,
        additions: nil,
        deletions: nil,
        fingerprint: nil
    )
}

enum GitFileDiffKind: String, Hashable, Sendable {
    case text
    case binary
    case tooLarge
    case unavailable
}

struct GitFileDiff: Hashable, Sendable {
    let path: String
    let content: String
    let kind: GitFileDiffKind
    let wasTruncated: Bool
}

struct TaskSpecification: Codable, Hashable {
    var objective: String
    var requirementUpdates: [String]
    var constraints: [String]
    var acceptanceCriteria: [String]
    var productDecisions: [String]
    var outOfScope: [String]
    var openQuestions: [String]
    var revision: Int
    var updatedAt: Date

    init(
        objective: String,
        requirementUpdates: [String] = [],
        constraints: [String] = [],
        acceptanceCriteria: [String] = [],
        productDecisions: [String] = [],
        outOfScope: [String] = [],
        openQuestions: [String] = [],
        revision: Int = 1,
        updatedAt: Date = .now
    ) {
        self.objective = Self.normalized(objective, maximumCharacters: 8_000)
        self.requirementUpdates = Self.normalizedList(requirementUpdates, maximumCount: 12)
        self.constraints = Self.normalizedList(constraints, maximumCount: 12)
        self.acceptanceCriteria = Self.normalizedList(acceptanceCriteria, maximumCount: 12)
        self.productDecisions = Self.normalizedList(productDecisions, maximumCount: 12)
        self.outOfScope = Self.normalizedList(outOfScope, maximumCount: 12)
        self.openQuestions = Self.normalizedList(openQuestions, maximumCount: 12)
        self.revision = max(revision, 1)
        self.updatedAt = updatedAt
    }

    mutating func recordRequirementUpdate(_ value: String) {
        let normalizedValue = Self.normalized(value, maximumCharacters: 4_000)
        guard !normalizedValue.isEmpty,
              normalizedValue != objective,
              requirementUpdates.last != normalizedValue
        else {
            return
        }

        requirementUpdates.append(normalizedValue)
        requirementUpdates = Array(requirementUpdates.suffix(12))
        revision += 1
        updatedAt = .now
    }

    var isEmpty: Bool {
        objective.isEmpty
            && requirementUpdates.isEmpty
            && constraints.isEmpty
            && acceptanceCriteria.isEmpty
            && productDecisions.isEmpty
            && outOfScope.isEmpty
            && openQuestions.isEmpty
    }

    private static func normalizedList(
        _ values: [String],
        maximumCount: Int
    ) -> [String] {
        Array(
            values
                .map { normalized($0, maximumCharacters: 1_000) }
                .filter { !$0.isEmpty }
                .suffix(maximumCount)
        )
    }

    private static func normalized(_ value: String, maximumCharacters: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumCharacters else { return trimmed }
        return String(trimmed.prefix(maximumCharacters))
    }
}

struct SemanticHandoff: Codable, Hashable {
    var decisions: [String]
    var progress: [String]
    var knownIssues: [String]
    var nextStep: String
    var updatedAt: Date

    static let initial = SemanticHandoff(
        decisions: ["Задача управляется через Git-состояние, а не историю диалога."],
        progress: ["Задача создана и готова к аудиту репозитория."],
        knownIssues: [],
        nextStep: "Изучить репозиторий и уточнить первый исполнимый этап.",
        updatedAt: .now
    )
}

struct ConversationHandoff: Codable, Hashable {
    var facts: [String]
    var recentContext: [String]
    var openThreads: [String]
    var nextReply: String
    var updatedAt: Date
}

enum AgentSessionScope: String, Codable, Hashable, Sendable {
    case conversation
    case workspace

    init(interactionMode: AgentInteractionMode) {
        self = interactionMode == .workspace ? .workspace : .conversation
    }

    var title: String {
        switch self {
        case .conversation: AppLocalization.string("Общение")
        case .workspace: AppLocalization.string("Проект")
        }
    }
}

struct AgentSessionBinding: Codable, Hashable, Sendable {
    let agent: AgentKind
    let scope: AgentSessionScope
    var sessionID: String
    var workingDirectory: String
    var modelID: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        agent: AgentKind,
        scope: AgentSessionScope,
        sessionID: String,
        workingDirectory: String,
        modelID: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.agent = agent
        self.scope = scope
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.modelID = modelID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct PortableContextCheckpoint: Codable, Hashable, Sendable {
    let id: UUID
    let scope: AgentSessionScope
    var decisions: [String]
    var progress: [String]
    var knownIssues: [String]
    var nextStep: String
    var coveredThroughMessageID: UUID?
    var sourceMessageCount: Int
    var estimatedOriginalTokens: Int
    var modelID: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        scope: AgentSessionScope,
        decisions: [String],
        progress: [String],
        knownIssues: [String],
        nextStep: String,
        coveredThroughMessageID: UUID?,
        sourceMessageCount: Int,
        estimatedOriginalTokens: Int,
        modelID: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.scope = scope
        self.decisions = decisions
        self.progress = progress
        self.knownIssues = knownIssues
        self.nextStep = nextStep
        self.coveredThroughMessageID = coveredThroughMessageID
        self.sourceMessageCount = sourceMessageCount
        self.estimatedOriginalTokens = estimatedOriginalTokens
        self.modelID = modelID
        self.createdAt = createdAt
    }
}

enum ValidationOutcome: String, Codable {
    case passed
    case failed
    case running
    case cancelled
    case notRun

    var title: String {
        switch self {
        case .passed: AppLocalization.string("Успешно")
        case .failed: AppLocalization.string("Ошибка")
        case .running: AppLocalization.string("Выполняется")
        case .cancelled: AppLocalization.string("Остановлено")
        case .notRun: AppLocalization.string("Не запускалось")
        }
    }
}

enum ValidationRecipeKind: String, Codable, Hashable, Sendable {
    case build
    case test
    case custom
}

struct ValidationRecipe: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var kind: ValidationRecipeKind
    var name: String
    var executablePath: String
    var arguments: [String]
    var timeoutSeconds: Int

    init(
        id: UUID = UUID(),
        kind: ValidationRecipeKind,
        name: String,
        executablePath: String,
        arguments: [String],
        timeoutSeconds: Int = 900
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
    }

    var commandDescription: String {
        ([executablePath] + arguments)
            .map(Self.shellQuoted)
            .joined(separator: " ")
    }

    private static func shellQuoted(_ value: String) -> String {
        guard value.contains(where: \.isWhitespace) else { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

struct ValidationRun: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var outcome: ValidationOutcome
    var summary: String
    var startedAt: Date?
    var finishedAt: Date?
    var recipeID: UUID?
    var gitFingerprint: String?
    var output: String?
    var duration: TimeInterval?
    var exitCode: Int32?

    init(
        id: UUID = UUID(),
        name: String,
        outcome: ValidationOutcome = .notRun,
        summary: String = "Проверка ещё не запускалась",
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        recipeID: UUID? = nil,
        gitFingerprint: String? = nil,
        output: String? = nil,
        duration: TimeInterval? = nil,
        exitCode: Int32? = nil
    ) {
        self.id = id
        self.name = name
        self.outcome = outcome
        self.summary = summary
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.recipeID = recipeID
        self.gitFingerprint = gitFingerprint
        self.output = output
        self.duration = duration
        self.exitCode = exitCode
    }

    func isFresh(for snapshot: GitSnapshot) -> Bool {
        guard outcome == .passed || outcome == .failed,
              let gitFingerprint,
              let currentFingerprint = snapshot.fingerprint
        else {
            return false
        }
        return gitFingerprint == currentFingerprint
    }
}

struct TaskCheckpoint: Identifiable, Codable, Hashable {
    let id: UUID
    let sequence: Int
    let createdAt: Date
    let gitHead: String
    let changedFileCount: Int
    let reason: String
}

struct ActivityEvent: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let title: String
    let detail: String
    let systemImage: String

    init(
        id: UUID = UUID(),
        date: Date = .now,
        title: String,
        detail: String,
        systemImage: String
    ) {
        self.id = id
        self.date = date
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
    }
}

enum TaskMessageRole: String, Codable, Hashable {
    case user
    case agent
    case system
}

struct TaskAttachment: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let fileName: String
    let filePath: String
    let contentTypeIdentifier: String?
    let byteCount: Int64?
    let securityScopedBookmarkData: Data?
    let addedAt: Date

    init(
        id: UUID = UUID(),
        fileName: String,
        filePath: String,
        contentTypeIdentifier: String? = nil,
        byteCount: Int64? = nil,
        securityScopedBookmarkData: Data? = nil,
        addedAt: Date = .now
    ) {
        self.id = id
        self.fileName = fileName
        self.filePath = filePath
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteCount = byteCount
        self.securityScopedBookmarkData = securityScopedBookmarkData
        self.addedAt = addedAt
    }

    var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }

    func resolvedFileURL() -> URL {
        guard let securityScopedBookmarkData else { return fileURL }
        var isStale = false
        return (try? URL(
            resolvingBookmarkData: securityScopedBookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )) ?? fileURL
    }
}

struct TaskMessage: Identifiable, Codable, Hashable {
    let id: UUID
    let role: TaskMessageRole
    let text: String
    let createdAt: Date
    let attachments: [TaskAttachment]?
    let executionSource: AgentExecutionSource?
    let executionTargetName: String?

    var fileAttachments: [TaskAttachment] {
        attachments ?? []
    }

    init(
        id: UUID = UUID(),
        role: TaskMessageRole,
        text: String,
        createdAt: Date = .now,
        attachments: [TaskAttachment]? = nil,
        executionSource: AgentExecutionSource? = nil,
        executionTargetName: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.attachments = attachments
        self.executionSource = executionSource
        self.executionTargetName = executionTargetName
    }
}

struct CodingTask: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var originalRequest: String
    var repositoryPath: String
    var status: TaskStatus
    var currentAgent: AgentKind?
    var routingMode: AgentRoutingMode?
    var agentConfiguration: TaskAgentConfiguration?
    var specification: TaskSpecification?
    var steps: [TaskStep]
    var gitSnapshot: GitSnapshot
    var handoff: SemanticHandoff
    var validationRecipes: [ValidationRecipe]?
    var validations: [ValidationRun]
    var checkpoints: [TaskCheckpoint]
    var activity: [ActivityEvent]
    var messages: [TaskMessage]?
    var persona: AgentPersona?
    var conversationHandoff: ConversationHandoff?
    var nativeSessionBindings: [AgentSessionBinding]?
    var portableContextCheckpoint: PortableContextCheckpoint?
    let createdAt: Date
    var updatedAt: Date

    var completedStepCount: Int {
        steps.filter(\.isCompleted).count
    }

    var progress: Double {
        guard !steps.isEmpty else { return 0 }
        return Double(completedStepCount) / Double(steps.count)
    }

    var chatMessages: [TaskMessage] {
        messages ?? []
    }

    var effectiveRoutingMode: AgentRoutingMode {
        routingMode ?? .manual
    }

    var configuredExecutionSource: AgentExecutionSource {
        guard effectiveRoutingMode == .manual else { return .cli }
        return agentConfiguration?[.executionSource]
            .flatMap(AgentExecutionSource.init(rawValue:)) ?? .cli
    }

    var configuredAPIProvider: AIAPIProvider? {
        agentConfiguration?[.apiProvider].flatMap(AIAPIProvider.init(rawValue:))
    }

    var configuredAPIModelID: String? {
        let modelID = agentConfiguration?[.apiModel]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return modelID.isEmpty ? nil : modelID
    }

    var configuredAPITarget: AIAPITarget? {
        guard let provider = configuredAPIProvider,
              let modelID = configuredAPIModelID
        else {
            return nil
        }
        return AIAPITarget(provider: provider, modelID: modelID)
    }

    var effectiveSpecification: TaskSpecification {
        specification ?? TaskSpecification(objective: originalRequest)
    }

    var effectivePersona: AgentPersona {
        persona ?? AgentPersona(
            prompt: "Ты — \(title), внимательный автономный разработчик. Общайся ясно, проверяй результат и честно сообщай о рисках.",
            avatarEmoji: "🤖",
            avatarColor: .indigo
        )
    }

    var effectiveInteractionMode: AgentInteractionMode {
        if let explicitMode = persona?.interactionMode {
            return explicitMode
        }
        return .automatic
    }

    var onboardingStage: AgentOnboardingStage? {
        persona?.onboardingStage
    }

    init(
        id: UUID = UUID(),
        title: String,
        originalRequest: String,
        repositoryPath: String,
        status: TaskStatus = .ready,
        currentAgent: AgentKind? = nil,
        routingMode: AgentRoutingMode? = nil,
        agentConfiguration: TaskAgentConfiguration? = nil,
        specification: TaskSpecification? = nil,
        steps: [TaskStep] = [
            TaskStep(title: "Изучить репозиторий и текущий diff"),
            TaskStep(title: "Сформировать план изменений"),
            TaskStep(title: "Реализовать следующий этап"),
            TaskStep(title: "Запустить сборку и тесты"),
            TaskStep(title: "Проверить результат и обновить handoff")
        ],
        gitSnapshot: GitSnapshot = .unavailable,
        handoff: SemanticHandoff = .initial,
        validationRecipes: [ValidationRecipe]? = nil,
        validations: [ValidationRun] = [
            ValidationRun(name: "Сборка"),
            ValidationRun(name: "Тесты")
        ],
        checkpoints: [TaskCheckpoint] = [],
        activity: [ActivityEvent] = [],
        messages: [TaskMessage]? = [],
        persona: AgentPersona? = nil,
        conversationHandoff: ConversationHandoff? = nil,
        nativeSessionBindings: [AgentSessionBinding]? = nil,
        portableContextCheckpoint: PortableContextCheckpoint? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.originalRequest = originalRequest
        self.repositoryPath = repositoryPath
        self.status = status
        self.currentAgent = currentAgent
        self.routingMode = routingMode
        self.agentConfiguration = agentConfiguration
        self.specification = specification
        self.steps = steps
        self.gitSnapshot = gitSnapshot
        self.handoff = handoff
        self.validationRecipes = validationRecipes
        self.validations = validations
        self.checkpoints = checkpoints
        self.activity = activity
        self.messages = messages
        self.persona = persona
        self.conversationHandoff = conversationHandoff
        self.nativeSessionBindings = nativeSessionBindings
        self.portableContextCheckpoint = portableContextCheckpoint
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
