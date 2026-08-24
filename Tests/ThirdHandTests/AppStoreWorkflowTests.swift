import Darwin
import Foundation
import XCTest
@testable import ThirdHand

@MainActor
final class AppStoreWorkflowTests: XCTestCase {
    func testAPICompressionIsPersistedBeforeNextAutomaticAgentStarts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quotaCLI = try makeExecutable(
            named: "quota-openrouter-cli",
            contents: "#!/bin/sh\nprintf 'work in progress\\n' > openrouter-change.txt\nprintf 'quota exceeded for this account\\n'\nexit 1\n",
            in: fixture.root
        )
        let successCLI = try makeExecutable(
            named: "success-openrouter-cli",
            contents: "#!/bin/sh\nfor value in \"$@\"; do prompt=\"$value\"; done\nprintf '%s' \"$prompt\" > compressed-prompt.txt\nprintf '{\"type\":\"result\",\"result\":\"REMOTE_HANDOFF_OK\"}\\n'\n",
            in: fixture.root
        )
        let compressor = RecordingHandoffCompressor(
            result: CompressedAgentHandoff(
                decisions: ["Keep the provider adapter isolated"],
                progress: ["Agent creation flow is implemented"],
                knownIssues: ["Minimum-width QA remains"],
                nextStep: "Run resize QA before changing architecture",
                modelID: "provider/handoff-model"
            )
        )
        let task = CodingTask(
            title: "Remote handoff",
            originalRequest: "Implement seamless switching",
            repositoryPath: fixture.repository.path,
            currentAgent: .codex,
            routingMode: .automatic
        )
        let store = AppStore(
            persistence: PersistenceService(stateURL: fixture.stateURL),
            performAgentDiscovery: false,
            preferredAgentOrder: { [.codex, .claudeCode, .antigravity] },
            handoffCompressor: compressor
        )
        store.tasks = [task]
        store.selection = task.id
        store.agentInstallations = [
            AgentInstallation(kind: .codex, executablePath: quotaCLI.path),
            AgentInstallation(kind: .claudeCode, executablePath: successCLI.path),
            AgentInstallation(kind: .antigravity, executablePath: nil)
        ]

        await store.submitMessage(
            taskID: task.id,
            text: "Продолжай работу",
            attachments: []
        )

        let updated = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(updated.currentAgent, .claudeCode)
        XCTAssertEqual(updated.handoff.decisions, ["Keep the provider adapter isolated"])
        XCTAssertEqual(updated.handoff.progress, ["Agent creation flow is implemented"])
        XCTAssertEqual(updated.handoff.nextStep, "Run resize QA before changing architecture")
        XCTAssertTrue(updated.handoff.knownIssues.contains("Minimum-width QA remains"))
        XCTAssertTrue(updated.handoff.knownIssues.contains { $0.contains("Codex") })
        XCTAssertTrue(updated.chatMessages.contains { $0.text.contains("API-модель provider/handoff-model") })
        XCTAssertTrue(updated.chatMessages.contains { $0.text.contains("REMOTE_HANDOFF_OK") })

