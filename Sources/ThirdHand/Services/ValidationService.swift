import Foundation

struct ValidationExecutionResult: Sendable {
    let exitCode: Int32
    let output: String
    let duration: TimeInterval
}

enum ValidationExecutionError: LocalizedError, Sendable {
    case busy
    case timedOut
    case cancelled
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .busy:
            "Для этой задачи уже выполняется проверка."
        case .timedOut:
            "Проверка превысила допустимое время и была остановлена."
        case .cancelled:
            "Проверка остановлена пользователем."
        case let .launchFailed(message):
            "Не удалось запустить проверку: \(message)"
        }
    }
}

actor ValidationService {
    private let runner = PTYProcessRunner()
    private var attemptByTask: [UUID: UUID] = [:]
    private var cancelledBeforeStart: Set<UUID> = []

    func run(
        taskID: UUID,
        attemptID: UUID,
        recipe: ValidationRecipe,
        repositoryPath: String,
        onOutput: @escaping @Sendable (AgentLiveOutput) async -> Void
    ) async throws -> ValidationExecutionResult {
        if cancelledBeforeStart.remove(attemptID) != nil {
            throw ValidationExecutionError.cancelled
        }
        guard attemptByTask[taskID] == nil else {
            throw ValidationExecutionError.busy
        }
        attemptByTask[taskID] = attemptID
        defer {
            if attemptByTask[taskID] == attemptID {
                attemptByTask[taskID] = nil
            }
        }

        let runner = runner
        return try await withThrowingTaskGroup(
            of: ValidationExecutionResult.self
        ) { group in
            group.addTask {
                try await Self.execute(
                    runner: runner,
                    attemptID: attemptID,
                    recipe: recipe,
                    repositoryPath: repositoryPath,
                    onOutput: onOutput
                )
            }
            group.addTask {
                try await Task.sleep(
                    for: .seconds(recipe.timeoutSeconds)
                )
                _ = runner.cancel(attemptID: attemptID)
                throw ValidationExecutionError.timedOut
            }

            guard let first = try await group.next() else {
                throw ValidationExecutionError.launchFailed(
                    "Процесс завершился без результата."
                )
            }
            group.cancelAll()
            return first
        }
    }

    func cancel(taskID: UUID, attemptID: UUID) {
        guard attemptByTask[taskID] == attemptID else {
            cancelledBeforeStart.insert(attemptID)
            return
        }
        _ = runner.cancel(attemptID: attemptID)
    }

    func discardPendingCancellation(attemptID: UUID) {
        cancelledBeforeStart.remove(attemptID)
    }

    private static func execute(
        runner: PTYProcessRunner,
        attemptID: UUID,
        recipe: ValidationRecipe,
        repositoryPath: String,
        onOutput: @escaping @Sendable (AgentLiveOutput) async -> Void
    ) async throws -> ValidationExecutionResult {
        var environment = ExecutableResolver.environment(
            forExecutablePath: recipe.executablePath
        )
        environment["TERM"] = "xterm-256color"
        environment["NO_COLOR"] = "1"
        environment["CLICOLOR"] = "0"

        let invocation = AgentCLIInvocation(
            attemptID: attemptID,
            executablePath: recipe.executablePath,
            arguments: recipe.arguments,
            workingDirectory: repositoryPath,
            environment: environment
        )
        let clock = ContinuousClock()
        let startedAt = clock.now
        var finalResult: PTYProcessResult?
        var liveData = Data()
        var wasTruncated = false
        var lastEmission = ContinuousClock.now - .seconds(1)

        do {
            for try await event in runner.events(invocation) {
                switch event {
                case let .output(data, streamWasTruncated):
                    liveData.append(data)
                    if liveData.count > 65_536 {
                        liveData.removeFirst(liveData.count - 65_536)
                        wasTruncated = true
                    }
                    wasTruncated = wasTruncated || streamWasTruncated

                    let now = ContinuousClock.now
                    guard now - lastEmission >= .milliseconds(100) else { continue }
                    lastEmission = now
                    await onOutput(
                        AgentLiveOutput(
                            text: AgentOutputParser.clean(
                                String(decoding: liveData, as: UTF8.self)
                            ),
                            wasTruncated: wasTruncated,
                            updatedAt: .now
                        )
                    )

                case let .finished(result):
                    finalResult = result
                }
            }
        } catch let error as AgentExecutionError {
            if case .cancelled = error {
                throw ValidationExecutionError.cancelled
            }
            throw ValidationExecutionError.launchFailed(
                error.errorDescription ?? error.localizedDescription
            )
        } catch {
            throw ValidationExecutionError.launchFailed(
                error.localizedDescription
            )
        }

        guard let finalResult else {
            throw ValidationExecutionError.launchFailed(
                "PTY завершилась без результата."
            )
        }
        if !liveData.isEmpty {
            await onOutput(
                AgentLiveOutput(
                    text: AgentOutputParser.clean(
                        String(decoding: liveData, as: UTF8.self)
                    ),
                    wasTruncated: wasTruncated,
                    updatedAt: .now
                )
            )
        }

        let durationComponents = startedAt.duration(to: clock.now).components
        let duration = Double(durationComponents.seconds)
            + Double(durationComponents.attoseconds) / 1_000_000_000_000_000_000
        return ValidationExecutionResult(
            exitCode: finalResult.exitCode,
            output: AgentOutputParser.clean(finalResult.output),
            duration: max(duration, 0)
        )
    }
}
