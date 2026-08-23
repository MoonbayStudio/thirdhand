import Darwin
import Foundation
import XCTest
@testable import ThirdHand

final class AgentExecutionTests: XCTestCase {
    func testPTYRunnerCapturesOutput() async throws {
        let runner = PTYProcessRunner()
        let result = try await runner.run(
            AgentCLIInvocation(
                attemptID: UUID(),
                executablePath: "/usr/bin/printf",
                arguments: ["THIRD_HAND_PTY_OK"],
                workingDirectory: "/tmp",
                environment: ProcessInfo.processInfo.environment
            )
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("THIRD_HAND_PTY_OK"))
    }

    func testPTYRunnerStreamsOutputBeforeProcessFinishes() async throws {
        let runner = PTYProcessRunner()
        let invocation = AgentCLIInvocation(
            attemptID: UUID(),
            executablePath: "/bin/sh",
            arguments: [
                "-c",
                "printf 'FIRST'; sleep 0.25; printf 'SECOND'"
            ],
            workingDirectory: "/tmp",
            environment: ProcessInfo.processInfo.environment
        )

        var streamed = Data()
        var sawFinished = false
        var firstOutputArrivedBeforeFinish = false
        for try await event in runner.events(invocation) {
            switch event {
            case let .output(data, _):
                streamed.append(data)
                if streamed.contains(Data("FIRST".utf8)), !sawFinished {
                    firstOutputArrivedBeforeFinish = true
                }
            case .finished:
                sawFinished = true
            }
        }

        XCTAssertTrue(firstOutputArrivedBeforeFinish)
        XCTAssertTrue(sawFinished)
        XCTAssertTrue(String(decoding: streamed, as: UTF8.self).contains("SECOND"))
    }

    func testPTYRunnerDoesNotExecuteCommandWhenWorkingDirectoryIsMissing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThirdHandMissingCWD-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missingDirectory = root.appendingPathComponent("removed-repository", isDirectory: true)
        let commandMarker = root.appendingPathComponent("command-must-not-run")
        let invocation = AgentCLIInvocation(
            attemptID: UUID(),
            executablePath: "/bin/sh",
            arguments: ["-c", "/usr/bin/touch \(commandMarker.path)"],
            workingDirectory: missingDirectory.path,
            environment: ProcessInfo.processInfo.environment
        )

