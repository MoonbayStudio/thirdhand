import Foundation
import XCTest
@testable import ThirdHand

@MainActor
final class GroupChatTests: XCTestCase {
    func testNameMentionsUsePlainNamesAndPreserveMentionOrder() {
        let stesha = makeAgent(name: "Стеша", role: "милая девушка и дизайнер")
        let moony = makeAgent(name: "Муни", role: "программист")
        let analyst = makeAgent(name: "Аналитик", role: "исследователь")

        let mentioned = AgentNameMentionResolver.mentionedParticipants(
            in: "муни, поспорь со Стешей об интерфейсе. Муниципальный стиль не нужен.",
            participants: [stesha, moony, analyst]
        )

        XCTAssertEqual(mentioned.map(\.id), [moony.id, stesha.id])
    }

    func testGroupPromptIntroducesEveryAgentAndKeepsVisibleTranscript() {
        let stesha = makeAgent(name: "Стеша", role: "милая девушка и дизайнер")
        let moony = makeAgent(name: "Муни", role: "программист")
        let group = AgentGroupChat(
            title: "Идея приложения",
            participantIDs: [stesha.id, moony.id],
            messages: [
                GroupChatMessage(
                    role: .user,
                    text: "Стеша, обсудите с Муни розовые кнопки"
                ),
                GroupChatMessage(
                    role: .agent,
                    text: "Розовый можно оставить для акцентов.",
                    senderAgentID: stesha.id,
                    senderName: stesha.title
                )
            ]
        )

        let prompt = GroupChatPromptBuilder.discussionPrompt(
            group: group,
            participants: [stesha, moony],
            speaker: moony,
            currentUserMessage: "Стеша, обсудите с Муни розовые кнопки",
            turn: 2,
            totalTurns: 4
        )

        XCTAssertTrue(prompt.contains("Ты — Муни"))
        XCTAssertTrue(prompt.contains("<member name=\"Стеша\">"))
        XCTAssertTrue(prompt.contains("<member name=\"Муни\">"))
        XCTAssertTrue(prompt.contains("Стеша: Розовый можно оставить для акцентов."))
        XCTAssertTrue(prompt.contains("без символа @"))
    }

    func testMentionedAgentsAlternateAndDiscussionEndsWithSummary() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThirdHandGroupTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let responder = QueueingGroupConversationResponder(
            responses: [
                "Стартовая идея Стеши",
                "Возражение Муни",
                "Уточнение Стеши",
                "Компромисс Муни",
                "Договорились оставить розовый для акцентных кнопок."
            ]
        )
        let store = AppStore(
            persistence: PersistenceService(
                stateURL: temporaryRoot.appendingPathComponent("state.json")
            ),
            performAgentDiscovery: false,
            notificationService: NoopGroupNotificationService(),
            providerUsageService: UnknownGroupUsageProvider(),
            conversationResponder: responder
        )
        let stesha = makeAgent(name: "Стеша", role: "милая девушка и дизайнер")
        let moony = makeAgent(name: "Муни", role: "программист")
        store.tasks = [stesha, moony]
        let groupID = try XCTUnwrap(
            store.createGroupChat(
                title: "Идея приложения",
                participantIDs: [stesha.id, moony.id]
            )
        )

        await store.submitGroupMessage(
            groupID: groupID,
            text: "Стеша, обсудите с Муни идею приложения"
        )

