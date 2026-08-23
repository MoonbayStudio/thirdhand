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
        case .ready: "Готова"
        case .running: "В работе"
        case .paused: "На паузе"
        case .needsAttention: "Нужно внимание"
        case .completed: "Завершена"
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
        case .all: "Все задачи"
        case .running: "В работе"
        case .needsAttention: "Нужно внимание"
        case .completed: "Завершённые"
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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex CLI"
        case .claudeCode: "Claude Code"
        case .antigravity: "Antigravity"
        }
    }

    var commandNames: [String] {
        switch self {
        case .codex: ["codex"]
        case .claudeCode: ["claude"]
        case .antigravity: ["agy", "antigravity"]
        }
    }

    var shortName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude"
        case .antigravity: "Antigravity"
        }
    }
}

enum AgentRoutingMode: String, Codable, Hashable, Sendable {
    case manual
    case automatic

    var title: String {
        switch self {
        case .manual: "Вручную"
        case .automatic: "Авто"
        }
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
    var needsReview: Bool
    var onboardingStage: AgentOnboardingStage?

    init(
        prompt: String,
        avatarEmoji: String = "🤖",
        avatarImageData: Data? = nil,
        avatarColor: AgentAvatarColor = .indigo,
        needsReview: Bool = false,
        onboardingStage: AgentOnboardingStage? = nil
    ) {
        self.prompt = prompt
        self.avatarEmoji = avatarEmoji
        self.avatarImageData = avatarImageData
        self.avatarColor = avatarColor
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
    var routingMode: AgentRoutingMode
    var agentKind: AgentKind
    var configuration: TaskAgentConfiguration
    var repositoryPath: String
    var needsReview: Bool

    init(
        name: String,
        personalityPrompt: String,
        avatarEmoji: String = "🤖",
        avatarImageData: Data? = nil,
        avatarColor: AgentAvatarColor = .indigo,
        routingMode: AgentRoutingMode = .automatic,
        agentKind: AgentKind = .codex,
        configuration: TaskAgentConfiguration = TaskAgentConfiguration(),
        repositoryPath: String,
        needsReview: Bool = false
    ) {
        self.name = name
        self.personalityPrompt = personalityPrompt
        self.avatarEmoji = avatarEmoji
        self.avatarImageData = avatarImageData
        self.avatarColor = avatarColor
        self.routingMode = routingMode
        self.agentKind = agentKind
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
            routingMode: task.effectiveRoutingMode,
            agentKind: task.currentAgent ?? fallbackAgent,
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

enum ValidationOutcome: String, Codable {
    case passed
    case failed
    case running
    case cancelled
    case notRun

    var title: String {
        switch self {
        case .passed: "Успешно"
        case .failed: "Ошибка"
        case .running: "Выполняется"
        case .cancelled: "Остановлено"
        case .notRun: "Не запускалось"
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

    var fileAttachments: [TaskAttachment] {
        attachments ?? []
    }

    init(
        id: UUID = UUID(),
        role: TaskMessageRole,
        text: String,
        createdAt: Date = .now,
        attachments: [TaskAttachment]? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.attachments = attachments
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
