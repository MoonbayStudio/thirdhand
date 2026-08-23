import Foundation

enum OpenRouterPreferences {
    static let handoffEnabledKey = "openRouterHandoffEnabled"
    static let handoffModelIDKey = "openRouterHandoffModelID"

    static func load(defaults: UserDefaults = .standard) -> OpenRouterHandoffConfiguration {
        OpenRouterHandoffConfiguration(
            isEnabled: defaults.bool(forKey: handoffEnabledKey),
            modelID: defaults.string(forKey: handoffModelIDKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}

struct OpenRouterHandoffConfiguration: Hashable, Sendable {
    let isEnabled: Bool
    let modelID: String

    var isReady: Bool {
        isEnabled && !modelID.isEmpty
    }
}

struct OpenRouterModelOption: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let contextLength: Int?
    let supportedParameters: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case contextLength = "context_length"
        case supportedParameters = "supported_parameters"
    }

    init(
        id: String,
        name: String,
        contextLength: Int? = nil,
        supportedParameters: [String] = []
    ) {
        self.id = id
        self.name = name
        self.contextLength = contextLength
        self.supportedParameters = supportedParameters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength)
        supportedParameters = try container.decodeIfPresent(
            [String].self,
            forKey: .supportedParameters
        ) ?? []
    }
}

struct AgentHandoffCompressionRequest: Hashable, Sendable {
    let previousAgent: AgentKind
    let nextAgent: AgentKind
    let context: String
}

struct CompressedAgentHandoff: Hashable, Sendable {
    let decisions: [String]
    let progress: [String]
    let knownIssues: [String]
    let nextStep: String
    let modelID: String
}

protocol AgentHandoffCompressing: Sendable {
    func compress(
        _ request: AgentHandoffCompressionRequest
    ) async throws -> CompressedAgentHandoff?
}

struct DisabledAgentHandoffCompressor: AgentHandoffCompressing {
    func compress(
        _ request: AgentHandoffCompressionRequest
    ) async throws -> CompressedAgentHandoff? {
        nil
    }
}

enum OpenRouterHandoffPromptBuilder {
    private static let maximumContextCharacters = 32_000

    static func build(
        task: CodingTask,
        from previousAgent: AgentKind,
        to nextAgent: AgentKind,
        gitSnapshot: GitSnapshot,
        lastAgentOutput: String?
    ) -> AgentHandoffCompressionRequest {
        let specification = task.effectiveSpecification
        let persona = task.effectivePersona
        let recentMessages = task.chatMessages.suffix(10).map { message in
            let attachmentNames = message.fileAttachments.map(\.fileName)
            let attachments = attachmentNames.isEmpty
                ? ""
                : " [attachments: \(attachmentNames.joined(separator: ", "))]"
            return "- \(message.role.rawValue): \(limited(message.text, to: 1_200))\(attachments)"
        }
        let changedFiles = gitSnapshot.changedFiles.prefix(60).map { file in
            let additions = file.additions.map { "+\($0)" } ?? ""
            let deletions = file.deletions.map { "-\($0)" } ?? ""
            let lineDelta = [additions, deletions]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return "- \(file.status) \(file.path)\(lineDelta.isEmpty ? "" : " (\(lineDelta))")"
        }
        let completedSteps = task.steps.filter(\.isCompleted).map(\.title)
        let remainingSteps = task.steps.filter { !$0.isCompleted }.map(\.title)
        let validations = task.validations.suffix(8).map {
            "- \($0.name): \($0.outcome.title). \(limited($0.summary, to: 500))"
        }
        let output = lastAgentOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let context = """
        A confirmed account quota error interrupted \(previousAgent.displayName). Prepare a compact, factual continuation for \(nextAgent.displayName). The next agent will independently inspect the repository and its full Git diff, so summarize intent and progress without reproducing code.

        <agent name="\(task.title)">
        Personality contract:
        \(limited(persona.prompt, to: 2_000))
        </agent>

        <task>
        Original request:
        \(limited(task.originalRequest, to: 2_500))

        Current objective (revision \(specification.revision)):
        \(limited(specification.objective, to: 3_000))

        Requirement updates:
        \(list(specification.requirementUpdates))

        Constraints:
        \(list(specification.constraints))

        Acceptance criteria:
        \(list(specification.acceptanceCriteria))

        Accepted product decisions:
        \(list(specification.productDecisions))

        Out of scope:
        \(list(specification.outOfScope))

        Open questions:
        \(list(specification.openQuestions))
        </task>

        <existing_handoff>
        Decisions:
        \(list(task.handoff.decisions))

        Progress:
        \(list(task.handoff.progress))

        Known issues:
        \(list(task.handoff.knownIssues))

        Next step:
        \(limited(task.handoff.nextStep, to: 1_200))
        </existing_handoff>

        <work_plan>
        Completed:
        \(list(completedSteps))

        Remaining:
        \(list(remainingSteps))
        </work_plan>

        <git_summary branch="\(gitSnapshot.branch)" head="\(gitSnapshot.head)">
        \(limited(gitSnapshot.diffStat, to: 3_000))
        Changed files:
        \(changedFiles.isEmpty ? "- None." : changedFiles.joined(separator: "\n"))
        </git_summary>

        <latest_validations>
        \(validations.isEmpty ? "- None." : validations.joined(separator: "\n"))
        </latest_validations>

        <recent_chat>
        \(recentMessages.isEmpty ? "- None." : recentMessages.joined(separator: "\n"))
        </recent_chat>

        <interrupted_agent_output>
        \(output.map { limitedTail($0, to: 5_000) } ?? "- No usable output was captured.")
        </interrupted_agent_output>
        """

        return AgentHandoffCompressionRequest(
            previousAgent: previousAgent,
            nextAgent: nextAgent,
            context: limited(context, to: maximumContextCharacters)
        )
    }

    private static func list(_ values: [String]) -> String {
        let compact = values.suffix(8).map {
            "- \(limited($0, to: 700))"
        }
        return compact.isEmpty ? "- None." : compact.joined(separator: "\n")
    }

    private static func limited(_ value: String, to maximumCharacters: Int) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maximumCharacters else { return normalized }
        return String(normalized.prefix(maximumCharacters)) + "…"
    }

    private static func limitedTail(_ value: String, to maximumCharacters: Int) -> String {
        guard value.count > maximumCharacters else { return value }
        return "…" + String(value.suffix(maximumCharacters))
    }
}