        let requests = await compressor.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.previousAgent, .codex)
        XCTAssertEqual(requests.first?.nextAgent, .claudeCode)
        XCTAssertTrue(requests.first?.context.contains("openrouter-change.txt") == true)

        let capturedPrompt = try String(
            contentsOf: fixture.repository.appendingPathComponent("compressed-prompt.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(capturedPrompt.contains("Keep the provider adapter isolated"))
        XCTAssertTrue(capturedPrompt.contains("Run resize QA before changing architecture"))
    }

    func testAPIFailureFallsBackWithoutBlockingAutomaticAgent() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quotaCLI = try makeExecutable(
            named: "quota-fallback-cli",
            contents: "#!/bin/sh\nprintf 'quota exceeded for this account\\n'\nexit 1\n",
            in: fixture.root
        )
        let successCLI = try makeExecutable(
            named: "success-fallback-cli",
            contents: "#!/bin/sh\nprintf '{\"type\":\"result\",\"result\":\"LOCAL_FALLBACK_OK\"}\\n'\n",
            in: fixture.root
        )
        let task = CodingTask(
            title: "Fallback handoff",
            originalRequest: "Continue even if bridge is unavailable",
            repositoryPath: fixture.repository.path,
            currentAgent: .codex,
            routingMode: .automatic
        )
        let store = AppStore(
            persistence: PersistenceService(stateURL: fixture.stateURL),
            performAgentDiscovery: false,
            preferredAgentOrder: { [.codex, .claudeCode, .antigravity] },
            handoffCompressor: FailingHandoffCompressor()
        )
        store.tasks = [task]
        store.selection = task.id
        store.agentInstallations = [
            AgentInstallation(kind: .codex, executablePath: quotaCLI.path),
            AgentInstallation(kind: .claudeCode, executablePath: successCLI.path),
            AgentInstallation(kind: .antigravity, executablePath: nil)
        ]

        await store.submitMessage(taskID: task.id, text: "Continue", attachments: [])

        let updated = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(updated.currentAgent, .claudeCode)
        XCTAssertEqual(updated.status, .ready)
        XCTAssertNotNil(updated.portableContextCheckpoint)
        XCTAssertTrue(updated.chatMessages.contains { $0.text.contains("API-handoff недоступен") })
        XCTAssertTrue(updated.chatMessages.contains { $0.text.contains("LOCAL_FALLBACK_OK") })
    }

    func testStopCancelsInFlightAPICompressionBeforeNextAgentStarts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quotaCLI = try makeExecutable(
            named: "quota-cancel-compression-cli",
            contents: "#!/bin/sh\nprintf 'quota exceeded for this account\\n'\nexit 1\n",
            in: fixture.root
        )
        let nextCLI = try makeExecutable(
            named: "must-not-start-cli",
            contents: "#!/bin/sh\nprintf started > next-agent-started.txt\nprintf '{\"type\":\"result\",\"result\":\"TOO_LATE\"}\\n'\n",
            in: fixture.root
        )
        let compressor = CancellationAwareHandoffCompressor()
        let task = CodingTask(
            title: "Cancel compression",
            originalRequest: "Stop promptly",
            repositoryPath: fixture.repository.path,
            currentAgent: .codex,
            routingMode: .automatic
        )
        let store = AppStore(
            persistence: PersistenceService(stateURL: fixture.stateURL),
            performAgentDiscovery: false,
            preferredAgentOrder: { [.codex, .claudeCode, .antigravity] },
            handoffCompressor: compressor
        )
        store.tasks = [task]
        store.selection = task.id
        store.agentInstallations = [
            AgentInstallation(kind: .codex, executablePath: quotaCLI.path),
            AgentInstallation(kind: .claudeCode, executablePath: nextCLI.path),
            AgentInstallation(kind: .antigravity, executablePath: nil)
        ]

        let execution = Swift.Task {
            await store.submitMessage(taskID: task.id, text: "Continue", attachments: [])
        }
        for _ in 0..<500 {
            if await compressor.hasStarted() { break }
            try await Swift.Task.sleep(for: .milliseconds(10))
        }
        let compressionDidStart = await compressor.hasStarted()
        XCTAssertTrue(compressionDidStart)

        let stopStartedAt = ContinuousClock.now
        await store.stopAgentRun(taskID: task.id)
        await execution.value

        XCTAssertLessThan(ContinuousClock.now - stopStartedAt, .seconds(2))
        XCTAssertEqual(store.tasks.first?.status, .paused)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.repository
                    .appendingPathComponent("next-agent-started.txt")
                    .path
            )
        )
    }

    func testAutomaticModeHandsOffAfterTypedQuotaFailure() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let quotaCLI = try makeExecutable(
            named: "quota-cli",
            contents: "#!/bin/sh\nif [ \"$1\" != \"app-server\" ]; then printf 'changed before handoff\\n' > agent-change.txt; fi\nprintf 'RESOURCE_EXHAUSTED: quota exceeded\\n'\nexit 1\n",
            in: fixture.root
        )
        let successCLI = try makeExecutable(
            named: "success-cli",
            contents: "#!/bin/sh\nfor value in \"$@\"; do prompt=\"$value\"; done\nprintf '%s' \"$prompt\" > captured-prompt.txt\nprintf '{\"type\":\"result\",\"result\":\"AUTO_HANDOFF_OK\"}\\n'\n",
            in: fixture.root
        )

        let task = CodingTask(
            title: "Auto fixture",
            originalRequest: "",
            repositoryPath: fixture.repository.path,
            routingMode: .automatic
        )
        let store = AppStore(
            persistence: PersistenceService(stateURL: fixture.stateURL),
            performAgentDiscovery: false,
            preferredAgentOrder: { [.codex, .claudeCode, .antigravity] }
        )
        store.tasks = [task]
        store.selection = task.id
        store.agentInstallations = [
            AgentInstallation(kind: .codex, executablePath: quotaCLI.path),
            AgentInstallation(kind: .claudeCode, executablePath: successCLI.path),
            AgentInstallation(kind: .antigravity, executablePath: nil)
        ]

        await store.submitMessage(taskID: task.id, text: "Продолжай", attachments: [])

        let updated = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(updated.currentAgent, .claudeCode)
        XCTAssertEqual(updated.status, .ready)
        XCTAssertEqual(updated.chatMessages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(updated.chatMessages.filter { $0.role == .agent }.count, 1)
        XCTAssertTrue(updated.chatMessages.contains { $0.text.contains("Авто передал задачу") })
        XCTAssertTrue(updated.chatMessages.contains { $0.text.contains("AUTO_HANDOFF_OK") })
        XCTAssertEqual(updated.checkpoints.count, 1)
        XCTAssertTrue(updated.handoff.knownIssues.contains { $0.contains("Codex") })
        XCTAssertEqual(store.providerUsage[.codex]?.state, .exhausted)
        XCTAssertTrue(store.activeRuns.isEmpty)

        let capturedPrompt = try String(
            contentsOf: fixture.repository.appendingPathComponent("captured-prompt.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(capturedPrompt.contains("agent-change.txt"), capturedPrompt)
        XCTAssertTrue(capturedPrompt.contains("Inspect the repository and current git diff"))
    }

    func testAutomaticModeStopsAfterEveryProviderReportsQuota() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quotaCLI = try makeExecutable(
            named: "quota-cli",
            contents: "#!/bin/sh\nprintf 'quota exceeded for this account\\n'\nexit 1\n",
            in: fixture.root
        )
        let task = CodingTask(
            title: "All quota",
            originalRequest: "",
            repositoryPath: fixture.repository.path,
            routingMode: .automatic
        )
        let store = makeStore(fixture: fixture)
        store.tasks = [task]
        store.selection = task.id
        store.agentInstallations = [
            AgentInstallation(kind: .codex, executablePath: quotaCLI.path),
            AgentInstallation(kind: .claudeCode, executablePath: quotaCLI.path),
            AgentInstallation(kind: .antigravity, executablePath: nil)
        ]

        await store.submitMessage(taskID: task.id, text: "Продолжай", attachments: [])

        let updated = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(updated.status, .needsAttention)
        XCTAssertEqual(updated.currentAgent, .claudeCode)
        XCTAssertTrue(updated.chatMessages.filter { $0.role == .agent }.isEmpty)
        XCTAssertEqual(store.providerUsage[.codex]?.state, .exhausted)
        XCTAssertEqual(store.providerUsage[.claudeCode]?.state, .exhausted)
        XCTAssertTrue(store.activeRuns.isEmpty)
    }

    func testStructuredAgentReportUpdatesHandoffStepsAndCheckpoint() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let successCLI = try makeExecutable(
            named: "structured-cli",
            contents: """
            #!/bin/sh
            response_file=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "--output-last-message" ]; then
                response_file="$2"
                shift 2
              else
                shift
              fi
            done
            cat > "$response_file" <<'THIRD_HAND_EOF'
            Готово.
            <<<THIRD_HAND_STATUS>>>
            {"decisions":["Keep adapters isolated"],"progress":["Streaming implemented"],"knownIssues":["Interactive stdin pending"],"nextStep":"Review the diff","completedSteps":["Реализовать следующий этап"]}
            <<<END_THIRD_HAND_STATUS>>>
            THIRD_HAND_EOF
            """,
            in: fixture.root
        )
        let task = CodingTask(
            title: "Structured report",
            originalRequest: "Implement",
            repositoryPath: fixture.repository.path,
            currentAgent: .codex
        )
        let store = makeStore(fixture: fixture)
        store.tasks = [task]
        store.selection = task.id
        store.agentInstallations = [
            AgentInstallation(kind: .codex, executablePath: successCLI.path),
            AgentInstallation(kind: .claudeCode, executablePath: nil),
            AgentInstallation(kind: .antigravity, executablePath: nil)
        ]

        await store.submitMessage(
            taskID: task.id,
            text: "Continue",
            attachments: []
        )

        let updated = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(updated.handoff.decisions, ["Keep adapters isolated"])
        XCTAssertEqual(updated.handoff.nextStep, "Review the diff")
        XCTAssertEqual(updated.checkpoints.count, 1)
        XCTAssertTrue(
            updated.steps.first {
                $0.title == "Реализовать следующий этап"
            }?.isCompleted == true
        )
        XCTAssertEqual(updated.chatMessages.last?.text, "Готово.")
    }

    func testFollowUpChatDoesNotSilentlyBecomeTaskSpecification() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let successCLI = try makeExecutable(
            named: "follow-up-cli",
            contents: "#!/bin/sh\nprintf '{\"type\":\"result\",\"result\":\"OK\"}\\n'\n",
            in: fixture.root
        )
        let specification = TaskSpecification(
            objective: "Implement the approved architecture",
            requirementUpdates: ["Preserve the public API"],
            constraints: ["Do not add private APIs"],
            revision: 4
        )
        let task = CodingTask(
            title: "Stable specification",
            originalRequest: "Implement the feature",
            repositoryPath: fixture.repository.path,
            currentAgent: .claudeCode,
            specification: specification
        )
        let store = makeStore(fixture: fixture)
        store.tasks = [task]
        store.selection = task.id
        store.agentInstallations = [
            AgentInstallation(kind: .codex, executablePath: nil),
            AgentInstallation(kind: .claudeCode, executablePath: successCLI.path),
            AgentInstallation(kind: .antigravity, executablePath: nil)
        ]

        await store.submitMessage(
            taskID: task.id,
            text: "Продолжай",
            attachments: []
        )

        let updated = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(updated.effectiveSpecification, specification)
        XCTAssertEqual(updated.effectiveSpecification.revision, 4)
        XCTAssertEqual(
            updated.effectiveSpecification.requirementUpdates,
            ["Preserve the public API"],
            "Routine chat must not evict or rewrite the explicit task contract"
        )
    }

    func testFastStructuredAttemptCheckpointsFreshGitSnapshot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let successCLI = try makeExecutable(
            named: "fast-checkpoint-cli",
            contents: """
            #!/bin/sh
            response_file=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "--output-last-message" ]; then
                response_file="$2"
                shift 2
              else
                shift
              fi
            done
            sleep 0.3
            printf 'new work\n' > fast-agent-change.swift
            cat > "$response_file" <<'THIRD_HAND_EOF'
            Готово.
            <<<THIRD_HAND_STATUS>>>
            {"decisions":[],"progress":["Implemented"],"knownIssues":[],"nextStep":"Review","completedSteps":[]}
            <<<END_THIRD_HAND_STATUS>>>
            THIRD_HAND_EOF
            """,
            in: fixture.root
        )
        let task = CodingTask(
            title: "Fresh checkpoint",
            originalRequest: "Implement",
            repositoryPath: fixture.repository.path,
            currentAgent: .codex
        )
        let store = makeStore(fixture: fixture)
        store.tasks = [task]
        store.selection = task.id
        store.agentInstallations = [
            AgentInstallation(kind: .codex, executablePath: successCLI.path),
            AgentInstallation(kind: .claudeCode, executablePath: nil),
            AgentInstallation(kind: .antigravity, executablePath: nil)
        ]

        await store.submitMessage(
            taskID: task.id,
            text: "Continue",
            attachments: []
        )

        let updated = try XCTUnwrap(store.tasks.first)
        let checkpoint = try XCTUnwrap(updated.checkpoints.last)
        XCTAssertEqual(updated.gitSnapshot.changedFiles.map(\.path), ["fast-agent-change.swift"])
        XCTAssertEqual(
            checkpoint.changedFileCount,
            updated.gitSnapshot.changedFiles.count,
            "Checkpoint metadata must be captured after the agent's final writes"
        )
    }

    func testAttemptEnvelopeUsesFreshGitSnapshotForValidationFreshness() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let initialSnapshot = await GitService().snapshot(at: fixture.repository)
        let initialFingerprint = try XCTUnwrap(initialSnapshot.fingerprint)
        let successCLI = try makeExecutable(
            named: "fresh-envelope-cli",
            contents: "#!/bin/sh\nfor value in \"$@\"; do prompt=\"$value\"; done\nprintf '%s' \"$prompt\" > captured-envelope.txt\nprintf '{\"type\":\"result\",\"result\":\"OK\"}\\n'\n",
            in: fixture.root
        )
        let task = CodingTask(
            title: "Fresh validation envelope",
            originalRequest: "Continue",
            repositoryPath: fixture.repository.path,
            currentAgent: .claudeCode,
            gitSnapshot: initialSnapshot,
            validations: [
                ValidationRun(
                    name: "Previously passing checks",
                    outcome: .passed,
                    summary: "exit 0",
                    gitFingerprint: initialFingerprint
                )
            ]
        )
        let store = makeStore(fixture: fixture)
        store.tasks = [task]
        store.selection = task.id
        store.agentInstallations = [
            AgentInstallation(kind: .codex, executablePath: nil),
            AgentInstallation(kind: .claudeCode, executablePath: successCLI.path),
            AgentInstallation(kind: .antigravity, executablePath: nil)
        ]

        try Data("external edit\n".utf8).write(
            to: fixture.repository.appendingPathComponent("external-change.swift")
        )
        await store.submitMessage(
            taskID: task.id,
            text: "Review current state",
            attachments: []
        )

        let envelope = try String(
            contentsOf: fixture.repository.appendingPathComponent("captured-envelope.txt"),
            encoding: .utf8
        )
        let validationLine = try XCTUnwrap(
            envelope.split(whereSeparator: \.isNewline)
                .map(String.init)
                .first { $0.contains("Previously passing checks") }
        )
        XCTAssertTrue(
            validationLine.localizedCaseInsensitiveContains("stale"),
            "The attempt used a persisted snapshot even though the repository changed: \(validationLine)"
        )
    }

    func testFollowUpAttemptRetainsTaskAttachmentReferences() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reference = fixture.root.appendingPathComponent("architecture-note.md")
        try Data("# Architecture reference\n".utf8).write(to: reference)
        let attachment = TaskAttachment(
            fileName: reference.lastPathComponent,
            filePath: reference.path,
            contentTypeIdentifier: "net.daringfireball.markdown"
        )
        let successCLI = try makeExecutable(
            named: "retained-attachment-cli",
            contents: "#!/bin/sh\nfor value in \"$@\"; do prompt=\"$value\"; done\nprintf '%s' \"$prompt\" > retained-attachment-prompt.txt\nprintf '{\"type\":\"result\",\"result\":\"OK\"}\\n'\n",
            in: fixture.root
        )
        let task = CodingTask(
            title: "Retained attachment",
            originalRequest: "Use the architecture reference",
            repositoryPath: fixture.repository.path,
            currentAgent: .claudeCode,
            messages: [
                TaskMessage(
                    role: .user,
                    text: "Use the attached architecture reference.",
                    attachments: [attachment]
                )
            ]
        )
        let store = makeStore(fixture: fixture)
        store.tasks = [task]
        store.selection = task.id
        store.agentInstallations = [
            AgentInstallation(kind: .codex, executablePath: nil),
            AgentInstallation(kind: .claudeCode, executablePath: successCLI.path),
            AgentInstallation(kind: .antigravity, executablePath: nil)
        ]

        await store.submitMessage(
            taskID: task.id,
            text: "Continue after reviewing the reference.",
            attachments: []
        )

        let prompt = try String(
            contentsOf: fixture.repository
                .appendingPathComponent("retained-attachment-prompt.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(prompt.contains(reference.lastPathComponent), prompt)
        XCTAssertTrue(prompt.contains(reference.path), prompt)
    }

    func testStopDuringAutomaticHandoffPreventsNextAgentFromFinishing() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let quotaCLI = try makeExecutable(
            named: "quota-cli",
            contents: "#!/bin/sh\nprintf 'quota exceeded for this account\\n'\nexit 1\n",
            in: fixture.root
        )
        let slowCLI = try makeExecutable(
            named: "slow-cli",
            contents: "#!/bin/sh\nsleep 5\nprintf 'should not exist' > next-agent-finished.txt\nprintf '{\"type\":\"result\",\"result\":\"TOO_LATE\"}\\n'\n",
            in: fixture.root
        )
        let task = CodingTask(
            title: "Stop handoff",
            originalRequest: "",
            repositoryPath: fixture.repository.path,
            routingMode: .automatic
        )
        let store = makeStore(fixture: fixture)
        store.tasks = [task]
        store.selection = task.id
        store.agentInstallations = [
            AgentInstallation(kind: .codex, executablePath: quotaCLI.path),
            AgentInstallation(kind: .claudeCode, executablePath: slowCLI.path),
            AgentInstallation(kind: .antigravity, executablePath: nil)
        ]

        let execution = Swift.Task {
            await store.submitMessage(taskID: task.id, text: "Продолжай", attachments: [])
        }
        for _ in 0..<300 {
            if store.activeRuns[task.id]?.agent == .claudeCode { break }
            try await Swift.Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.activeRuns[task.id]?.agent, .claudeCode)
        await store.stopAgentRun(taskID: task.id)
        await execution.value

        let updated = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(updated.status, .paused)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.repository.appendingPathComponent("next-agent-finished.txt").path
            )
        )
        XCTAssertFalse(updated.chatMessages.contains { $0.text.contains("TOO_LATE") })
        XCTAssertTrue(store.activeRuns.isEmpty)
    }

    func testCasualMessageUsesOpenRouterFreeBeforeLookingForCLI() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let responder = RecordingConversationResponder(
            response: OpenRouterConversationResponse(
                text: "Привет! Я рядом.",
                modelID: "provider/friendly-model:free"
            )
        )
        let task = CodingTask(
            title: "Стеша",
            originalRequest: "",
            repositoryPath: fixture.repository.path,
            routingMode: .automatic,
            messages: [
                TaskMessage(role: .user, text: "Мне сегодня немного грустно"),
                TaskMessage(role: .agent, text: "Я рядом, хочешь поговорить?")
            ],
            persona: AgentPersona(
                prompt: "Ты — Стеша, виртуальная подруга для душевных разговоров.",
                interactionMode: .automatic
            )
        )
        let store = AppStore(
            persistence: PersistenceService(stateURL: fixture.stateURL),
            performAgentDiscovery: false,
            preferredAgentOrder: { [.codex, .claudeCode, .antigravity] },
            conversationResponder: responder
        )
        store.tasks = [task]
        store.selection = task.id
        store.agentInstallations = AgentKind.allCases.map {
            AgentInstallation(kind: $0, executablePath: nil)
        }

        await store.submitMessage(taskID: task.id, text: "Привет", attachments: [])

        let updated = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(updated.status, .ready)
        XCTAssertEqual(updated.chatMessages.last?.text, "Привет! Я рядом.")
        XCTAssertTrue(
            updated.activity.contains {
                $0.detail.contains("provider/friendly-model:free")
            }
        )
        XCTAssertTrue(store.activeRuns.isEmpty)

        let requests = await responder.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let prompt = try XCTUnwrap(requests.first?.prompt)
        XCTAssertTrue(prompt.contains("виртуальная подруга"))
        XCTAssertTrue(prompt.contains("Мне сегодня немного грустно"))
        XCTAssertTrue(prompt.contains("Привет"))
        XCTAssertFalse(prompt.contains(fixture.repository.path))
        XCTAssertFalse(prompt.contains("<task_specification"))
    }

    func testProjectMessageDoesNotUseOpenRouterConversationRoute() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projectCLI = try makeExecutable(
            named: "project-only-cli",
            contents: "#!/bin/sh\nprintf '{\"type\":\"result\",\"result\":\"PROJECT_OK\"}\\n'\n",
            in: fixture.root
        )
        let responder = RecordingConversationResponder(
            response: OpenRouterConversationResponse(
                text: "MUST_NOT_BE_USED",
                modelID: "provider/free:free"
            )
        )
        let task = CodingTask(
            title: "Муни",
            originalRequest: "",
            repositoryPath: fixture.repository.path,
            currentAgent: .claudeCode,
            routingMode: .manual,
            persona: AgentPersona(
                prompt: "Ты — Муни, разработчик и программист.",
                interactionMode: .automatic
            )
        )
        let store = AppStore(
            persistence: PersistenceService(stateURL: fixture.stateURL),
            performAgentDiscovery: false,
            preferredAgentOrder: { [.codex, .claudeCode, .antigravity] },
            conversationResponder: responder
        )
        store.tasks = [task]
        store.selection = task.id
        store.agentInstallations = [
            AgentInstallation(kind: .codex, executablePath: nil),
            AgentInstallation(kind: .claudeCode, executablePath: projectCLI.path),
            AgentInstallation(kind: .antigravity, executablePath: nil)
        ]

        await store.submitMessage(
            taskID: task.id,
            text: "Исправь баг в SwiftUI-коде",
            attachments: []
        )

        XCTAssertEqual(store.tasks.first?.chatMessages.last?.text, "PROJECT_OK")
        let requests = await responder.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testCasualMessageRunsOutsideRepositoryWithConversationPrompt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let capturedPromptURL = fixture.root.appendingPathComponent("casual-prompt.txt")
        let capturedDirectoryURL = fixture.root.appendingPathComponent("casual-working-directory.txt")
        let successCLI = try makeExecutable(
            named: "casual-claude-cli",
            contents: """
            #!/bin/sh
            for value in "$@"; do prompt="$value"; done
            printf '%s' "$prompt" > '\(capturedPromptURL.path)'
            pwd > '\(capturedDirectoryURL.path)'
            sleep 0.3
            printf '{"type":"result","result":"Привет! Я рядом. Как ты сегодня?"}\n'
            """,
            in: fixture.root
        )
        let task = CodingTask(
            title: "Стеша",
            originalRequest: "",
            repositoryPath: fixture.repository.path,
            currentAgent: .claudeCode,
            routingMode: .manual,
            persona: AgentPersona(
                prompt: "Ты — Стеша, виртуальная подруга для душевных разговоров.",
                interactionMode: .automatic
            )
        )
        let store = makeStore(fixture: fixture)
        store.tasks = [task]
        store.selection = task.id
        store.agentInstallations = [
            AgentInstallation(kind: .codex, executablePath: nil),
            AgentInstallation(kind: .claudeCode, executablePath: successCLI.path),
            AgentInstallation(kind: .antigravity, executablePath: nil)
        ]

        let execution = Swift.Task {
            await store.submitMessage(taskID: task.id, text: "Привет", attachments: [])
        }
        for _ in 0..<100 where store.activeRuns[task.id] == nil {
            try await Swift.Task.sleep(for: .milliseconds(10))
        }
        let activeRun = try XCTUnwrap(store.activeRuns[task.id])
        XCTAssertEqual(activeRun.interactionMode, .conversation)
        XCTAssertFalse(activeRun.presentsDetailedActivity)
        XCTAssertFalse(
            store.isRepositoryBusyForInteraction(task.repositoryPath),
            "A casual response must not reserve the project repository"
        )

        await execution.value

        let updated = try XCTUnwrap(store.tasks.first)
        XCTAssertTrue(updated.originalRequest.isEmpty)
        XCTAssertNil(updated.specification)
        XCTAssertEqual(updated.status, .ready)
        XCTAssertEqual(
            updated.chatMessages.last?.text,
            "Привет! Я рядом. Как ты сегодня?"
        )

        let prompt = try String(contentsOf: capturedPromptURL, encoding: .utf8)
        XCTAssertTrue(prompt.contains("обычный личный диалог"))
        XCTAssertTrue(prompt.contains("виртуальная подруга"))
        XCTAssertFalse(prompt.contains(fixture.repository.path))
        XCTAssertFalse(prompt.contains("<task_specification"))
        XCTAssertFalse(prompt.contains("<<<THIRD_HAND_STATUS>>>"))

        let workingDirectory = try String(
            contentsOf: capturedDirectoryURL,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(workingDirectory, fixture.repository.path)
        XCTAssertTrue(workingDirectory.contains("Conversation Sessions"))
    }

    func testSessionResumeSlashCommandPersistsBindingAcrossStoreReload() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let task = CodingTask(
            title: "Муни",
            originalRequest: "",
            repositoryPath: fixture.repository.path,
            currentAgent: .codex,
            routingMode: .manual,
            persona: AgentPersona(
                prompt: "Постоянный собеседник",
                interactionMode: .conversation
            )
        )
        let store = makeStore(fixture: fixture)
        store.tasks = [task]
        store.selection = task.id

        await store.submitMessage(
            taskID: task.id,
            text: "/session resume codex-session-123",
            attachments: []
        )

        let updated = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(updated.nativeSessionBindings?.count, 1)
        XCTAssertEqual(updated.nativeSessionBindings?.first?.agent, .codex)
        XCTAssertEqual(updated.nativeSessionBindings?.first?.scope, .conversation)
        XCTAssertEqual(updated.nativeSessionBindings?.first?.sessionID, "codex-session-123")
        XCTAssertTrue(updated.chatMessages.allSatisfy { $0.role == .system })

        let reloaded = AppStore(
            persistence: PersistenceService(stateURL: fixture.stateURL),
            performAgentDiscovery: false
        )
        XCTAssertEqual(
            reloaded.tasks.first?.nativeSessionBindings?.first?.sessionID,
            "codex-session-123"
        )

        await reloaded.submitMessage(
            taskID: task.id,
            text: "/context",
            attachments: []
        )
        XCTAssertTrue(
            reloaded.tasks.first?.chatMessages.last?.text.contains("Native resume: Codex") == true
        )
        XCTAssertTrue(
            reloaded.tasks.first?.chatMessages.last?.text.contains(fixture.stateURL.path) == true
        )
    }

    func testClaudeNativeSessionAutomaticallyResumesAfterStoreReload() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let invocationLog = fixture.root.appendingPathComponent("claude-session-log.txt")
        let fakeClaude = try makeExecutable(
            named: "persistent-claude-cli",
            contents: """
            #!/bin/sh
            mode=missing
            session=missing
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --session-id)
                        mode=fresh
                        session="$2"
                        shift 2
                        ;;
                    --resume)
                        mode=resume
                        session="$2"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            printf '%s:%s\n' "$mode" "$session" >> '\(invocationLog.path)'
            printf '{"type":"result","result":"SESSION_OK","session_id":"%s"}\n' "$session"
            """,
            in: fixture.root
        )
        let task = CodingTask(
            title: "Муни",
            originalRequest: "",
            repositoryPath: fixture.repository.path,
            currentAgent: .claudeCode,
            routingMode: .manual,
            persona: AgentPersona(
                prompt: "Постоянный собеседник",
                interactionMode: .conversation
            )
        )
        let firstStore = makeStore(fixture: fixture)
        firstStore.tasks = [task]
        firstStore.selection = task.id
        firstStore.agentInstallations = [
            AgentInstallation(kind: .codex, executablePath: nil),
            AgentInstallation(kind: .claudeCode, executablePath: fakeClaude.path),
            AgentInstallation(kind: .antigravity, executablePath: nil),
            AgentInstallation(kind: .deepSeek, executablePath: nil)
        ]

        await firstStore.submitMessage(
            taskID: task.id,
            text: "Первое сообщение",
            attachments: []
        )
        let firstSessionID = try XCTUnwrap(
            firstStore.tasks.first?.nativeSessionBindings?.first?.sessionID
        )

        let secondStore = AppStore(
            persistence: PersistenceService(stateURL: fixture.stateURL),
            performAgentDiscovery: false
        )
        secondStore.agentInstallations = firstStore.agentInstallations
        await secondStore.submitMessage(
            taskID: task.id,
            text: "Сообщение после перезапуска",
            attachments: []
        )

        let lines = try String(contentsOf: invocationLog, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(lines, [
            "fresh:\(firstSessionID)",
            "resume:\(firstSessionID)"
        ])
        XCTAssertEqual(
            secondStore.tasks.first?.nativeSessionBindings?.first?.sessionID,
            firstSessionID
        )
    }

    func testCompactSlashCommandPersistsCheckpointAndRetiresNativeSessions() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let compressor = RecordingHandoffCompressor(
            result: CompressedAgentHandoff(
                decisions: ["Пользователь предпочитает короткие ответы"],
                progress: ["Обсудили архитектуру сессий"],
                knownIssues: ["Нужно проверить UI"],
                nextStep: "Продолжить с command palette",
                modelID: "test/handoff-model"
            )
        )
        let task = CodingTask(
            title: "Муни",
            originalRequest: "",
            repositoryPath: fixture.repository.path,
            currentAgent: .codex,
            routingMode: .manual,
            messages: [
                TaskMessage(role: .user, text: "Сделай команды"),
                TaskMessage(role: .agent, text: "Хорошо")
            ],
            persona: AgentPersona(
                prompt: "Постоянный собеседник",
                interactionMode: .conversation
            ),
            nativeSessionBindings: [
                AgentSessionBinding(
                    agent: .codex,
                    scope: .conversation,
                    sessionID: "old-native-session",
                    workingDirectory: fixture.root.path
                )
            ]
        )
        let store = AppStore(
            persistence: PersistenceService(stateURL: fixture.stateURL),
            performAgentDiscovery: false,
            handoffCompressor: compressor
        )
        store.tasks = [task]
        store.selection = task.id

        await store.submitMessage(taskID: task.id, text: "/compact", attachments: [])

        let updated = try XCTUnwrap(store.tasks.first)
        let checkpoint = try XCTUnwrap(updated.portableContextCheckpoint)
        XCTAssertEqual(checkpoint.scope, .conversation)
        XCTAssertEqual(checkpoint.decisions, ["Пользователь предпочитает короткие ответы"])
        XCTAssertEqual(checkpoint.coveredThroughMessageID, task.chatMessages.last?.id)
        XCTAssertNil(updated.nativeSessionBindings)
        XCTAssertTrue(updated.chatMessages.last?.text.contains("чистую нативную сессию") == true)
        XCTAssertTrue(store.activeRuns.isEmpty)

        let reloaded = AppStore(
            persistence: PersistenceService(stateURL: fixture.stateURL),
            performAgentDiscovery: false
        )
        XCTAssertEqual(
            reloaded.tasks.first?.portableContextCheckpoint?.modelID,
            "test/handoff-model"
        )
    }

    func testDeletionRemovesOnlyTaskRecordAndKeepsRepository() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let repositoryMarker = fixture.repository.appendingPathComponent("keep-me.txt")
        try Data("repository stays".utf8).write(to: repositoryMarker)
        let first = CodingTask(
            title: "Delete me",
            originalRequest: "Request",
            repositoryPath: fixture.repository.path
        )
        let second = CodingTask(
            title: "Keep me",
            originalRequest: "Request",
            repositoryPath: fixture.repository.path
        )
        let store = AppStore(
            persistence: PersistenceService(stateURL: fixture.stateURL),
            performAgentDiscovery: false
        )
        store.tasks = [first, second]
        store.selection = first.id

        store.requestTaskDeletion(first.id)
        XCTAssertEqual(store.taskPendingDeletion, first.id)
        store.confirmTaskDeletion()

        XCTAssertEqual(store.tasks.map(\.id), [second.id])
        XCTAssertEqual(store.selection, second.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repositoryMarker.path))
    }

    private func makeFixture() throws -> (root: URL, repository: URL, stateURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThirdHandStoreFixture-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", repository.path, "init", "-b", "main"]
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try git.run()
        git.waitUntilExit()
        guard git.terminationStatus == 0 else {
            throw POSIXError(.EIO)
        }
        return (root, repository, root.appendingPathComponent("state.json"))
    }

    private func makeStore(
        fixture: (root: URL, repository: URL, stateURL: URL)
    ) -> AppStore {
        AppStore(
            persistence: PersistenceService(stateURL: fixture.stateURL),
            performAgentDiscovery: false,
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
        guard chmod(url.path, 0o700) == 0 else {
            throw POSIXError(.EPERM)
        }
        return url
    }
}

