import Foundation
import XCTest
@testable import ThirdHand

@MainActor
final class ProviderUsageAutoRefreshTests: XCTestCase {
    func testAutoRefreshIsSingleInstanceAndStopsCleanly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThirdHandAutoUsage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = CountingProviderUsageService()
        let store = AppStore(
            persistence: PersistenceService(
                stateURL: directory.appendingPathComponent("tasks.json")
            ),
            performAgentDiscovery: false,
            providerUsageService: service,
            usageAutoRefreshInterval: .milliseconds(40)
        )
        store.agentInstallations = [
            AgentInstallation(kind: .codex, executablePath: "/usr/bin/true")
        ]

        store.startUsageAutoRefresh()
        store.startUsageAutoRefresh()
        try await Swift.Task.sleep(for: .milliseconds(20))
        let countAfterStart = await service.count()
        XCTAssertEqual(
            countAfterStart,
            1,
            "Starting the lifecycle twice must not create two refresh loops"
        )

        try await Swift.Task.sleep(for: .milliseconds(110))
        let periodicCount = await service.count()
        XCTAssertGreaterThanOrEqual(periodicCount, 3)

        store.stopUsageAutoRefresh()
        try await Swift.Task.sleep(for: .milliseconds(20))
        let countAfterStop = await service.count()
        try await Swift.Task.sleep(for: .milliseconds(100))
        let finalCount = await service.count()
        XCTAssertEqual(finalCount, countAfterStop)
    }

    func testAntigravityUsagePutsSelectedModelGroupFirst() {
        let store = AppStore(
            persistence: PersistenceService(
                stateURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("ThirdHandModelUsage-\(UUID().uuidString).json")
            ),
            performAgentDiscovery: false
        )
        store.providerUsage[.antigravity] = ProviderUsageSnapshot(
            agent: .antigravity,
            state: .available,
            windows: [
                ProviderUsageWindow(
                    id: "gemini-weekly",
                    title: "7 дн.",
                    remainingFraction: 0.9
                ),
                ProviderUsageWindow(
                    id: "gemini-five-hour",
                    title: "5 ч.",
                    remainingFraction: 0.8
                ),
                ProviderUsageWindow(
                    id: "claude-gpt-weekly",
                    title: "7 дн.",
                    remainingFraction: 0.7
                ),
                ProviderUsageWindow(
                    id: "claude-gpt-five-hour",
                    title: "5 ч.",
                    remainingFraction: 0.6
                )
            ],
            detail: "fixture",
            updatedAt: .now
        )

        let claude = store.usageSnapshot(
            for: .antigravity,
            modelID: "Claude Sonnet 4.6 (Thinking)"
        )
        XCTAssertEqual(
            claude.windows.prefix(2).map(\.id),
            ["claude-gpt-weekly", "claude-gpt-five-hour"]
        )

        let gemini = store.usageSnapshot(
            for: .antigravity,
            modelID: "Gemini 3.1 Pro (High)"
        )
        XCTAssertEqual(
            gemini.windows.prefix(2).map(\.id),
            ["gemini-weekly", "gemini-five-hour"]
        )

        let unspecified = store.usageSnapshot(for: .antigravity)
        XCTAssertEqual(unspecified.windows.map(\.id), ["all-weekly", "all-five-hour"])
        XCTAssertEqual(unspecified.windows[0].remainingFraction, 0.7, accuracy: 0.0001)
        XCTAssertEqual(unspecified.windows[1].remainingFraction, 0.6, accuracy: 0.0001)
        XCTAssertTrue(unspecified.detail.contains("минимум"))
    }

    func testManualRefreshDoesNotKeepAStaleOfficialSnapshot() async {
        let service = StaticProviderUsageService(
            snapshots: [.antigravity: .unknown(for: .antigravity, detail: "setup required")]
        )
        let store = AppStore(
            persistence: PersistenceService(
                stateURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("ThirdHandStaleUsage-\(UUID().uuidString).json")
            ),
            performAgentDiscovery: false,
            providerUsageService: service
        )
        store.agentInstallations = [
            AgentInstallation(kind: .antigravity, executablePath: "/usr/bin/true")
        ]
        store.providerUsage[.antigravity] = ProviderUsageSnapshot(
            agent: .antigravity,
            state: .available,
            windows: [
                ProviderUsageWindow(
                    id: "gemini-weekly",
                    title: "7 дн.",
                    remainingFraction: 0.5
                )
            ],
            detail: "old",
            updatedAt: .now,
            source: .officialCLI
        )

        await store.refreshProviderUsage(clearInferredExhaustion: true)

        XCTAssertEqual(store.providerUsage[.antigravity]?.state, .unknown)
        XCTAssertEqual(store.providerUsage[.antigravity]?.detail, "setup required")
    }
}

private actor CountingProviderUsageService: ProviderUsageProviding {
    private var callCount = 0

    func snapshots(
        for installations: [AgentInstallation]
    ) async -> [AgentKind: ProviderUsageSnapshot] {
        callCount += 1
        return [:]
    }

    func count() -> Int {
        callCount
    }
}

private actor StaticProviderUsageService: ProviderUsageProviding {
    let value: [AgentKind: ProviderUsageSnapshot]

    init(snapshots: [AgentKind: ProviderUsageSnapshot]) {
        value = snapshots
    }

    func snapshots(
        for installations: [AgentInstallation]
    ) async -> [AgentKind: ProviderUsageSnapshot] {
        value
    }
}
