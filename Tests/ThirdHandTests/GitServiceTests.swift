import Foundation
import XCTest
@testable import ThirdHand

final class GitServiceTests: XCTestCase {
    func testSnapshotReadsBranchAndChangedFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThirdHandGitTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.email", "third-hand@example.invalid"], at: root)
        try runGit(["config", "user.name", "Third Hand Tests"], at: root)

        let tracked = root.appendingPathComponent("README.md")
        try Data("# Fixture\n".utf8).write(to: tracked)
        try runGit(["add", "README.md"], at: root)
        try runGit(["commit", "-m", "Initial"], at: root)

        try Data("# Fixture\nChanged\n".utf8).write(to: tracked)
        try Data("new\n".utf8).write(to: root.appendingPathComponent("New.swift"))

        let snapshot = await GitService().snapshot(at: root)

        XCTAssertTrue(snapshot.isGitRepository)
        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertEqual(snapshot.changedFiles.count, 2)
        XCTAssertTrue(snapshot.changedFiles.contains { $0.path == "README.md" })
        XCTAssertTrue(snapshot.changedFiles.contains { $0.path == "New.swift" })
        XCTAssertEqual(snapshot.lineAdditions, 1)
        XCTAssertEqual(snapshot.lineDeletions, 0)
        XCTAssertEqual(
            snapshot.changedFiles.first(where: { $0.path == "README.md" })?.additions,
            1
        )
        XCTAssertNil(
            snapshot.changedFiles.first(where: { $0.path == "New.swift" })?.additions,
            "Untracked files are listed but are not invented into tracked diff line counts"
        )
        let firstFingerprint = try XCTUnwrap(snapshot.fingerprint)

        let untrackedDiff = await GitService().fileDiff(
            at: root,
            file: try XCTUnwrap(
                snapshot.changedFiles.first(where: { $0.path == "New.swift" })
            )
        )
        XCTAssertEqual(untrackedDiff.kind, .text)
        XCTAssertTrue(untrackedDiff.content.contains("+++ b/New.swift"))
        XCTAssertTrue(untrackedDiff.content.contains("+new"))

        try Data("changed untracked content\n".utf8).write(
            to: root.appendingPathComponent("New.swift")
        )
        let changedSnapshot = await GitService().snapshot(at: root)
        let changedFingerprint = try XCTUnwrap(changedSnapshot.fingerprint)
        XCTAssertNotEqual(firstFingerprint, changedFingerprint)

        let escapedDiff = await GitService().fileDiff(
            at: root,
            file: ChangedFile(status: "??", path: "../outside.txt")
        )
        XCTAssertEqual(escapedDiff.kind, .unavailable)
        XCTAssertTrue(escapedDiff.content.contains("за пределами"))

        let handoffContext = await GitService().handoffContext(at: root)
        XCTAssertTrue(handoffContext.isGitRepository)
        XCTAssertTrue(handoffContext.status.contains("README.md"))
        XCTAssertTrue(handoffContext.status.contains("New.swift"))
        XCTAssertTrue(handoffContext.diff.contains("Changed"))
        XCTAssertTrue(handoffContext.diffStat.contains("README.md"))
    }

    func testUnbornRepositoryDiffIncludesStagedAndLaterWorkingTreeEdits() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ThirdHandUnbornGitTest-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        let source = root.appendingPathComponent("Initial.swift")
        try Data("let first = 1\n".utf8).write(to: source)
        try runGit(["add", "Initial.swift"], at: root)
        try Data("let first = 1\nlet second = 2\n".utf8).write(to: source)

        let service = GitService()
        let snapshot = await service.snapshot(at: root)
        let handoff = await service.handoffContext(at: root)
        let file = try XCTUnwrap(
            snapshot.changedFiles.first(where: { $0.path == "Initial.swift" })
        )
        let fileDiff = await service.fileDiff(at: root, file: file)

        XCTAssertEqual(snapshot.head, "нет коммитов")
        XCTAssertEqual(file.additions, 2)
        XCTAssertTrue(handoff.diff.contains("+let second = 2"), handoff.diff)
        XCTAssertTrue(handoff.diffStat.contains("2 insertions"))
        XCTAssertTrue(fileDiff.content.contains("+let second = 2"))
    }

    func testUntrackedDiffRejectsAncestorSymlinkEscapeAfterSnapshot() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThirdHandGitSymlink-\(UUID().uuidString)", isDirectory: true)
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        let nested = repository.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        try runGit(["init", "-b", "main"], at: repository)
        try Data("ordinary repository content\n".utf8).write(
            to: nested.appendingPathComponent("context.txt")
        )
        let snapshot = await GitService().snapshot(at: repository)
        let staleFile = try XCTUnwrap(
            snapshot.changedFiles.first { $0.path == "nested/context.txt" }
        )

        try FileManager.default.removeItem(at: nested)
        try Data("OUTSIDE_SECRET_MUST_NOT_BE_READ\n".utf8).write(
            to: outside.appendingPathComponent("context.txt")
        )
        try FileManager.default.createSymbolicLink(
            at: nested,
            withDestinationURL: outside
        )

        let escapedDiff = await GitService().fileDiff(
            at: repository,
            file: staleFile
        )

        XCTAssertEqual(escapedDiff.kind, .unavailable)
        XCTAssertTrue(escapedDiff.content.contains("за пределами"))
        XCTAssertFalse(escapedDiff.content.contains("OUTSIDE_SECRET_MUST_NOT_BE_READ"))
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
