import Foundation
import XCTest
@testable import ThirdHand

final class AntigravityUsageParserTests: XCTestCase {
    func testParserReadsBothModelGroupsAndTheirWindows() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try XCTUnwrap(
            AntigravityUsageParser.parse(
                """
                └ Models & Quota

                  Account: person@example.com

                GEMINI MODELS
                  Models within this group: Gemini Flash, Gemini Pro

                  Weekly Limit
                [██████████████████████████████████████████████████] 99.97%
                    100% remaining · Refreshes in 167h 54m

                  Five Hour Limit
                [██████████████████████████████████████████████████] 99.83%
                    100% remaining · Refreshes in 4h 54m

                CLAUDE AND GPT MODELS
                  Models within this group: Claude Opus, Claude Sonnet, GPT-OSS

                  Weekly Limit
                [██████████████████████████████████████████████████] 74.50%
                    75% remaining · Refreshes in 120h

                  Five Hour Limit
                [██████████████████████████████████████████████████] 40.00%
                    40% remaining · Refreshes in 3h 5m
                """,
                now: now
            )
        )

        XCTAssertEqual(snapshot.agent, .antigravity)
        XCTAssertEqual(snapshot.state, .available)
        XCTAssertEqual(snapshot.updatedAt, now)
        XCTAssertEqual(snapshot.source, .officialCLI)
        XCTAssertEqual(snapshot.windows.count, 4)

        let byID = Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.id, $0) })
        XCTAssertEqual(
            try XCTUnwrap(byID["gemini-weekly"]).remainingFraction,
            0.9997,
            accuracy: 0.0001,
            "The progress bar carries the precise value; the prose is rounded for display"
        )
        XCTAssertEqual(
            try XCTUnwrap(byID["gemini-five-hour"]).remainingFraction,
            0.9983,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(byID["claude-gpt-weekly"]).remainingFraction,
            0.745,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(byID["claude-gpt-five-hour"]).remainingFraction,
            0.4,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(byID["gemini-weekly"]).resetsAt,
            now.addingTimeInterval((167 * 60 + 54) * 60)
        )
        XCTAssertEqual(
            try XCTUnwrap(byID["claude-gpt-five-hour"]).resetsAt,
            now.addingTimeInterval((3 * 60 + 5) * 60)
        )
    }

    func testParserHandlesQuotaAvailableAndTerminalEscapeSequences() throws {
        let snapshot = try XCTUnwrap(
            AntigravityUsageParser.parse(
                """
                \u{001B}[13A└ Models & Quota\u{001B}[K\r
                GEMINI MODELS\u{001B}[K\r
                  Weekly Limit\u{001B}[K\r
                \u{001B}[10D[████] 100.00%\u{001B}[K\r
                    Quota available\u{001B}[K\r
                  Five Hour Limit\u{001B}[K\r
                \u{001B}[13D[████] 100.00%\u{001B}[K\r
                    Quota available\u{001B}[K\r
                \u{001B}[?25h
                """
            )
        )

        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.remainingFraction == 1 })
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.resetsAt == nil })
    }

    func testParserRejectsHelpAndOrdinaryChatOutput() {
        XCTAssertNil(
            AntigravityUsageParser.parse(
                """
                /usage               View model quota usage
                Ordinary agent answer containing the word limit.
                """
            )
        )
    }

    func testTerminalRendererAppliesCursorPatchesInsteadOfKeepingStaleText() {
        let screen = TerminalScreenRenderer.render(
            "stale value\r\u{001B}[2Kfresh value",
            rows: 6,
            columns: 40
        )

        XCTAssertTrue(screen.contains("fresh value"), screen)
        XCTAssertFalse(screen.contains("stale value"), screen)
    }
}
