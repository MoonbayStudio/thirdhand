import Foundation
import XCTest
@testable import ThirdHand

final class ProviderUsageServiceTests: XCTestCase {
    func testParserReadsPrimaryAndSecondaryWindows() throws {
        let reset = 1_785_338_129
        let snapshot = try XCTUnwrap(
            CodexRateLimitParser.parseResponseLine(
                responseData(
                    primary: [
                        "usedPercent": 60,
                        "windowDurationMins": 10_080,
                        "resetsAt": reset
                    ],
                    secondary: [
                        "usedPercent": 25,
                        "windowDurationMins": 300,
                        "resetsAt": reset + 60
                    ]
                ),
                now: Date(timeIntervalSince1970: 100)
            )
        )

        XCTAssertEqual(snapshot.agent, .codex)
        XCTAssertEqual(snapshot.state, .available)
        XCTAssertEqual(snapshot.updatedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].id, "primary")
        XCTAssertEqual(snapshot.windows[0].title, "7 дн.")
        XCTAssertEqual(snapshot.windows[0].remainingFraction, 0.4, accuracy: 0.0001)
        XCTAssertEqual(
            snapshot.windows[0].resetsAt,
            Date(timeIntervalSince1970: TimeInterval(reset))
        )
        XCTAssertEqual(snapshot.windows[1].id, "secondary")
        XCTAssertEqual(snapshot.windows[1].title, "5 ч.")
        XCTAssertEqual(snapshot.windows[1].remainingFraction, 0.75, accuracy: 0.0001)
    }

    func testParserClampsUsedPercentOutsideExpectedRange() throws {
        let snapshot = try XCTUnwrap(
            CodexRateLimitParser.parseResponseLine(
                responseData(
                    primary: ["usedPercent": -20],
                    secondary: ["usedPercent": 130]
                )
            )
        )

        XCTAssertEqual(snapshot.windows[0].remainingFraction, 1, accuracy: 0.0001)
        XCTAssertEqual(snapshot.windows[1].remainingFraction, 0, accuracy: 0.0001)
        XCTAssertEqual(
            snapshot.state,
            .available,
            "0% is display data; Auto blocks only after an explicit reached type or run failure"
        )
    }

    func testParserUsesRateLimitReachedTypeAsExhaustionSignal() throws {
        let snapshot = try XCTUnwrap(
            CodexRateLimitParser.parseResponseLine(
                responseData(
                    primary: ["usedPercent": 35],
                    rateLimitReachedType: "workspace_member_usage_limit_reached"
                )
            )
        )

        XCTAssertEqual(snapshot.state, .exhausted)
        XCTAssertEqual(
            try XCTUnwrap(snapshot.windows.first).remainingFraction,
            0.65,
            accuracy: 0.0001
        )
        XCTAssertTrue(snapshot.detail.contains("workspace_member_usage_limit_reached"))
    }

    func testParserPrefersCodexBucketFromMultiBucketResponse() throws {
        let object: [String: Any] = [
            "id": 2,
            "result": [
                "rateLimits": ["primary": ["usedPercent": 99]],
                "rateLimitsByLimitId": [
                    "other": ["primary": ["usedPercent": 90]],
                    "codex": ["primary": ["usedPercent": 10]]
                ]
            ]
        ]
        let snapshot = try XCTUnwrap(
            CodexRateLimitParser.parseResponseLine(
                try JSONSerialization.data(withJSONObject: object)
            )
        )

        XCTAssertEqual(
            try XCTUnwrap(snapshot.windows.first).remainingFraction,
            0.9,
            accuracy: 0.0001
        )
    }

    func testParserFallsBackWhenCodexBucketIsEmpty() throws {
        let object: [String: Any] = [
            "id": 2,
            "result": [
                "rateLimits": ["primary": ["usedPercent": 40]],
                "rateLimitsByLimitId": ["codex": [:]]
            ]
        ]
        let snapshot = try XCTUnwrap(
            CodexRateLimitParser.parseResponseLine(
                try JSONSerialization.data(withJSONObject: object)
            )
        )

        XCTAssertEqual(
            try XCTUnwrap(snapshot.windows.first).remainingFraction,
            0.6,
            accuracy: 0.0001
        )
    }

    func testUnavailableProviderResponsesRemainUnknown() async {
        let service = ProviderUsageService(timeout: 0.1)
        let snapshots = await service.snapshots(
            for: [
                AgentInstallation(kind: .claudeCode, executablePath: "/usr/bin/true"),
                AgentInstallation(kind: .antigravity, executablePath: "/usr/bin/true")
            ]
        )

        XCTAssertEqual(snapshots[.claudeCode]?.state, .unknown)
        XCTAssertEqual(snapshots[.antigravity]?.state, .unknown)
        XCTAssertTrue(snapshots[.claudeCode]?.windows.isEmpty == true)
        XCTAssertTrue(snapshots[.antigravity]?.windows.isEmpty == true)
    }

    func testAntigravityProbeReadsUsageFromSafeInteractivePrompt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThirdHandUsage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = try makeExecutable(
            in: directory,
            contents: """
            #!/bin/sh
            printf '\\033[?1049h\\033[2J\\033[H'
            printf 'Antigravity CLI 1.1.5\\r\\n'
            printf '> \\r\\n'
            printf '? for shortcuts\\r\\n'
            IFS= read -r command
            [ "$command" = "/usage" ] || exit 9
            printf '\\033[2J\\033[H'
            printf '└ Models & Quota\\r\\n'
            printf 'GEMINI MODELS\\r\\n'
            printf 'Weekly Limit\\r\\n'
            printf '[████] 62.50%%\\r\\n'
            printf '63%% remaining · Refreshes in 12h 30m\\r\\n'
            printf 'Five Hour Limit\\r\\n'
            printf '[████] 40.00%%\\r\\n'
            printf '40%% remaining · Refreshes in 2h\\r\\n'
            printf 'CLAUDE AND GPT MODELS\\r\\n'
            printf 'Weekly Limit\\r\\n'
            printf '[████] 80.00%%\\r\\n'
            printf '80%% remaining · Refreshes in 24h\\r\\n'
            printf 'Five Hour Limit\\r\\n'
            printf '[████] 70.00%%\\r\\n'
            printf '70%% remaining · Refreshes in 3h\\r\\n'
            printf 'esc Close\\r\\n'
            sleep 5
            """
        )

        let snapshot = await ProviderUsageService(timeout: 2).snapshot(
            for: AgentInstallation(
                kind: .antigravity,
                executablePath: executable.path
            )
        )

        XCTAssertEqual(snapshot.state, .available, snapshot.detail)
        XCTAssertEqual(snapshot.source, .officialCLI)
        XCTAssertEqual(
            snapshot.windows.count,
            4,
            snapshot.windows.map(\.id).joined(separator: ", ")
        )
        XCTAssertEqual(snapshot.windows[0].remainingFraction, 0.625, accuracy: 0.0001)
        XCTAssertEqual(snapshot.windows[1].remainingFraction, 0.4, accuracy: 0.0001)
    }

    func testAntigravityProbeNeverAnswersTrustPrompt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThirdHandTrust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("unexpected-input")
        let executable = try makeExecutable(
            in: directory,
            contents: """
            #!/bin/sh
            printf 'Do you trust this folder?\\r\\n'
            printf '1. Trust folder\\r\\n2. Exit\\r\\n'
            if IFS= read -r answer; then
              /usr/bin/touch '\(marker.path)'
            fi
            sleep 5
            """
        )

        let snapshot = await ProviderUsageService(timeout: 1).snapshot(
            for: AgentInstallation(
                kind: .antigravity,
                executablePath: executable.path
            )
        )

        XCTAssertEqual(snapshot.state, .unknown)
        XCTAssertTrue(snapshot.detail.contains("trust"), snapshot.detail)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testLiveCodexUsageWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["THIRD_HAND_RUN_LIVE_USAGE_TEST"] == "1" else {
            throw XCTSkip("Set THIRD_HAND_RUN_LIVE_USAGE_TEST=1 for the read-only Codex app-server probe")
        }

        let installations = await AgentDetector().detect()
        let codex = try XCTUnwrap(
            installations.first { $0.kind == .codex && $0.isAvailable }
        )
        let snapshot = await ProviderUsageService().snapshot(for: codex)

        XCTAssertEqual(snapshot.agent, .codex)
        XCTAssertNotEqual(snapshot.state, .unknown, snapshot.detail)
        XCTAssertFalse(snapshot.windows.isEmpty)
    }

    func testLiveAntigravityUsageWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment[
            "THIRD_HAND_RUN_LIVE_ANTIGRAVITY_USAGE_TEST"
        ] == "1" else {
            throw XCTSkip(
                "Set THIRD_HAND_RUN_LIVE_ANTIGRAVITY_USAGE_TEST=1 for the read-only agy /usage PTY probe"
            )
        }

        let installations = await AgentDetector().detect()
        let antigravity = try XCTUnwrap(
            installations.first {
                $0.kind == .antigravity && $0.isAvailable
            }
        )
        let snapshot = await ProviderUsageService(timeout: 20).snapshot(
            for: antigravity
        )

        XCTAssertEqual(snapshot.agent, .antigravity)
        XCTAssertNotEqual(snapshot.state, .unknown, snapshot.detail)
        XCTAssertEqual(snapshot.windows.count, 4)
    }

    private func responseData(
        primary: [String: Any],
        secondary: [String: Any]? = nil,
        rateLimitReachedType: String? = nil
    ) throws -> Data {
        var limits: [String: Any] = [
            "limitId": "codex",
            "primary": primary,
            "secondary": secondary ?? NSNull(),
            "rateLimitReachedType": rateLimitReachedType ?? NSNull()
        ]
        limits["credits"] = [
            "hasCredits": false,
            "unlimited": false,
            "balance": "0"
        ]

        return try JSONSerialization.data(
            withJSONObject: [
                "id": 2,
                "result": [
                    "rateLimits": limits,
                    "rateLimitsByLimitId": ["codex": limits]
                ]
            ]
        )
    }

    private func makeExecutable(
        in directory: URL,
        contents: String
    ) throws -> URL {
        let url = directory.appendingPathComponent("fake-agy")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }
}