private actor RecordingHandoffCompressor: AgentHandoffCompressing {
    private let result: CompressedAgentHandoff
    private var requests: [AgentHandoffCompressionRequest] = []

    init(result: CompressedAgentHandoff) {
        self.result = result
    }

    func compress(
        _ request: AgentHandoffCompressionRequest
    ) async throws -> CompressedAgentHandoff? {
        requests.append(request)
        return result
    }

    func recordedRequests() -> [AgentHandoffCompressionRequest] {
        requests
    }
}

private actor RecordingConversationResponder: OpenRouterConversationResponding {
    private let response: OpenRouterConversationResponse?
    private var requests: [OpenRouterConversationRequest] = []

    init(response: OpenRouterConversationResponse?) {
        self.response = response
    }

    func respond(
        to request: OpenRouterConversationRequest
    ) async throws -> OpenRouterConversationResponse? {
        requests.append(request)
        return response
    }

    func recordedRequests() -> [OpenRouterConversationRequest] {
        requests
    }
}

private struct FailingHandoffCompressor: AgentHandoffCompressing {
    func compress(
        _ request: AgentHandoffCompressionRequest
    ) async throws -> CompressedAgentHandoff? {
        throw StubHandoffError.unavailable
    }
}

private actor CancellationAwareHandoffCompressor: AgentHandoffCompressing {
    private var started = false

    func compress(
        _ request: AgentHandoffCompressionRequest
    ) async throws -> CompressedAgentHandoff? {
        started = true
        try await Swift.Task.sleep(for: .seconds(30))
        return nil
    }

    func hasStarted() -> Bool {
        started
    }
}

private enum StubHandoffError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "OpenRouter test outage"
    }
}
