import Foundation

enum ProviderUsageState: String, Hashable, Sendable {
    case available
    case exhausted
    case unknown
}

enum ProviderUsageSource: String, Hashable, Sendable {
    case officialCLI
    case executionError
    case unavailable
}

struct ProviderUsageWindow: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let remainingFraction: Double
    let resetsAt: Date?

    init(
        id: String,
        title: String,
        remainingFraction: Double,
        resetsAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.remainingFraction = min(max(remainingFraction, 0), 1)
        self.resetsAt = resetsAt
    }

    var remainingPercent: Int {
        Int((remainingFraction * 100).rounded())
    }
}

struct ProviderUsageSnapshot: Hashable, Sendable {
    let agent: AgentKind
    var state: ProviderUsageState
    var windows: [ProviderUsageWindow]
    var detail: String
    var updatedAt: Date
    var source: ProviderUsageSource = .officialCLI

    func blocksAutomaticRouting(at date: Date = .now) -> Bool {
        guard state == .exhausted else { return false }

        if source == .executionError {
            return date < updatedAt.addingTimeInterval(15 * 60)
        }

        let resetDates = windows.compactMap(\.resetsAt)
        guard let nextReset = resetDates.min() else { return true }
        return date < nextReset
    }

    static func unknown(
        for agent: AgentKind,
        detail: String = "Официальный CLI не сообщает остаток лимита."
    ) -> Self {
        Self(
            agent: agent,
            state: .unknown,
            windows: [],
            detail: detail,
            updatedAt: .now,
            source: .unavailable
        )
    }

    static func exhausted(for agent: AgentKind, detail: String) -> Self {
        Self(
            agent: agent,
            state: .exhausted,
            windows: [
                ProviderUsageWindow(
                    id: "exhausted",
                    title: "Лимит",
                    remainingFraction: 0
                )
            ],
            detail: detail,
            updatedAt: .now,
            source: .executionError
        )
    }
}
