import Foundation
import XCTest
@testable import ThirdHand

final class PersistenceServiceTests: XCTestCase {
    func testSaveCreatesBackupAndCorruptStateRecoversFromIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThirdHandPersistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = root.appendingPathComponent("state.json")
        let service = PersistenceService(stateURL: stateURL)
        let first = CodingTask(
            title: "First",
            originalRequest: "Request",
            repositoryPath: "/tmp/repository"
        )
        let second = CodingTask(
            title: "Second",
            originalRequest: "Request",
            repositoryPath: "/tmp/repository"
        )

        try service.saveTasks([first])
        try service.saveTasks([first, second])
        try Data("not-json".utf8).write(to: stateURL)

        let recovered = service.loadTasks()

        XCTAssertTrue(recovered.allowsWrites)
        XCTAssertNotNil(recovered.warning)
        XCTAssertEqual(recovered.tasks.map(\.id), [first.id])
        let archivedCorruptFiles = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("state.json.corrupt-") }
        XCTAssertEqual(archivedCorruptFiles.count, 1)

        let reloaded = service.loadTasks()
        XCTAssertNil(reloaded.warning)
        XCTAssertEqual(reloaded.tasks.map(\.id), [first.id])
    }

    func testCorruptStateWithoutBackupBlocksWrites() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThirdHandPersistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = root.appendingPathComponent("state.json")
        try Data("broken".utf8).write(to: stateURL)
        let loaded = PersistenceService(stateURL: stateURL).loadTasks()

        XCTAssertTrue(loaded.tasks.isEmpty)
        XCTAssertFalse(loaded.allowsWrites)
        XCTAssertNotNil(loaded.warning)
    }
}
