import XCTest
@testable import ThirdHand

final class AutomaticAgentRouterTests: XCTestCase {
    func testAutomaticModeUsesPreferredOrderAndAvailableInstallationsOnly() {
        let candidates = AutomaticAgentRouter.candidates(
            routingMode: .automatic,
            currentAgent: .codex,
            installations: [
                installation(.codex, available: true),
                installation(.claudeCode, available: false),
                installation(.antigravity, available: true)
            ],
            preferredOrder: [.antigravity, .claudeCode, .codex],
            usageSnapshots: [:]
        )

        XCTAssertEqual(candidates, [.antigravity, .codex])
    }

    func testAutomaticModeRemovesDuplicatesAndAppendsMissingProvidersOnce() {
        let candidates = AutomaticAgentRouter.candidates(
            routingMode: .automatic,
            currentAgent: nil,
            installations: AgentKind.allCases.map { installation($0, available: true) },
            preferredOrder: [.claudeCode, .claudeCode],
            usageSnapshots: [:]
        )

        XCTAssertEqual(candidates, [.claudeCode, .codex, .antigravity])
        XCTAssertEqual(Set(candidates).count, candidates.count)
    }

    func testAutomaticModeSkipsExhaustedButKeepsUnknownUsageEligible() {
        let candidates = AutomaticAgentRouter.candidates(
            routingMode: .automatic,
            currentAgent: .codex,
            installations: AgentKind.allCases.map { installation($0, available: true) },
            preferredOrder: [.codex, .claudeCode, .antigravity],
            usageSnapshots: [
                .codex: .exhausted(for: .codex, detail: "Лимит исчерпан"),
                .claudeCode: .unknown(for: .claudeCode)
            ]
        )

        XCTAssertEqual(candidates, [.claudeCode, .antigravity])
    }