        let group = try XCTUnwrap(store.groupChats.first { $0.id == groupID })
        let agentMessages = group.messages.filter { $0.role == .agent }
        XCTAssertEqual(
            agentMessages.compactMap(\.senderAgentID),
            [stesha.id, moony.id, stesha.id, moony.id]
        )
        XCTAssertEqual(group.messages.filter { $0.role == .summary }.count, 1)
        XCTAssertEqual(group.messages.last?.text, "Договорились оставить розовый для акцентных кнопок.")
        XCTAssertEqual(group.status, .ready)
        XCTAssertNil(store.activeGroupRuns[groupID])
        let requestCount = await responder.requestCount()
        XCTAssertEqual(requestCount, 5)
    }

    func testSingleMentionRoutesOnlyToNamedAgentWithoutExtraSummary() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThirdHandGroupTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let responder = QueueingGroupConversationResponder(
            responses: ["Я отвечаю на прямой вопрос."]
        )
        let store = AppStore(
            persistence: PersistenceService(
                stateURL: temporaryRoot.appendingPathComponent("state.json")
            ),
            performAgentDiscovery: false,
            notificationService: NoopGroupNotificationService(),
            providerUsageService: UnknownGroupUsageProvider(),
            conversationResponder: responder
        )
        let stesha = makeAgent(name: "Стеша", role: "дизайнер")
        let moony = makeAgent(name: "Муни", role: "программист")
        store.tasks = [stesha, moony]
        let groupID = try XCTUnwrap(
            store.createGroupChat(
                title: "Команда",
                participantIDs: [stesha.id, moony.id]
            )
        )

        await store.submitGroupMessage(
            groupID: groupID,
            text: "Стеша, какой цвет ты выберешь?"
        )

        let group = try XCTUnwrap(store.groupChats.first { $0.id == groupID })
        XCTAssertEqual(
            group.messages.filter { $0.role == .agent }.compactMap(\.senderAgentID),
            [stesha.id]
        )
        XCTAssertFalse(group.messages.contains { $0.role == .summary })
        let requestCount = await responder.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testGroupChatsPersistSeparatelyFromExistingTaskState() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThirdHandGroupPersistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let persistence = PersistenceService(
            stateURL: temporaryRoot.appendingPathComponent("state.json")
        )
        let task = makeAgent(name: "Стеша", role: "дизайнер")
        let group = AgentGroupChat(
            title: "Команда",
            participantIDs: [task.id, UUID()],
            messages: [GroupChatMessage(role: .system, text: "Группа создана")]
        )

        try persistence.saveTasks([task])
        try persistence.saveGroupChats([group])

        XCTAssertEqual(persistence.loadTasks().tasks.map(\.id), [task.id])
        let loadedGroups = persistence.loadGroupChats()
        XCTAssertTrue(loadedGroups.allowsWrites)
        XCTAssertEqual(loadedGroups.groupChats.map(\.id), [group.id])
        XCTAssertEqual(loadedGroups.groupChats.first?.title, group.title)
        XCTAssertEqual(loadedGroups.groupChats.first?.participantIDs, group.participantIDs)
        XCTAssertEqual(loadedGroups.groupChats.first?.messages.map(\.text), ["Группа создана"])
    }

    private func makeAgent(name: String, role: String) -> CodingTask {
        CodingTask(
            title: name,
            originalRequest: "",
            repositoryPath: FileManager.default.temporaryDirectory.path,
            currentAgent: .codex,
            routingMode: .automatic,
            steps: [],
            validations: [],
            persona: AgentPersona(
                prompt: "Ты — \(name), \(role). Общайся естественно и аргументированно.",
                interactionMode: .conversation
            )
        )
    }
}

private actor QueueingGroupConversationResponder: OpenRouterConversationResponding {
    private let responses: [String]
    private var requests: [OpenRouterConversationRequest] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func respond(
        to request: OpenRouterConversationRequest
    ) async throws -> OpenRouterConversationResponse? {
        requests.append(request)
        let index = requests.count - 1
        guard responses.indices.contains(index) else { return nil }
        return OpenRouterConversationResponse(
            text: responses[index],
            modelID: "test/group-model"
        )
    }

    func requestCount() -> Int {
        requests.count
    }
}

private struct UnknownGroupUsageProvider: ProviderUsageProviding {
    func snapshots(
        for installations: [AgentInstallation]
    ) async -> [AgentKind: ProviderUsageSnapshot] {
        Dictionary(uniqueKeysWithValues: installations.map {
            ($0.kind, .unknown(for: $0.kind))
        })
    }
}

private actor NoopGroupNotificationService: TaskNotificationSending {
    func requestAuthorization() async -> Bool { true }
    func post(_ event: TaskNotificationEvent) async {}
    func removeNotifications(taskID: UUID) async {}
}
