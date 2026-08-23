import Foundation

enum AgentRoutingPreferences {
    static let automaticOrderKey = "automaticAgentOrder"

    static var defaultOrder: [AgentKind] {
        [.codex, .claudeCode, .antigravity]
    }

    static func load(from defaults: UserDefaults = .standard) -> [AgentKind] {
        let stored = defaults.string(forKey: automaticOrderKey)?
            .split(separator: ",")
            .compactMap { AgentKind(rawValue: String($0)) } ?? []

        var result: [AgentKind] = []
        for kind in stored + defaultOrder where !result.contains(kind) {
            result.append(kind)
        }
        return result
    }

    static func save(
        _ order: [AgentKind],
        to defaults: UserDefaults = .standard
    ) {
        var normalized: [AgentKind] = []
        for kind in order + defaultOrder where !normalized.contains(kind) {
            normalized.append(kind)
        }
        defaults.set(normalized.map(\.rawValue).joined(separator: ","), forKey: automaticOrderKey)
    }
}
