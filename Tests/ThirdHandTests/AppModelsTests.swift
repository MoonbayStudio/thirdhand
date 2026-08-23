import AppKit
import XCTest
@testable import ThirdHand

final class AppModelsTests: XCTestCase {
    func testProgressUsesCompletedSteps() {
        let task = CodingTask(
            title: "Test",
            originalRequest: "Request",
            repositoryPath: "/tmp/repository",
            steps: [
                TaskStep(title: "One", isCompleted: true),
                TaskStep(title: "Two"),
                TaskStep(title: "Three", isCompleted: true),
                TaskStep(title: "Four")
            ]
        )

        XCTAssertEqual(task.completedStepCount, 2)
        XCTAssertEqual(task.progress, 0.5)
    }

    func testInitialHandoffIsCompactAndActionable() {
        let handoff = SemanticHandoff.initial

        XCTAssertFalse(handoff.decisions.isEmpty)
        XCTAssertFalse(handoff.progress.isEmpty)
        XCTAssertFalse(handoff.nextStep.isEmpty)
        XCTAssertLessThan(handoff.decisions.count, 6)
        XCTAssertLessThan(handoff.progress.count, 6)
    }

    func testAntigravityPrefersAgyCommand() {
        XCTAssertEqual(AgentKind.antigravity.commandNames.first, "agy")
        XCTAssertTrue(AgentKind.antigravity.commandNames.contains("antigravity"))
    }

    func testNewTaskStartsWithEmptyChat() {
        let task = CodingTask(
            title: "Chat task",
            originalRequest: "",
            repositoryPath: "/tmp/repository"
        )

        XCTAssertTrue(task.chatMessages.isEmpty)
        XCTAssertTrue(task.originalRequest.isEmpty)
    }

    func testMessageAttachmentsRoundTripWithPersistedMetadata() throws {
        let attachment = TaskAttachment(
            id: UUID(uuidString: "A0E3A19D-D64C-47C1-BBF4-BDDE4862B63F")!,
            fileName: "architecture.md",
            filePath: "/tmp/repository/docs/architecture.md",
            contentTypeIdentifier: "net.daringfireball.markdown",
            byteCount: 4_096,
            securityScopedBookmarkData: Data([0x01, 0x02, 0x03]),
            addedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let message = TaskMessage(
            id: UUID(uuidString: "1B259C12-89FE-4494-A090-E235D781047A")!,
            role: .user,
            text: "Проверь этот файл",
            createdAt: Date(timeIntervalSince1970: 1_750_000_100),
            attachments: [attachment]
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(TaskMessage.self, from: data)

        XCTAssertEqual(decoded, message)
        XCTAssertEqual(decoded.fileAttachments, [attachment])
        XCTAssertEqual(decoded.fileAttachments.first?.fileURL.path, attachment.filePath)
    }

    func testLegacyMessageDecodesWithoutAttachments() throws {
        let message = TaskMessage(
            role: .user,
            text: "Сообщение из старого хранилища",
            attachments: [
                TaskAttachment(fileName: "temporary.txt", filePath: "/tmp/temporary.txt")
            ]
        )
        let encoded = try JSONEncoder().encode(message)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "attachments")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)

        let decoded = try JSONDecoder().decode(TaskMessage.self, from: legacyData)

        XCTAssertEqual(decoded.id, message.id)
        XCTAssertEqual(decoded.role, message.role)
        XCTAssertEqual(decoded.text, message.text)
        XCTAssertNil(decoded.attachments)
        XCTAssertTrue(decoded.fileAttachments.isEmpty)
    }

    func testAgentConfigurationRoundTripsUnknownCLIValues() throws {
        let configuration = TaskAgentConfiguration(
            values: [
                AgentOptionID.model.rawValue: "future-model-2030",
                AgentOptionID.reasoningEffort.rawValue: "extreme",
                "futureProviderOption": "provider-specific-value"
            ]
        )
        let task = CodingTask(
            title: "Configured task",
            originalRequest: "Keep unknown CLI values intact",
            repositoryPath: "/tmp/repository",
            currentAgent: .codex,
            agentConfiguration: configuration
        )

        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(CodingTask.self, from: data)

        XCTAssertEqual(decoded.agentConfiguration, configuration)
        XCTAssertEqual(decoded.agentConfiguration?[.model], "future-model-2030")
        XCTAssertEqual(decoded.agentConfiguration?.values["futureProviderOption"], "provider-specific-value")
    }

