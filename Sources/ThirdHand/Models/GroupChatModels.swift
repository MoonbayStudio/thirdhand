import Foundation

enum GroupChatStatus: String, Codable, Hashable, Sendable {
    case ready
    case discussing
    case needsAttention
}

enum GroupChatMessageRole: String, Codable, Hashable, Sendable {
    case user
    case agent
    case summary
    case system
}

struct GroupChatMessage: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let role: GroupChatMessageRole
    let text: String
    let senderAgentID: UUID?
    let senderName: String?
    let executionSource: AgentExecutionSource?
    let executionTargetName: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: GroupChatMessageRole,
        text: String,
        senderAgentID: UUID? = nil,
        senderName: String? = nil,
        executionSource: AgentExecutionSource? = nil,
        executionTargetName: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.senderAgentID = senderAgentID
        self.senderName = senderName
        self.executionSource = executionSource
        self.executionTargetName = executionTargetName
        self.createdAt = createdAt
    }
}

struct AgentGroupChat: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var participantIDs: [UUID]
    var messages: [GroupChatMessage]
    var status: GroupChatStatus
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        participantIDs: [UUID],
        messages: [GroupChatMessage] = [],
        status: GroupChatStatus = .ready,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.participantIDs = Self.uniqued(participantIDs)
        self.messages = messages
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var lastPreview: String? {
        messages.last(where: { $0.role != .system })?.text
    }

    private static func uniqued(_ values: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return values.filter { seen.insert($0).inserted }
    }
}

enum GroupChatRunPhase: String, Hashable, Sendable {
    case discussing
    case summarizing
}

struct GroupChatRunState: Hashable, Sendable {
    let attemptID: UUID
    let currentAgentID: UUID
    let currentAgentName: String
    let currentAgentKind: AgentKind
    let executionTarget: AgentExecutionTarget
    let phase: GroupChatRunPhase
    let startedAt: Date

    init(
        attemptID: UUID,
        currentAgentID: UUID,
        currentAgentName: String,
        currentAgentKind: AgentKind,
        executionTarget: AgentExecutionTarget? = nil,
        phase: GroupChatRunPhase,
        startedAt: Date
    ) {
        self.attemptID = attemptID
        self.currentAgentID = currentAgentID
        self.currentAgentName = currentAgentName
        self.currentAgentKind = currentAgentKind
        self.executionTarget = executionTarget ?? .cli(currentAgentKind)
        self.phase = phase
        self.startedAt = startedAt
    }
}