        do {
            let result = try await PTYProcessRunner().run(invocation)
            XCTAssertEqual(
                result.exitCode,
                126,
                "A missing working directory must fail before executing the command body"
            )
        } catch let error as AgentExecutionError {
            guard case .launchFailed = error else {
                return XCTFail("Unexpected execution error: \(error)")
            }
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: commandMarker.path),
            "The executable ran in Third Hand's inherited cwd after chdir failed"
        )
    }

    func testPTYRunnerCanCancelAttempt() async throws {
        let runner = PTYProcessRunner()
        let attemptID = UUID()
        let startedAt = ContinuousClock.now
        let execution = Swift.Task {
            try await runner.run(
                AgentCLIInvocation(
                    attemptID: attemptID,
                    executablePath: "/bin/sleep",
                    arguments: ["10"],
                    workingDirectory: "/tmp",
                    environment: ProcessInfo.processInfo.environment
                )
            )
        }

        try await Swift.Task.sleep(for: .milliseconds(150))
        let cancelStartedAt = ContinuousClock.now
        let didCancel = runner.cancel(attemptID: attemptID)
        XCTAssertTrue(didCancel)
        XCTAssertLessThan(ContinuousClock.now - cancelStartedAt, .seconds(1))

        do {
            _ = try await execution.value
            XCTFail("Cancelled PTY attempt unexpectedly succeeded")
        } catch let error as AgentExecutionError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(2))
    }

    func testCodexInvocationPlacesGlobalApprovalBeforeExecAndMapsFastTier() {
        let request = AgentExecutionRequest(
            attemptID: UUID(),
            taskID: UUID(),
            agent: .codex,
            executablePath: "/usr/local/bin/codex",
            repositoryPath: "/tmp/repository",
            prompt: "Inspect first",
            configuration: [
                AgentOptionID.model.rawValue: "gpt-5.6-sol",
                AgentOptionID.reasoningEffort.rawValue: "high",
                AgentOptionID.speedTier.rawValue: "priority",
                AgentOptionID.sandboxMode.rawValue: "workspace-write",
                AgentOptionID.approvalPolicy.rawValue: "on-request"
            ],
            attachments: [],
            isGitRepository: true
        )

        let prepared = AgentCLIInvocationFactory.prepare(
            request: request,
            temporaryDirectory: URL(fileURLWithPath: "/tmp")
        )
        let arguments = prepared.invocation.arguments

        XCTAssertEqual(Array(arguments.prefix(3)), ["--ask-for-approval", "on-request", "exec"])
        XCTAssertTrue(arguments.contains("features.fast_mode=true"))
        XCTAssertTrue(arguments.contains("service_tier=\"fast\""))
        XCTAssertFalse(arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    func testClaudeAndAntigravityInvocationsUseOnlySupportedSafeFlags() throws {
        let attachment = TaskAttachment(
            fileName: "context.txt",
            filePath: "/tmp/attachments/context.txt",
            contentTypeIdentifier: "public.plain-text"
        )
        let commonAttemptID = UUID()
        let commonTaskID = UUID()

        let claude = AgentCLIInvocationFactory.prepare(
            request: AgentExecutionRequest(
                attemptID: commonAttemptID,
                taskID: commonTaskID,
                agent: .claudeCode,
                executablePath: "/usr/local/bin/claude",
                repositoryPath: "/tmp/repository",
                prompt: "Inspect first",
                configuration: [
                    AgentOptionID.model.rawValue: "default",
                    AgentOptionID.reasoningEffort.rawValue: "high",
                    AgentOptionID.permissionMode.rawValue: "acceptEdits"
                ],
                attachments: [attachment],
                isGitRepository: true
            ),
            temporaryDirectory: URL(fileURLWithPath: "/tmp")
        ).invocation.arguments
        XCTAssertTrue(claude.contains("--no-session-persistence"))
        XCTAssertTrue(claude.contains("acceptEdits"))
        XCTAssertFalse(claude.contains("bypassPermissions"))
        XCTAssertFalse(claude.contains("--model"), "Default Claude alias should use CLI default")

        let antigravity = AgentCLIInvocationFactory.prepare(
            request: AgentExecutionRequest(
                attemptID: commonAttemptID,
                taskID: commonTaskID,
                agent: .antigravity,
                executablePath: "/usr/local/bin/agy",
                repositoryPath: "/tmp/repository",
                prompt: "Inspect first",
                configuration: [
                    AgentOptionID.model.rawValue: "Gemini 3.6 Flash (High)",
                    AgentOptionID.executionMode.rawValue: "accept-edits",
                    AgentOptionID.sandboxMode.rawValue: "enabled"
                ],
                attachments: [attachment],
                isGitRepository: true
            ),
            temporaryDirectory: URL(fileURLWithPath: "/tmp")
        ).invocation.arguments
        XCTAssertTrue(antigravity.contains("--sandbox"))
        XCTAssertTrue(antigravity.contains("accept-edits"))
        XCTAssertTrue(antigravity.contains("/tmp/attachments"))
        XCTAssertFalse(antigravity.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(antigravity.contains("--print"))
        XCTAssertEqual(antigravity.last, "--print=Inspect first")
        XCTAssertLessThan(
            try XCTUnwrap(antigravity.firstIndex(of: "--model")),
            try XCTUnwrap(antigravity.firstIndex(of: "--print=Inspect first"))
        )
    }

    func testEnvelopeDoesNotIncludePreviousChatMessages() {
        let task = CodingTask(
            title: "Task",
            originalRequest: "Build the feature",
            repositoryPath: "/tmp/repository",
            messages: [
                TaskMessage(role: .agent, text: "PREVIOUS_TRANSCRIPT_MUST_NOT_LEAK")
            ]
        )

        let prompt = TaskEnvelopeBuilder.build(
            task: task,
            currentInstruction: "Continue safely",
            attachments: [],
            repositoryContext: RepositoryHandoffContext(
                status: "## main",
                diff: "diff --git a/file b/file",
                diffStat: "1 file changed",
                isGitRepository: true
            )
        )

        XCTAssertTrue(prompt.contains("Build the feature"))
        XCTAssertTrue(prompt.contains("Continue safely"))
        XCTAssertTrue(prompt.contains("diff --git"))
        XCTAssertFalse(prompt.contains("PREVIOUS_TRANSCRIPT_MUST_NOT_LEAK"))
    }

    func testEnvelopeIncludesCurrentTaskSpecificationAndProgressProtocol() {
        let task = CodingTask(
            title: "Task",
            originalRequest: "Historical request",
            repositoryPath: "/tmp/repository",
            specification: TaskSpecification(
                objective: "Current objective",
                constraints: ["Do not change the API"],
                acceptanceCriteria: ["Tests pass"],
                outOfScope: ["No browser"],
                openQuestions: ["Which database?"],
                revision: 4
            )
        )

        let prompt = TaskEnvelopeBuilder.build(
            task: task,
            currentInstruction: "Continue",
            attachments: [],
            repositoryContext: RepositoryHandoffContext(
                status: "clean",
                diff: "none",
                diffStat: "none",
                isGitRepository: true
            )
        )

        XCTAssertTrue(prompt.contains(#"<task_specification revision="4">"#))
        XCTAssertTrue(prompt.contains("Current objective"))
        XCTAssertTrue(prompt.contains("Do not change the API"))
        XCTAssertTrue(prompt.contains("<<<THIRD_HAND_STATUS>>>"))
    }

    func testEnvelopeIncludesPersistentAgentPersona() {
        let task = CodingTask(
            title: "Муни",
            originalRequest: "Почини интерфейс",
            repositoryPath: "/tmp/repository",
            persona: AgentPersona(
                prompt: "Ты — Муни, разработчик. Общайся спокойно и проверяй результат.",
                avatarEmoji: "🌙",
                avatarColor: .blue
            )
        )

        let prompt = TaskEnvelopeBuilder.build(
            task: task,
            currentInstruction: "Проверь ресайз",
            attachments: [],
            repositoryContext: RepositoryHandoffContext(
                status: "clean",
                diff: "none",
                diffStat: "none",
                isGitRepository: true
            )
        )

        XCTAssertTrue(prompt.contains(#"<agent_persona name="Муни">"#))
        XCTAssertTrue(prompt.contains("Общайся спокойно и проверяй результат"))
        XCTAssertTrue(prompt.contains("Проверь ресайз"))
    }

    func testConversationEnvelopeKeepsPersonaAndChatWithoutProjectContract() {
        let task = CodingTask(
            title: "Стеша",
            originalRequest: "",
            repositoryPath: "/tmp/REPOSITORY_MUST_NOT_APPEAR",
            messages: [
                TaskMessage(role: .user, text: "Я сегодня немного устал"),
                TaskMessage(role: .agent, text: "Давай выдохнем и поговорим"),
                TaskMessage(role: .user, text: "Привет")
            ],
            persona: AgentPersona(
                prompt: "Ты — Стеша, добрая виртуальная подруга для душевных разговоров.",
                interactionMode: .conversation
            )
        )

        let prompt = ConversationEnvelopeBuilder.build(
            task: task,
            currentInstruction: "Привет",
            attachments: []
        )

        XCTAssertTrue(prompt.contains("добрая виртуальная подруга"))
        XCTAssertTrue(prompt.contains("Я сегодня немного устал"))
        XCTAssertTrue(prompt.contains("Давай выдохнем и поговорим"))
        XCTAssertTrue(prompt.contains("<current_user_message>\nПривет"))
        XCTAssertFalse(prompt.contains("/tmp/REPOSITORY_MUST_NOT_APPEAR"))
        XCTAssertFalse(prompt.contains("<task_specification"))
        XCTAssertFalse(prompt.contains("<<<THIRD_HAND_STATUS>>>"))
        XCTAssertFalse(prompt.contains("Inspect the repository and current git diff"))
    }

    func testEnvelopeLabelsValidationFreshnessAgainstCurrentGitFingerprint() throws {
        let snapshot = GitSnapshot(
            branch: "main",
            head: "abc123",
            changedFiles: [ChangedFile(status: "M", path: "Feature.swift")],
            diffStat: "1 file changed",
            capturedAt: .now,
            isGitRepository: true,
            additions: 1,
            deletions: 0,
            fingerprint: "current-fingerprint"
        )
        let task = CodingTask(
            title: "Validation freshness",
            originalRequest: "Continue",
            repositoryPath: "/tmp/repository",
            gitSnapshot: snapshot,
            validations: [
                ValidationRun(
                    name: "Current validation",
                    outcome: .passed,
                    summary: "exit 0",
                    gitFingerprint: "current-fingerprint"
                ),
                ValidationRun(
                    name: "Old validation",
                    outcome: .passed,
                    summary: "exit 0",
                    gitFingerprint: "previous-fingerprint"
                )
            ]
        )

        let prompt = TaskEnvelopeBuilder.build(
            task: task,
            currentInstruction: "Continue",
            attachments: [],
            repositoryContext: RepositoryHandoffContext(
                status: "M Feature.swift",
                diff: "diff",
                diffStat: "1 file changed",
                isGitRepository: true
            )
        )
        let lines = prompt.split(whereSeparator: \.isNewline).map(String.init)
        let currentLine = try XCTUnwrap(lines.first { $0.contains("Current validation") })
        let oldLine = try XCTUnwrap(lines.first { $0.contains("Old validation") })

        XCTAssertTrue(
            currentLine.localizedCaseInsensitiveContains("fresh"),
            currentLine
        )
        XCTAssertTrue(
            oldLine.localizedCaseInsensitiveContains("stale"),
            oldLine
        )
    }

    func testOutputParserRemovesTerminalFormattingAndReadsClaudeJSON() throws {
        let formatted = "\u{001B}[31mОшибка\u{001B}[0m\r\n"
        XCTAssertEqual(
            AgentOutputParser.clean(formatted).trimmingCharacters(in: .whitespacesAndNewlines),
            "Ошибка"
        )

        let response = try AgentOutputParser.finalResponse(
            for: .claudeCode,
            terminalOutput: #"{"type":"result","result":"Готово"}"#,
            responseFileURL: nil
        )
        XCTAssertEqual(response, "Готово")
    }

    func testFailureClassifierRecognizesQuotaWithoutMisclassifyingOtherLimits() {
        XCTAssertEqual(
            AgentFailureClassifier.category(for: "You've hit your usage limit. Resets tomorrow."),
            .quotaExceeded
        )
        XCTAssertEqual(
            AgentFailureClassifier.category(for: #"{"type":"rate_limit_error"}"#),
            .unknown
        )
        XCTAssertEqual(
            AgentFailureClassifier.category(for: "RESOURCE_EXHAUSTED: quota exceeded"),
            .quotaExceeded
        )
        XCTAssertEqual(
            AgentFailureClassifier.category(for: "context window token limit exceeded"),
            .unknown
        )
        XCTAssertEqual(
            AgentFailureClassifier.category(for: "file size limit is 10 MB"),
            .unknown
        )
        XCTAssertEqual(
            AgentFailureClassifier.category(for: "HTTP 429"),
            .unknown
        )
        XCTAssertEqual(
            AgentFailureClassifier.category(
                for: "Server is temporarily limiting requests (not your usage limit)"
            ),
            .unknown
        )
    }

    func testPTYRunnerRemembersCancellationBeforeSessionRegistration() async {
        let runner = PTYProcessRunner()
        let attemptID = UUID()
        XCTAssertTrue(runner.cancel(attemptID: attemptID))

        do {
            _ = try await runner.run(
                AgentCLIInvocation(
                    attemptID: attemptID,
                    executablePath: "/bin/sleep",
                    arguments: ["5"],
                    workingDirectory: "/tmp",
                    environment: ProcessInfo.processInfo.environment
                )
            )
            XCTFail("Pre-cancelled runner attempt unexpectedly succeeded")
        } catch let error as AgentExecutionError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOrchestratorHonorsCancellationBeforeProcessStarts() async {
        let orchestrator = TaskOrchestrator()
        let attemptID = UUID()
        let taskID = UUID()
        await orchestrator.cancel(taskID: taskID, attemptID: attemptID)

        let request = AgentExecutionRequest(
            attemptID: attemptID,
            taskID: taskID,
            agent: .antigravity,
            executablePath: "/usr/bin/false",
            repositoryPath: "/tmp",
            prompt: "Should never launch",
            configuration: [:],
            attachments: [],
            isGitRepository: false
        )

        do {
            _ = try await orchestrator.execute(request)
            XCTFail("Pre-cancelled attempt unexpectedly launched")
        } catch let error as AgentExecutionError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOrchestratorProducesTypedQuotaFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThirdHandQuotaFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("quota-fixture")
        try Data(
            "#!/bin/sh\nprintf 'RESOURCE_EXHAUSTED: quota exceeded\\n'\nexit 1\n".utf8
        ).write(to: executable)
        XCTAssertEqual(chmod(executable.path, 0o700), 0)

        let request = AgentExecutionRequest(
            attemptID: UUID(),
            taskID: UUID(),
            agent: .antigravity,
            executablePath: executable.path,
            repositoryPath: directory.path,
            prompt: "Inspect first",
            configuration: [:],
            attachments: [],
            isGitRepository: false
        )

        do {
            _ = try await TaskOrchestrator().execute(request)
            XCTFail("Quota fixture unexpectedly succeeded")
        } catch let error as AgentExecutionError {
            guard case let .usageLimitExceeded(agent, output) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(agent, .antigravity)
            XCTAssertTrue(output.lowercased().contains("quota exceeded"))
        }
    }

    func testLiveCodexRoundTripWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["THIRD_HAND_RUN_LIVE_AGENT_TEST"] == "1" else {
            throw XCTSkip("Set THIRD_HAND_RUN_LIVE_AGENT_TEST=1 to use one real Codex request")
        }

        let installations = await AgentDetector().detect()
        let installation = try XCTUnwrap(
            installations.first { $0.kind == .codex && $0.isAvailable }
        )
        let executablePath = try XCTUnwrap(installation.executablePath)
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThirdHandLiveAgent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }

        let attemptID = UUID()
        let request = AgentExecutionRequest(
            attemptID: attemptID,
            taskID: UUID(),
            agent: .codex,
            executablePath: executablePath,
            repositoryPath: repository.path,
            prompt: "Do not use tools or modify files. Reply with exactly THIRD_HAND_AGENT_OK.",
            configuration: [
                AgentOptionID.model.rawValue: "gpt-5.4-mini",
                AgentOptionID.reasoningEffort.rawValue: "low",
                AgentOptionID.speedTier.rawValue: "standard",
                AgentOptionID.sandboxMode.rawValue: "read-only",
                AgentOptionID.approvalPolicy.rawValue: "never"
            ],
            attachments: [],
            isGitRepository: false
        )

        let response = try await TaskOrchestrator().execute(request)
        XCTAssertTrue(response.text.contains("THIRD_HAND_AGENT_OK"))
    }
}
