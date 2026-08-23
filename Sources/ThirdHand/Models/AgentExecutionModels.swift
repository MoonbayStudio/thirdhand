import Foundation

enum AgentRunPhase: String, Hashable, Sendable {
    case preparing
    case compressingContext
    case running
    case stopping

    var title: String {
        switch self {
        case .preparing: AppLocalization.string("Подготовка контекста")
        case .compressingContext: AppLocalization.string("Сжатие контекста")
        case .running: AppLocalization.string("Агент работает")
        case .stopping: AppLocalization.string("Остановка")
        }
    }
}

struct AgentRunState: Hashable, Sendable {
    let attemptID: UUID
    let agent: AgentKind
    let executionTarget: AgentExecutionTarget
    let interactionMode: AgentInteractionMode
    var phase: AgentRunPhase
    let startedAt: Date

    init(
        attemptID: UUID,
        agent: AgentKind,
        executionTarget: AgentExecutionTarget? = nil,
        interactionMode: AgentInteractionMode,
        phase: AgentRunPhase,
        startedAt: Date
    ) {
        self.attemptID = attemptID
        self.agent = agent
        self.executionTarget = executionTarget ?? .cli(agent)
        self.interactionMode = interactionMode
        self.phase = phase
        self.startedAt = startedAt
    }

    var presentsDetailedActivity: Bool {
        interactionMode == .workspace
    }
}

struct RepositoryHandoffContext: Hashable, Sendable {
    let status: String
    let diff: String
    let diffStat: String
    let isGitRepository: Bool
}

struct AgentExecutionRequest: Sendable {
    let attemptID: UUID
    let taskID: UUID
    let agent: AgentKind
    let executablePath: String
    let repositoryPath: String
    let prompt: String
    let configuration: [String: String]
    let attachments: [TaskAttachment]
    let isGitRepository: Bool
}

struct AgentExecutionResponse: Sendable {
    let text: String
    let exitCode: Int32
}

struct AgentLiveOutput: Hashable, Sendable {
    var text: String
    var wasTruncated: Bool
    var updatedAt: Date

    static let empty = AgentLiveOutput(
        text: "",
        wasTruncated: false,
        updatedAt: .now
    )
}

struct ValidationExecutionState: Hashable, Sendable {
    let attemptID: UUID
    let recipeID: UUID
    let name: String
    let startedAt: Date
    var output: String
    var wasTruncated: Bool
    var isStopping: Bool
}

enum AgentFailureCategory: Hashable, Sendable {
    case quotaExceeded
    case authentication
    case permission
    case unknown
}

enum AgentFailureClassifier {
    static func category(for output: String) -> AgentFailureCategory {
        let value = output.lowercased()

        let nonQuotaLimitMarkers = [
            "context window",
            "context length",
            "file size limit",
            "maximum file size",
            "token limit for this request",
            "not your usage limit",
            "not_your_usage_limit",
            "temporarily limiting requests",
            "temporary rate limit",
            "high traffic"
        ]
        if nonQuotaLimitMarkers.contains(where: value.contains) {
            return .unknown
        }

        let quotaMarkers = [
            "usage limit",
            "usage_limit",
            "weekly limit",
            "5-hour limit",
            "quota exceeded",
            "quota_exceeded",
            "insufficient_quota",
            "you've hit your limit",
            "you have hit your limit",
            "limit reached for your account",
            "no weighted tokens left"
        ]
        if quotaMarkers.contains(where: value.contains) {
            return .quotaExceeded
        }

        let authenticationMarkers = [
            "not logged in",
            "authentication required",
            "authentication failed",
            "unauthorized",
            "invalid api key",
            "please log in"
        ]
        if authenticationMarkers.contains(where: value.contains) {
            return .authentication
        }

        let permissionMarkers = [
            "permission denied",
            "operation not permitted",
            "approval required"
        ]
        if permissionMarkers.contains(where: value.contains) {
            return .permission
        }

        return .unknown
    }
}

enum AgentExecutionError: LocalizedError, Sendable {
    case executableUnavailable(AgentKind)
    case repositoryBusy
    case launchFailed(String)
    case usageLimitExceeded(agent: AgentKind, output: String)
    case failed(exitCode: Int32, output: String)
    case emptyResponse
    case cancelled

    var failureCategory: AgentFailureCategory {
        switch self {
        case .usageLimitExceeded:
            .quotaExceeded
        case let .failed(_, output):
            AgentFailureClassifier.category(for: output)
        case .executableUnavailable, .repositoryBusy, .launchFailed, .emptyResponse, .cancelled:
            .unknown
        }
    }

    var errorDescription: String? {
        switch self {
        case let .executableUnavailable(agent):
            "CLI для \(agent.displayName) не найден. Проверьте установку в правом inspector."
        case .repositoryBusy:
            "Другой агент уже работает с этим репозиторием. Дождитесь завершения или остановите его."
        case let .launchFailed(message):
            "Не удалось запустить CLI: \(message)"
        case let .usageLimitExceeded(agent, _):
            "Лимит \(agent.displayName) исчерпан."
        case let .failed(exitCode, output):
            output.isEmpty
                ? "CLI завершился с кодом \(exitCode)."
                : "CLI завершился с кодом \(exitCode): \(output)"
        case .emptyResponse:
            "CLI завершился без финального ответа. Проверьте авторизацию и выбранные параметры агента."
        case .cancelled:
            "Выполнение остановлено."
        }
    }
}
