import Foundation

struct AgentCapabilityDetector: Sendable {
    func detect(installations: [AgentInstallation]) async -> [AgentKind: AgentCapabilitySet] {
        await Task.detached(priority: .utility) {
            var catalog = AgentCapabilityCatalog.fallback

            for installation in installations {
                guard let executablePath = installation.executablePath else { continue }

                switch installation.kind {
                case .codex:
                    if let models = Self.loadCodexModels(executablePath: executablePath), !models.isEmpty {
                        catalog[.codex] = AgentCapabilitySet(kind: .codex, models: models)
                    }

                case .claudeCode:
                    break

                case .antigravity:
                    if let models = Self.loadAntigravityModels(executablePath: executablePath), !models.isEmpty {
                        catalog[.antigravity] = AgentCapabilitySet(kind: .antigravity, models: models)
                    }

                case .deepSeek:
                    // The headless profile owns its model selection in DSH settings.
                    break
                }
            }

            return catalog
        }.value
    }

    private static func loadCodexModels(executablePath: String) -> [AgentModelCapability]? {
        guard let data = run(executablePath: executablePath, arguments: ["debug", "models"]),
              let envelope = try? JSONDecoder().decode(CodexModelsEnvelope.self, from: data)
        else {
            return nil
        }

        return envelope.models
            .filter { $0.visibility != "hide" && $0.slug != "codex-auto-review" }
            .map { model in
                AgentCapabilityCatalog.codexModel(
                    model.slug,
                    title: AgentCapabilityCatalog.codexModelTitle(model.slug),
                    detail: model.description,
                    efforts: model.supportedReasoningLevels.map(\.effort),
                    defaultEffort: model.defaultReasoningLevel ?? "medium",
                    fast: model.serviceTiers.contains { $0.id == "priority" }
                        || model.additionalSpeedTiers.contains("fast")
                )
            }
    }

    private static func loadAntigravityModels(executablePath: String) -> [AgentModelCapability]? {
        guard let data = run(executablePath: executablePath, arguments: ["models"]),
              let output = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let models = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasSuffix(":") }

        return models.map { AgentModelCapability(id: $0, title: $0) }
    }

    private static func run(executablePath: String, arguments: [String]) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return data
        } catch {
            return nil
        }
    }
}

private struct CodexModelsEnvelope: Decodable {
    let models: [CodexModelRecord]
}

private struct CodexModelRecord: Decodable {
    let slug: String
    let description: String?
    let defaultReasoningLevel: String?
    let supportedReasoningLevels: [CodexReasoningRecord]
    let additionalSpeedTiers: [String]
    let serviceTiers: [CodexServiceTierRecord]
    let visibility: String?

    enum CodingKeys: String, CodingKey {
        case slug
        case description
        case defaultReasoningLevel = "default_reasoning_level"
        case supportedReasoningLevels = "supported_reasoning_levels"
        case additionalSpeedTiers = "additional_speed_tiers"
        case serviceTiers = "service_tiers"
        case visibility
    }
}

private struct CodexReasoningRecord: Decodable {
    let effort: String
}

private struct CodexServiceTierRecord: Decodable {
    let id: String
}
