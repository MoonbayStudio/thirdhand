import Foundation
import XCTest
@testable import ThirdHand

final class AgentActivityClassifierTests: XCTestCase {
    func testConversationRunHidesDetailedActivityWhileProjectRunKeepsIt() {
        let conversation = AgentRunState(
            attemptID: UUID(),
            agent: .codex,
            interactionMode: .conversation,
            phase: .running,
            startedAt: .now
        )

        XCTAssertFalse(conversation.presentsDetailedActivity)
        XCTAssertTrue(run(phase: .running).presentsDetailedActivity)
    }

    func testPhaseOverridesOutputClassification() {
        let output = AgentLiveOutput(
            text: "apply_patch Sources/App.swift",
            wasTruncated: false,
            updatedAt: .now
        )

        XCTAssertEqual(
            AgentActivityClassifier.presentation(
                for: run(phase: .preparing),
                output: output
            ).current,
            .preparing
        )
        XCTAssertEqual(
            AgentActivityClassifier.presentation(
                for: run(phase: .stopping),
                output: output
            ).current,
            .stopping
        )
        XCTAssertEqual(
            AgentActivityClassifier.presentation(
                for: run(phase: .compressingContext),
                output: output
            ).current,
            .compressingContext
        )
    }

    func testRunningWithoutOutputUsesHonestGenericState() {
        let presentation = AgentActivityClassifier.presentation(
            for: run(phase: .running),
            output: .empty
        )

        XCTAssertEqual(presentation.current, .working)
        XCTAssertEqual(presentation.recent, [.working])
        XCTAssertNil(presentation.lastEventAt)
    }

    func testRecentActivityUsesActualOutputOrder() {
        let output = AgentLiveOutput(
            text: """
            analysis Planning the change
            exec_command rg AgentRunState Sources
            read_file Sources/App.swift
            search_query SwiftUI agent activity patterns
            apply_patch Sources/App.swift
            swift test --filter AgentActivityClassifierTests
            """,
            wasTruncated: false,
            updatedAt: .now
        )

        let presentation = AgentActivityClassifier.presentation(
            for: run(phase: .running),
            output: output
        )

        XCTAssertEqual(presentation.current, .verifying)
        XCTAssertEqual(
            presentation.recent,
            [.readingFiles, .readingSources, .editing, .verifying]
        )
        XCTAssertNotNil(presentation.lastEventAt)
    }

    func testRecognizesCompactCodexEventNames() {
        let output = AgentLiveOutput(
            text: """
            analysis
            Проверяю рабочую папку.
            exec
            /bin/zsh -lc pwd
            """,
            wasTruncated: false,
            updatedAt: .now
        )

        let presentation = AgentActivityClassifier.presentation(
            for: run(phase: .running),
            output: output
        )

        XCTAssertEqual(presentation.current, .runningCommand)
        XCTAssertEqual(presentation.recent, [.analyzing, .runningCommand])
    }

    func testCodexResponseEventBecomesAnswerStage() {
        let output = AgentLiveOutput(
            text: "analysis\nexec\ncodex\nГотово.",
            wasTruncated: false,
            updatedAt: .now
        )

        let presentation = AgentActivityClassifier.presentation(
            for: run(phase: .running),
            output: output
        )

        XCTAssertEqual(presentation.current, .responding)
        XCTAssertEqual(
            presentation.recent,
            [.analyzing, .runningCommand, .responding]
        )
    }

    private func run(phase: AgentRunPhase) -> AgentRunState {
        AgentRunState(
            attemptID: UUID(),
            agent: .codex,
            interactionMode: .workspace,
            phase: phase,
            startedAt: .now
        )
    }
}