    func testLegacyTaskDecodesWithoutAgentConfiguration() throws {
        let task = CodingTask(
            title: "Legacy task",
            originalRequest: "Created before agent configuration existed",
            repositoryPath: "/tmp/repository",
            currentAgent: .claudeCode,
            agentConfiguration: TaskAgentConfiguration(
                values: [AgentOptionID.model.rawValue: "sonnet"]
            )
        )
        let encoded = try JSONEncoder().encode(task)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "agentConfiguration")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)

        let decoded = try JSONDecoder().decode(CodingTask.self, from: legacyData)

        XCTAssertEqual(decoded.id, task.id)
        XCTAssertEqual(decoded.currentAgent, .claudeCode)
        XCTAssertNil(decoded.agentConfiguration)
    }

    func testAgentPersonaRoundTripsAndLegacyTaskGetsSafeDefault() throws {
        let avatarImageData = Data([0x89, 0x50, 0x4E, 0x47])
        let persona = AgentPersona(
            prompt: "Ты — Муни, разработчик. Отвечай коротко.",
            avatarEmoji: "🌙",
            avatarImageData: avatarImageData,
            avatarColor: .blue,
            needsReview: true
        )
        let task = CodingTask(
            title: "Муни",
            originalRequest: "",
            repositoryPath: "/tmp/repository",
            persona: persona
        )

        let encoded = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(CodingTask.self, from: encoded)
        XCTAssertEqual(decoded.persona, persona)
        XCTAssertEqual(decoded.effectivePersona.avatarEmoji, "🌙")
        XCTAssertEqual(decoded.effectivePersona.avatarImageData, avatarImageData)

        var prePhotoObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var prePhotoPersona = try XCTUnwrap(prePhotoObject["persona"] as? [String: Any])
        prePhotoPersona.removeValue(forKey: "avatarImageData")
        prePhotoObject["persona"] = prePhotoPersona
        let prePhotoTask = try JSONDecoder().decode(
            CodingTask.self,
            from: JSONSerialization.data(withJSONObject: prePhotoObject)
        )
        XCTAssertNil(prePhotoTask.effectivePersona.avatarImageData)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "persona")
        let legacy = try JSONDecoder().decode(
            CodingTask.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )

        XCTAssertNil(legacy.persona)
        XCTAssertTrue(legacy.effectivePersona.prompt.contains("Муни"))
        XCTAssertEqual(legacy.effectivePersona.avatarEmoji, "🤖")
        XCTAssertNil(legacy.effectivePersona.avatarImageData)
    }

    @MainActor
    func testAvatarPhotoIsCroppedAndNormalizedForPersistence() throws {
        let image = NSImage(size: NSSize(width: 900, height: 450))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 450).fill()
        image.unlockFocus()

        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let sourceBitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let sourceData = try XCTUnwrap(
            sourceBitmap.representation(using: .png, properties: [:])
        )

        let normalized = try PersonaAvatarImageProcessor.normalizedImageData(from: sourceData)
        let normalizedBitmap = try XCTUnwrap(NSBitmapImageRep(data: normalized))

        XCTAssertEqual(normalizedBitmap.pixelsWide, 512)
        XCTAssertEqual(normalizedBitmap.pixelsHigh, 512)
    }

    func testConversationDescriptionCreatesNamedPersonaDraft() {
        let seed = AgentPersonaDraftParser.parse(
            "Ты Муни, разработчик. Общайся коротко и сначала проверяй код."
        )

        XCTAssertEqual(seed.name, "Муни")
        XCTAssertEqual(seed.avatarEmoji, "🧑‍💻")
        XCTAssertEqual(seed.avatarColor, .blue)
        XCTAssertTrue(seed.prompt.contains("сначала проверяй код"))
    }

    func testLegacyTaskDecodesWithoutRoutingAndLineStats() throws {
        var snapshot = GitSnapshot.unavailable
        snapshot.additions = 12
        snapshot.deletions = 3
        let task = CodingTask(
            title: "Legacy routing",
            originalRequest: "Request",
            repositoryPath: "/tmp/repository",
            currentAgent: .codex,
            routingMode: .automatic,
            gitSnapshot: snapshot
        )
        let encoded = try JSONEncoder().encode(task)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "routingMode")
        var git = try XCTUnwrap(object["gitSnapshot"] as? [String: Any])
        git.removeValue(forKey: "additions")
        git.removeValue(forKey: "deletions")
        object["gitSnapshot"] = git

        let decoded = try JSONDecoder().decode(
            CodingTask.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.effectiveRoutingMode, .manual)
        XCTAssertNil(decoded.gitSnapshot.additions)
        XCTAssertNil(decoded.gitSnapshot.deletions)
    }

    func testTaskSpecificationPreservesCurrentContractWithoutTranscript() throws {
        var specification = TaskSpecification(
            objective: "Сделать безопасный runner",
            constraints: ["Не передавать историю чата"],
            acceptanceCriteria: ["Процесс переживает закрытие окна"],
            productDecisions: ["Git остаётся источником истины"],
            outOfScope: ["Не добавлять browser"],
            openQuestions: ["Нужен ли launch agent?"]
        )
        specification.recordRequirementUpdate("Не менять публичный API")

        let task = CodingTask(
            title: "Specification",
            originalRequest: "Первоначальный запрос",
            repositoryPath: "/tmp/repository",
            specification: specification
        )
        let decoded = try JSONDecoder().decode(
            CodingTask.self,
            from: JSONEncoder().encode(task)
        )

        XCTAssertEqual(decoded.specification, specification)
        XCTAssertEqual(decoded.effectiveSpecification.revision, 2)
        XCTAssertEqual(
            decoded.effectiveSpecification.requirementUpdates,
            ["Не менять публичный API"]
        )
    }

    func testLegacyTaskWithoutSpecificationUsesOriginalRequest() throws {
        let task = CodingTask(
            title: "Legacy specification",
            originalRequest: "Сохранённая исходная задача",
            repositoryPath: "/tmp/repository",
            specification: TaskSpecification(objective: "Temporary")
        )
        let encoded = try JSONEncoder().encode(task)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "specification")
        let decoded = try JSONDecoder().decode(
            CodingTask.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.specification)
        XCTAssertEqual(
            decoded.effectiveSpecification.objective,
            "Сохранённая исходная задача"
        )
    }

    func testCodexParametersFollowSelectedModelCapabilities() throws {
        let capabilities = try XCTUnwrap(AgentCapabilityCatalog.fallback[.codex])

        let solParameters = capabilities.parameters(selectedModelID: "gpt-5.6-sol")
        let solEffort = try XCTUnwrap(solParameters.first { $0.id == .reasoningEffort })
        XCTAssertTrue(solEffort.options.contains { $0.id == "ultra" })
        XCTAssertTrue(solParameters.contains { $0.id == .speedTier })

        let miniParameters = capabilities.parameters(selectedModelID: "gpt-5.4-mini")
        XCTAssertFalse(miniParameters.contains { $0.id == .speedTier })
    }

    func testSafeMenusExcludePermissionBypass() throws {
        let claude = try XCTUnwrap(AgentCapabilityCatalog.fallback[.claudeCode])
        let permissionMode = try XCTUnwrap(
            claude.parameters(selectedModelID: nil).first { $0.id == .permissionMode }
        )

        XCTAssertFalse(permissionMode.options.contains { $0.id == "bypassPermissions" })

        let antigravity = try XCTUnwrap(AgentCapabilityCatalog.fallback[.antigravity])
        let parameterIDs = Set(antigravity.parameters(selectedModelID: nil).map(\.id))
        XCTAssertTrue(parameterIDs.contains(.executionMode))
        XCTAssertTrue(parameterIDs.contains(.sandboxMode))
        XCTAssertFalse(parameterIDs.contains(.reasoningEffort))
    }
}
