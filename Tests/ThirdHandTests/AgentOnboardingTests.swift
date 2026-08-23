import Darwin
import Foundation
import XCTest
@testable import ThirdHand

@MainActor
final class AgentOnboardingTests: XCTestCase {
    func testCreateAgentImmediatelySelectsChatThenAsksIdentity() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let store = makeStore(fixture: fixture)
        let taskID = store.beginAgentCreation(greetingDelay: .zero)
        defer { removeGeneratedDirectories(taskID: taskID, task: store.tasks.first) }

        XCTAssertEqual(store.selection, taskID)
        XCTAssertTrue(store.isShowingInspector)
        XCTAssertEqual(store.tasks.first?.title, "Новый агент")

        for _ in 0..<100 where store.tasks.first?.onboardingStage != .awaitingIdentity {
            try await Task.sleep(for: .milliseconds(10))
        }

        let task = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(task.onboardingStage, .awaitingIdentity)
        XCTAssertEqual(task.chatMessages.count, 1)
        XCTAssertEqual(task.chatMessages.first?.role, .agent)
        XCTAssertEqual(task.chatMessages.first?.text, "Я кто?")
    }

    func testIdentityAnswerConfiguresProfileWithoutShowingInternalAIResponse() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let capturedPrompt = fixture.root.appendingPathComponent("captured-profile-prompt.txt")
        let cli = try makeExecutable(
            named: "profile-codex",
            contents: """
            #!/bin/sh
            response_file=""
            prompt=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "--output-last-message" ]; then
                response_file="$2"
                shift 2
              else
                prompt="$1"
                shift
              fi
            done
            printf '%s' "$prompt" > '\(capturedPrompt.path)'
            cat > "$response_file" <<'THIRD_HAND_EOF'
            <<<THIRD_HAND_AGENT_PROFILE>>>
            {"name":"Муни","personalityPrompt":"Ты — Муни, спокойный разработчик. Отвечай коротко, сначала изучай код и всегда проверяй результат.","avatarColor":"blue","routingMode":"manual","agentKind":"codex","modelID":"gpt-5.6-sol"}
            <<<END_THIRD_HAND_AGENT_PROFILE>>>
            THIRD_HAND_EOF
            """,
            in: fixture.root
        )

        let task = CodingTask(
            title: "Новый агент",
            originalRequest: "",
            repositoryPath: fixture.repository.path,
            currentAgent: .codex,
            routingMode: .automatic,
            steps: [],
            validations: [],
            messages: [TaskMessage(role: .agent, text: "Я кто?")],
            persona: AgentPersona(
                prompt: "Черновик",
                needsReview: true,
                onboardingStage: .awaitingIdentity
            )
        )
        defer { removeGeneratedDirectories(taskID: task.id, task: task) }

        let store = makeStore(fixture: fixture)
        store.tasks = [task]
        store.selection = task.id
        store.agentInstallations = [
            AgentInstallation(kind: .codex, executablePath: cli.path),
            AgentInstallation(kind: .claudeCode, executablePath: nil),
            AgentInstallation(kind: .antigravity, executablePath: nil)
        ]

        await store.submitMessage(
            taskID: task.id,
            text: "Ты Муни, разработчик. Общайся спокойно и коротко, сначала изучай код и проверяй результат.",
            attachments: []
        )

        let updated = try XCTUnwrap(store.tasks.first)
        XCTAssertNil(updated.onboardingStage)
        XCTAssertEqual(updated.title, "Муни")
        XCTAssertEqual(updated.effectivePersona.avatarColor, .blue)
        XCTAssertTrue(updated.effectivePersona.prompt.contains("спокойный разработчик"))
        XCTAssertTrue(updated.effectivePersona.needsReview)
        XCTAssertEqual(updated.effectiveRoutingMode, .manual)
        XCTAssertEqual(updated.currentAgent, .codex)
        XCTAssertEqual(updated.agentConfiguration?[.model], "gpt-5.6-sol")
        XCTAssertEqual(updated.status, .ready)
        XCTAssertTrue(updated.originalRequest.isEmpty)
        XCTAssertEqual(updated.chatMessages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(updated.chatMessages.filter { $0.role == .agent }.map(\.text), ["Я кто?"])
        XCTAssertTrue(updated.chatMessages.contains {
            $0.role == .system && $0.text.contains("Профиль настроен")
        })
        XCTAssertFalse(updated.chatMessages.contains { $0.text.contains("personalityPrompt") })
        XCTAssertTrue(store.activeRuns.isEmpty)

        let prompt = try String(contentsOf: capturedPrompt, encoding: .utf8)
        XCTAssertTrue(prompt.contains("Тебе дали информацию о том, кто должен быть новый агент"))
        XCTAssertTrue(prompt.contains("Ответ получит приложение, а не чат"))
        XCTAssertTrue(prompt.contains("Ты Муни, разработчик"))
    }

    func testProfileResponseParserAcceptsMarkersAndRejectsVisibleProseOnly() throws {
        let profile = try AgentProfileGenerationResponseParser.parse(
            """
            technical prefix
            <<<THIRD_HAND_AGENT_PROFILE>>>
            {"name":"Луна","personalityPrompt":"Ты — Луна, аналитик.","avatarColor":"teal","routingMode":"automatic","agentKind":null,"modelID":null}
            <<<END_THIRD_HAND_AGENT_PROFILE>>>
            """
        )

        XCTAssertEqual(profile.name, "Луна")
        XCTAssertEqual(profile.avatarColor, .teal)
        XCTAssertEqual(profile.interactionMode, .automatic)
        XCTAssertEqual(profile.routingMode, .automatic)
        XCTAssertNil(profile.agentKind)
        XCTAssertThrowsError(
            try AgentProfileGenerationResponseParser.parse("Привет! Я готова.")
        )
    }

    private func makeFixture() throws -> (root: URL, repository: URL, stateURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThirdHandOnboarding-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        return (
            root,
            repository,
            root.appendingPathComponent("state.json")
        )
    }

    private func makeStore(
        fixture: (root: URL, repository: URL, stateURL: URL)
    ) -> AppStore {
        AppStore(
            persistence: PersistenceService(stateURL: fixture.stateURL),
            performAgentDiscovery: false,
            providerUsageService: UnknownUsageProvider(),
            preferredAgentOrder: { [.codex, .claudeCode, .antigravity] }
        )
    }

    private func makeExecutable(
        named name: String,
        contents: String,
        in directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        guard chmod(url.path, 0o755) == 0 else {
            throw POSIXError(.EACCES)
        }
        return url
    }

    private func removeGeneratedDirectories(taskID: UUID, task: CodingTask?) {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let thirdHand = support.appendingPathComponent("Third Hand", isDirectory: true)
        try? FileManager.default.removeItem(
            at: thirdHand
                .appendingPathComponent("Profile Generation", isDirectory: true)
                .appendingPathComponent(taskID.uuidString, isDirectory: true)
        )
        if let task,
           task.repositoryPath.contains("/Third Hand/Agent Workspaces/") {
            try? FileManager.default.removeItem(atPath: task.repositoryPath)
        }
    }
}

private struct UnknownUsageProvider: ProviderUsageProviding {
    func snapshots(
        for installations: [AgentInstallation]
    ) async -> [AgentKind: ProviderUsageSnapshot] {
        Dictionary(uniqueKeysWithValues: installations.map {
            ($0.kind, .unknown(for: $0.kind))
        })
    }
}
