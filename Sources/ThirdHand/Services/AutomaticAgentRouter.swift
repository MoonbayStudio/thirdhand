import Foundation

enum AutomaticAgentRouter {
    static func candidates(
        for task: CodingTask,
        installations: [AgentInstallation],
        preferredOrder: [AgentKind],
        usageSnapshots: [AgentKind: ProviderUsageSnapshot]
    ) -> [AgentKind] {
        candidates(
            routingMode: task.effectiveRoutingMode,
            currentAgent: task.currentAgent,
            installations: installations,
            preferredOrder: preferredOrder,
            usageSnapshots: usageSnapshots,
            antigravityModelID: task.agentConfiguration?[.model]
        )
    }

    static func candidates(
        routingMode: AgentRoutingMode,
        currentAgent: AgentKind?,
        installations: [AgentInstallation],
        preferredOrder: [AgentKind],
        usageSnapshots: [AgentKind: ProviderUsageSnapshot],
        now: Date = .now,
        antigravityModelID: String? = nil
    ) -> [AgentKind] {
        let availableAgents = Set(
            installations.compactMap { installation in
                installation.isAvailable ? installation.kind : nil
            }
        )
        let orderedAgents = normalizedOrder(preferredOrder)

        switch routingMode {
        case .manual:
            if let currentAgent {
                return [currentAgent]
            }
            return orderedAgents.first(where: availableAgents.contains).map { [$0] } ?? []

        case .automatic:
            return orderedAgents.filter { agent in
                availableAgents.contains(agent)
                    && !usageBlocksAutomaticRouting(
                        agent: agent,
                        snapshot: usageSnapshots[agent],
                        antigravityModelID: antigravityModelID,
                        now: now
                    )
            }
        }
    }

    private static func usageBlocksAutomaticRouting(
        agent: AgentKind,
        snapshot: ProviderUsageSnapshot?,
        antigravityModelID: String?,
        now: Date
    ) -> Bool {
        guard let snapshot else { return false }
        if snapshot.blocksAutomaticRouting(at: now) {
            return true
        }
        guard agent == .antigravity,
              snapshot.source == .officialCLI
        else {
            return false
        }

        let relevantWindows: [ProviderUsageWindow]
        if let antigravityModelID, !antigravityModelID.isEmpty {
            let normalizedModel = antigravityModelID.lowercased()
            let prefix = normalizedModel.contains("claude")
                || normalizedModel.contains("gpt")
                ? "claude-gpt-"
                : "gemini-"
            relevantWindows = snapshot.windows.filter {
                $0.id.hasPrefix(prefix)
            }
        } else {
            // Antigravity may use either quota group for its configured default
            // model. Until the task selects a model explicitly, routing must not
            // assume Gemini and accidentally start against an exhausted group.
            relevantWindows = snapshot.windows
        }
        guard !relevantWindows.isEmpty else { return false }

        return relevantWindows.contains { window in
            guard window.remainingFraction == 0 else { return false }
            return window.resetsAt.map { now < $0 } ?? true
        }
    }

    private static func normalizedOrder(_ preferredOrder: [AgentKind]) -> [AgentKind] {
        var result: [AgentKind] = []
        var seen: Set<AgentKind> = []

        for agent in preferredOrder + AgentKind.allCases where seen.insert(agent).inserted {
            result.append(agent)
        }

        return result
    }
}
