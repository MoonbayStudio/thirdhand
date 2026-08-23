import Foundation
import XCTest
@testable import ThirdHand

final class AgentProgressReportTests: XCTestCase {
    func testParserSeparatesDisplayTextFromStructuredProgress() throws {
        let response = """
        Реализация готова, тесты запущены.

        <<<THIRD_HAND_STATUS>>>
        {"decisions":["Use SQLite"],"progress":["Persistence implemented"],"knownIssues":["Migration needs review"],"nextStep":"Review the diff","completedSteps":["Реализовать следующий этап"]}
        <<<END_THIRD_HAND_STATUS>>>
        """

        let parsed = AgentProgressReportParser.parse(response)

        XCTAssertEqual(parsed.displayText, "Реализация готова, тесты запущены.")
        let report = try XCTUnwrap(parsed.progressReport)
        XCTAssertEqual(report.decisions, ["Use SQLite"])
        XCTAssertEqual(report.nextStep, "Review the diff")
        XCTAssertEqual(report.completedSteps, ["Реализовать следующий этап"])
    }

    func testMalformedProgressBlockRemainsVisibleAndDoesNotMutateState() {
        let response = """
        Ответ
        <<<THIRD_HAND_STATUS>>>
        not-json
        <<<END_THIRD_HAND_STATUS>>>
        """

        let parsed = AgentProgressReportParser.parse(response)

        XCTAssertNil(parsed.progressReport)
        XCTAssertTrue(parsed.displayText.contains("not-json"))
    }

    func testParserDoesNotHideTextAfterValidProgressBlock() throws {
        let response = """
        Основная работа завершена.
        <<<THIRD_HAND_STATUS>>>
        {"decisions":[],"progress":["Implemented"],"knownIssues":[],"nextStep":"Review","completedSteps":[]}
        <<<END_THIRD_HAND_STATUS>>>
        Важно: интеграционные тесты всё ещё падают.
        """

        let parsed = AgentProgressReportParser.parse(response)

        XCTAssertNotNil(parsed.progressReport)
        XCTAssertTrue(parsed.displayText.contains("Основная работа завершена."))
        XCTAssertTrue(
            parsed.displayText.contains("Важно: интеграционные тесты всё ещё падают."),
            "A valid machine-readable block must not hide a trailing user-facing warning"
        )
        XCTAssertFalse(parsed.displayText.contains(AgentProgressReportParser.openingMarker))
        XCTAssertFalse(parsed.displayText.contains(AgentProgressReportParser.closingMarker))
    }
}
