import Foundation

struct AgentDetector: Sendable {
    func detect() async -> [AgentInstallation] {
        await Task.detached(priority: .utility) {
            AgentKind.allCases.map { kind in
                AgentInstallation(
                    kind: kind,
                    executablePath: ExecutableResolver.first(
                        named: kind.commandNames
                    )
                )
            }
        }.value
    }
}
