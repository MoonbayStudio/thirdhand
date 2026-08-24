import Foundation

actor TaskOrchestrator {
    private let runner = PTYProcessRunner()
    private var attemptByTask: [UUID: UUID] = [:]
    private var repositoryLeases: [String: UUID] = [:]
    private var cancelledBeforeStart: Set<UUID> = []

    func execute(
        _ request: AgentExecutionRequest,
        onOutput: @escaping @Sendable (AgentLiveOutput) async -> Void = { _ in }
    ) async throws -> AgentExecutionResponse {
        if cancelledBeforeStart.remove(request.attemptID) != nil {
            throw AgentExecutionError.cancelled
        }

        let repositoryKey = URL(fileURLWithPath: request.repositoryPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        guard attemptByTask[request.taskID] == nil,
              repositoryLeases[repositoryKey] == nil
        else {
            throw AgentExecutionError.repositoryBusy
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: request.repositoryPath,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw AgentExecutionError.launchFailed("Папка репозитория больше не существует.")
        }

        attemptByTask[request.taskID] = request.attemptID
        repositoryLeases[repositoryKey] = request.attemptID
        defer {
            if attemptByTask[request.taskID] == request.attemptID {
                attemptByTask[request.taskID] = nil
            }
            if repositoryLeases[repositoryKey] == request.attemptID {
                repositoryLeases[repositoryKey] = nil
            }
        }

        let resolved = resolveAttachments(in: request)
        defer {
            resolved.accessedSecurityScopedURLs.forEach {
                $0.stopAccessingSecurityScopedResource()
            }
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThirdHandAgentRuns", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let prepared = AgentCLIInvocationFactory.prepare(
            request: resolved.request,
            temporaryDirectory: temporaryDirectory
        )
        defer {
            if let responseFileURL = prepared.responseFileURL {
                try? FileManager.default.removeItem(at: responseFileURL)
            }
        }

        var processResult: PTYProcessResult?
        var liveData = Data()
        var liveOutputWasTruncated = false
        var lastEmission = ContinuousClock.now - .seconds(1)

        for try await event in runner.events(prepared.invocation) {
            switch event {
            case let .output(data, streamWasTruncated):
                liveData.append(data)
                if liveData.count > 32_768 {
                    liveData.removeFirst(liveData.count - 32_768)
                    liveOutputWasTruncated = true
                }
                liveOutputWasTruncated = liveOutputWasTruncated || streamWasTruncated

                let now = ContinuousClock.now
                guard now - lastEmission >= .milliseconds(50) else { continue }
                lastEmission = now
                await onOutput(
                    AgentLiveOutput(
                        text: AgentOutputParser.clean(
                            String(decoding: liveData, as: UTF8.self)
                        ),
                        wasTruncated: liveOutputWasTruncated,
                        updatedAt: .now
                    )
                )

            case let .finished(result):
                processResult = result
            }
        }

        guard let processResult else {
            throw AgentExecutionError.launchFailed(
                "PTY завершилась без финального результата."
            )
        }
        if !liveData.isEmpty {
            await onOutput(
                AgentLiveOutput(
                    text: AgentOutputParser.clean(
                        String(decoding: liveData, as: UTF8.self)
                    ),
                    wasTruncated: liveOutputWasTruncated,
                    updatedAt: .now
                )
            )
        }
        guard attemptByTask[request.taskID] == request.attemptID else {
            throw AgentExecutionError.cancelled
        }

        let diagnosticOutput = AgentOutputParser.clean(processResult.output)
        guard processResult.exitCode == 0 else {
            let limitedOutput = String(diagnosticOutput.suffix(2_400))
            if AgentFailureClassifier.category(for: limitedOutput) == .quotaExceeded {
                throw AgentExecutionError.usageLimitExceeded(
                    agent: request.agent,
                    output: limitedOutput
                )
            }
            throw AgentExecutionError.failed(
                exitCode: processResult.exitCode,
                output: limitedOutput
            )
        }

        let responseText = try AgentOutputParser.finalResponse(
            for: request.agent,
            terminalOutput: processResult.output,
            responseFileURL: prepared.responseFileURL
        )
        let parsedSessionID = AgentOutputParser.nativeSessionID(
            for: request.agent,
            terminalOutput: processResult.output
        )
        let nativeSessionID: String?
        switch request.nativeSession {
        case .disabled:
            nativeSessionID = nil
        case let .start(preferredID):
            nativeSessionID = parsedSessionID ?? preferredID
        case let .resume(sessionID):
            nativeSessionID = parsedSessionID ?? sessionID
        }
        return AgentExecutionResponse(
            text: responseText,
            exitCode: processResult.exitCode,
            nativeSessionID: nativeSessionID
        )
    }

    func cancel(taskID: UUID, attemptID: UUID) async {
        guard attemptByTask[taskID] == attemptID else {
            cancelledBeforeStart.insert(attemptID)
            return
        }
        runner.cancel(attemptID: attemptID)
    }

    func discardPendingCancellation(attemptID: UUID) {
        cancelledBeforeStart.remove(attemptID)
    }

    private func resolveAttachments(
        in request: AgentExecutionRequest
    ) -> (request: AgentExecutionRequest, accessedSecurityScopedURLs: [URL]) {
        var accessedURLs: [URL] = []
        let attachments = request.attachments.map { attachment in
            let resolvedURL = attachment.resolvedFileURL()
            if resolvedURL.startAccessingSecurityScopedResource() {
                accessedURLs.append(resolvedURL)
            }
            return TaskAttachment(
                id: attachment.id,
                fileName: attachment.fileName,
                filePath: resolvedURL.path,
                contentTypeIdentifier: attachment.contentTypeIdentifier,
                byteCount: attachment.byteCount,
                securityScopedBookmarkData: attachment.securityScopedBookmarkData,
                addedAt: attachment.addedAt
            )
        }

        return (
            AgentExecutionRequest(
                attemptID: request.attemptID,
                taskID: request.taskID,
                agent: request.agent,
                executablePath: request.executablePath,
                repositoryPath: request.repositoryPath,
                prompt: request.prompt,
                configuration: request.configuration,
                attachments: attachments,
                isGitRepository: request.isGitRepository,
                nativeSession: request.nativeSession
            ),
            accessedURLs
        )
    }
}

enum AgentOutputParser {
    static func nativeSessionID(
        for agent: AgentKind,
        terminalOutput: String
    ) -> String? {
        let cleanedOutput = clean(terminalOutput)
        switch agent {
        case .codex:
            for object in jsonObjects(from: cleanedOutput) {
                guard object["type"] as? String == "thread.started",
                      let threadID = object["thread_id"] as? String
                else {
                    continue
                }
                return normalizedSessionID(threadID)
            }
            return capturedSessionID(
                in: cleanedOutput,
                key: "thread_id"
            )

        case .claudeCode:
            for object in jsonObjects(from: cleanedOutput) {
                if let sessionID = object["session_id"] as? String,
                   let normalized = normalizedSessionID(sessionID) {
                    return normalized
                }
            }
            return capturedSessionID(
                in: cleanedOutput,
                key: "session_id"
            )

        case .antigravity, .deepSeek:
            return nil
        }
    }

    static func finalResponse(
        for agent: AgentKind,
        terminalOutput: String,
        responseFileURL: URL?
    ) throws -> String {
        if agent == .codex,
           let responseFileURL,
           let response = try? String(contentsOf: responseFileURL, encoding: .utf8),
           !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let cleanedOutput = clean(terminalOutput)
        if agent == .claudeCode, let result = claudeResult(from: cleanedOutput) {
            return result
        }

        let trimmed = cleanedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentExecutionError.emptyResponse }
        return trimmed
    }

    static func clean(_ value: String) -> String {
        var output = value
        output = output.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: "\u{001B}\\][^\u{0007}]*(?:\u{0007}|\u{001B}\\\\)",
            with: "",
            options: .regularExpression
        )
        output = output.replacingOccurrences(of: "\r\n", with: "\n")
        output = output.replacingOccurrences(of: "\r", with: "\n")
        return String(output.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || scalar.value >= 0x20
        })
    }

    private static func claudeResult(from output: String) -> String? {
        let candidates = [output] + output.split(separator: "\n").reversed().map(String.init)
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = object["result"] as? String,
                  !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func jsonObjects(from output: String) -> [[String: Any]] {
        let candidates = [output] + output.split(separator: "\n").map(String.init)
        return candidates.compactMap { candidate in
            guard let data = candidate.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    private static func capturedSessionID(in output: String, key: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        guard let expression = try? NSRegularExpression(
            pattern: #"\"\#(escapedKey)\"\s*:\s*\"([^\"]+)\""#
        ) else {
            return nil
        }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = expression.firstMatch(in: output, range: range),
              let valueRange = Range(match.range(at: 1), in: output)
        else {
            return nil
        }
        return normalizedSessionID(String(output[valueRange]))
    }

    private static func normalizedSessionID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