    func testAutomaticModeReturnsEmptyWhenEveryAvailableProviderIsExhausted() {
        let usage = Dictionary(
            uniqueKeysWithValues: AgentKind.allCases.map { agent in
                (agent, ProviderUsageSnapshot.exhausted(for: agent, detail: "Лимит исчерпан"))
            }
        )

        let candidates = AutomaticAgentRouter.candidates(
            routingMode: .automatic,
            currentAgent: .codex,
            installations: AgentKind.allCases.map { installation($0, available: true) },
            preferredOrder: AgentKind.allCases,
            usageSnapshots: usage
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    func testAutomaticModeRetriesInferredExhaustionAfterCooldown() {
        var expired = ProviderUsageSnapshot.exhausted(
            for: .claudeCode,
            detail: "Лимит исчерпан"
        )
        expired.updatedAt = Date(timeIntervalSince1970: 0)

        let candidates = AutomaticAgentRouter.candidates(
            routingMode: .automatic,
            currentAgent: .codex,
            installations: [installation(.claudeCode, available: true)],
            preferredOrder: [.claudeCode],
            usageSnapshots: [.claudeCode: expired],
            now: Date(timeIntervalSince1970: 10_000)
        )

        XCTAssertEqual(candidates, [.claudeCode])
    }

    func testAutomaticModeReenablesOfficialLimitAfterResetDate() {
        let resetDate = Date(timeIntervalSince1970: 1_000)
        let snapshot = ProviderUsageSnapshot(
            agent: .codex,
            state: .exhausted,
            windows: [
                ProviderUsageWindow(
                    id: "primary",
                    title: "5 ч.",
                    remainingFraction: 0,
                    resetsAt: resetDate
                )
            ],
            detail: "Лимит исчерпан",
            updatedAt: Date(timeIntervalSince1970: 500),
            source: .officialCLI
        )

        let beforeReset = AutomaticAgentRouter.candidates(
            routingMode: .automatic,
            currentAgent: .codex,
            installations: [installation(.codex, available: true)],
            preferredOrder: [.codex],
            usageSnapshots: [.codex: snapshot],
            now: Date(timeIntervalSince1970: 999)
        )
        let afterReset = AutomaticAgentRouter.candidates(
            routingMode: .automatic,
            currentAgent: .codex,
            installations: [installation(.codex, available: true)],
            preferredOrder: [.codex],
            usageSnapshots: [.codex: snapshot],
            now: resetDate
        )

        XCTAssertTrue(beforeReset.isEmpty)
        XCTAssertEqual(afterReset, [.codex])
    }

    func testAutomaticModeSkipsOnlySelectedAntigravityModelGroupAtZero() {
        let usage = ProviderUsageSnapshot(
            agent: .antigravity,
            state: .available,
            windows: [
                ProviderUsageWindow(
                    id: "gemini-weekly",
                    title: "7 дн.",
                    remainingFraction: 0
                ),
                ProviderUsageWindow(
                    id: "gemini-five-hour",
                    title: "5 ч.",
                    remainingFraction: 0.5
                ),
                ProviderUsageWindow(
                    id: "claude-gpt-weekly",
                    title: "7 дн.",
                    remainingFraction: 0.8
                ),
                ProviderUsageWindow(
                    id: "claude-gpt-five-hour",
                    title: "5 ч.",
                    remainingFraction: 0.7
                )
            ],
            detail: "fixture",
            updatedAt: .now,
            source: .officialCLI
        )
        let installations = [
            installation(.antigravity, available: true),
            installation(.codex, available: true)
        ]

        let geminiTask = CodingTask(
            title: "Gemini",
            originalRequest: "",
            repositoryPath: "/tmp",
            routingMode: .automatic,
            agentConfiguration: TaskAgentConfiguration(
                values: [AgentOptionID.model.rawValue: "Gemini 3.1 Pro (High)"]
            )
        )
        let claudeTask = CodingTask(
            title: "Claude",
            originalRequest: "",
            repositoryPath: "/tmp",
            routingMode: .automatic,
            agentConfiguration: TaskAgentConfiguration(
                values: [AgentOptionID.model.rawValue: "Claude Sonnet 4.6 (Thinking)"]
            )
        )
        let unspecifiedTask = CodingTask(
            title: "Default",
            originalRequest: "",
            repositoryPath: "/tmp",
            routingMode: .automatic
        )

        XCTAssertEqual(
            AutomaticAgentRouter.candidates(
                for: geminiTask,
                installations: installations,
                preferredOrder: [.antigravity, .codex],
                usageSnapshots: [.antigravity: usage]
            ),
            [.codex]
        )
        XCTAssertEqual(
            AutomaticAgentRouter.candidates(
                for: claudeTask,
                installations: installations,
                preferredOrder: [.antigravity, .codex],
                usageSnapshots: [.antigravity: usage]
            ),
            [.antigravity, .codex]
        )
        XCTAssertEqual(
            AutomaticAgentRouter.candidates(
                for: unspecifiedTask,
                installations: installations,
                preferredOrder: [.antigravity, .codex],
                usageSnapshots: [.antigravity: usage]
            ),
            [.codex],
            "An unspecified Antigravity default must be conservative across both quota groups"
        )
    }

    func testManualModeUsesOnlyCurrentAgent() {
        let candidates = AutomaticAgentRouter.candidates(
            routingMode: .manual,
            currentAgent: .claudeCode,
            installations: AgentKind.allCases.map { installation($0, available: true) },
            preferredOrder: [.antigravity, .codex, .claudeCode],
            usageSnapshots: [
                .claudeCode: .exhausted(for: .claudeCode, detail: "Лимит исчерпан")
            ]
        )

        XCTAssertEqual(candidates, [.claudeCode])
    }

    func testManualModeWithoutCurrentAgentUsesFirstAvailablePreferredAgent() {
        let candidates = AutomaticAgentRouter.candidates(
            routingMode: .manual,
            currentAgent: nil,
            installations: [
                installation(.antigravity, available: true),
                installation(.codex, available: true)
            ],
            preferredOrder: [.claudeCode, .codex, .antigravity],
            usageSnapshots: [:]
        )

        XCTAssertEqual(candidates, [.codex])
    }

    private func installation(
        _ kind: AgentKind,
        available: Bool
    ) -> AgentInstallation {
        AgentInstallation(
            kind: kind,
            executablePath: available ? "/usr/bin/true" : nil
        )
    }
}
