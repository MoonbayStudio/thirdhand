import Darwin
import Foundation
import XCTest
@testable import ThirdHand

final class ValidationAndNotificationTests: XCTestCase {
    func testDetectorFindsSwiftPMBuildAndTests() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("// swift-tools-version: 6.1\n".utf8).write(
            to: root.appendingPathComponent("Package.swift")
        )

        let recipes = await ValidationRecipeDetector().detect(at: root)

        XCTAssertTrue(recipes.contains {
            $0.kind == .build
                && $0.executablePath == "/usr/bin/xcrun"
                && $0.arguments == ["swift", "build"]
        })
        XCTAssertTrue(recipes.contains {
            $0.kind == .test
                && $0.arguments == ["swift", "test"]
        })
    }

    func testValidationTimeoutStopsLongRunningProcess() async {
        let service = ValidationService()
        let recipe = ValidationRecipe(
            kind: .test,
            name: "Timeout fixture",
            executablePath: "/bin/sleep",
            arguments: ["10"],
            timeoutSeconds: 1
        )
        let startedAt = ContinuousClock.now

        do {
            _ = try await service.run(
                taskID: UUID(),
                attemptID: UUID(),
                recipe: recipe,
                repositoryPath: "/tmp",
                onOutput: { _ in }
            )
            XCTFail("Timed-out validation unexpectedly succeeded")
        } catch let error as ValidationExecutionError {
            guard case .timedOut = error else {
                return XCTFail("Unexpected validation error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(4))
    }

    func testValidationTimeoutReleasesTaskWhenDetachedDescendantKeepsPTYOpen() async throws {
        let root = try makeRepository()
        let descendantPIDFile = root.appendingPathComponent("detached-descendant.pid")
        func terminateDetachedDescendant(
            waitingUpTo timeout: Duration
        ) -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)

            repeat {
                if let pidText = try? String(
                    contentsOf: descendantPIDFile,
                    encoding: .utf8
                ).trimmingCharacters(in: .whitespacesAndNewlines),
                   let pid = Int32(pidText) {
                    return Darwin.kill(pid, SIGKILL) == 0 || errno == ESRCH
                }
                usleep(10_000)
            } while clock.now < deadline

            return false
        }
        defer {
            _ = terminateDetachedDescendant(waitingUpTo: .milliseconds(250))
            try? FileManager.default.removeItem(at: root)
        }

        let service = ValidationService()
        let taskID = UUID()
        let detachedRecipe = ValidationRecipe(
            kind: .test,
            name: "Detached PTY holder",
            executablePath: "/usr/bin/python3",
            arguments: [
                "-c",
                """
                import os
                import time

                ready_read, ready_write = os.pipe()
                child = os.fork()
                if child == 0:
                    os.close(ready_read)
                    os.setsid()
                    with open(r"\(descendantPIDFile.path)", "w") as handle:
                        handle.write(str(os.getpid()))
                    os.write(ready_write, b"ready")
                    os.close(ready_write)
                    time.sleep(30)
                    os._exit(0)

                os.close(ready_write)
                os.read(ready_read, 5)
                os.close(ready_read)
                time.sleep(30)
                """
            ],
            timeoutSeconds: 1
        )
        let startedAt = ContinuousClock.now

        do {
            _ = try await service.run(
                taskID: taskID,
                attemptID: UUID(),
                recipe: detachedRecipe,
                repositoryPath: root.path,
                onOutput: { _ in }
            )
            XCTFail("Detached descendant fixture unexpectedly succeeded")
        } catch let error as ValidationExecutionError {
            guard case .timedOut = error else {
                return XCTFail("Unexpected validation error: \(error)")
            }
        }

        XCTAssertLessThan(
            ContinuousClock.now - startedAt,
            .seconds(4),
            "A detached descendant kept the PTY and validation lease alive"
        )

        XCTAssertTrue(
            terminateDetachedDescendant(waitingUpTo: .seconds(1)),
            "The detached fixture must be terminated during test cleanup"
        )

        let followUpRecipe = ValidationRecipe(
            kind: .test,
            name: "Follow-up after timeout",
            executablePath: "/usr/bin/printf",
            arguments: ["FOLLOW_UP_VALIDATION_OK"],
            timeoutSeconds: 5
        )
        let followUp = try await service.run(
            taskID: taskID,
            attemptID: UUID(),
            recipe: followUpRecipe,
            repositoryPath: root.path,
            onOutput: { _ in }
        )

        XCTAssertEqual(followUp.exitCode, 0)
        XCTAssertTrue(followUp.output.contains("FOLLOW_UP_VALIDATION_OK"))
    }

    @MainActor
    func testStoreRunsRealValidationAndRecordsFreshResult() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThirdHandValidationState-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        defer {
            try? FileManager.default.removeItem(
                at: stateURL.appendingPathExtension("backup")
            )
        }
        let recipe = ValidationRecipe(
            kind: .test,
            name: "Fixture Validation",
            executablePath: "/usr/bin/printf",
            arguments: ["VALIDATION_OK"]
        )
        let task = CodingTask(
            title: "Validation",
            originalRequest: "Run checks",
            repositoryPath: root.path,
            validationRecipes: [recipe],
            validations: [
                ValidationRun(name: recipe.name, recipeID: recipe.id)
            ]
        )
        let notifications = RecordingNotificationService()
        let store = AppStore(
            persistence: PersistenceService(stateURL: stateURL),
            performAgentDiscovery: false,
            notificationService: notifications
        )
        store.tasks = [task]

        let passed = await store.runValidation(
            taskID: task.id,
            recipeID: recipe.id
        )

        XCTAssertTrue(passed)
        let updated = try XCTUnwrap(store.tasks.first)
        let run = try XCTUnwrap(updated.validations.first)
        XCTAssertEqual(run.outcome, .passed)
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertTrue(run.output?.contains("VALIDATION_OK") == true)
        XCTAssertTrue(run.isFresh(for: updated.gitSnapshot))
        XCTAssertNil(store.activeValidations[task.id])
    }

    @MainActor
    func testTaskCompletionPostsNotificationThroughInjectedService() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let notifications = RecordingNotificationService()
        let task = CodingTask(
            title: "Notify",
            originalRequest: "Finish",
            repositoryPath: root.path,
            steps: [TaskStep(title: "Only step")]
        )
        let store = AppStore(
            persistence: PersistenceService(
                stateURL: root.appendingPathComponent("state.json")
            ),
            performAgentDiscovery: false,
            notificationService: notifications
        )
        store.tasks = [task]

        store.toggleStep(taskID: task.id, stepID: task.steps[0].id)
        for _ in 0..<50 {
            if await notifications.recordedEvents().count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let events = await notifications.recordedEvents()
        XCTAssertEqual(events.map(\.kind), [.taskCompleted])
        XCTAssertEqual(events.first?.taskID, task.id)
    }

    private func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThirdHandValidation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "init", "-b", "main"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return root
    }
}

private actor RecordingNotificationService: TaskNotificationSending {
    private var events: [TaskNotificationEvent] = []
    private var removedTaskIDs: [UUID] = []

    func requestAuthorization() async -> Bool {
        true
    }

    func post(_ event: TaskNotificationEvent) async {
        events.append(event)
    }

    func removeNotifications(taskID: UUID) async {
        removedTaskIDs.append(taskID)
    }

    func recordedEvents() -> [TaskNotificationEvent] {
        events
    }
}
