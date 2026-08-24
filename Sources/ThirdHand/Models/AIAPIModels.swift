import Foundation

enum AIAPIProvider: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case openRouter
    case deepSeek
    case openAI
    case anthropic
    case googleGemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .deepSeek: "DeepSeek"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .googleGemini: "Google Gemini"
        }
    }

    var shortName: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .deepSeek: "DeepSeek API"
        case .openAI: "OpenAI"
        case .anthropic: "Claude API"
        case .googleGemini: "Gemini API"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .openRouter: "sk-or-v1-…"
        case .deepSeek: "sk-…"
        case .openAI: "sk-…"
        case .anthropic: "sk-ant-…"
        case .googleGemini: "AIza…"
        }
    }

    var privacyHost: String {
        switch self {
        case .openRouter: "openrouter.ai"
        case .deepSeek: "api.deepseek.com"
        case .openAI: "api.openai.com"
        case .anthropic: "api.anthropic.com"
        case .googleGemini: "generativelanguage.googleapis.com"
        }
    }
}
struct AIAPIModelOption: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let contextLength: Int?

    init(id: String, name: String? = nil, contextLength: Int? = nil) {
        self.id = id
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? name!
            : id
        self.contextLength = contextLength
    }
}

struct AIAPITarget: Codable, Hashable, Identifiable, Sendable {
    let provider: AIAPIProvider
    let modelID: String

    var id: String { "\(provider.rawValue):\(modelID)" }
    var displayName: String { "\(provider.displayName) · \(modelID)" }
}

enum AgentExecutionSource: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case cli
    case api

    var id: Self { self }

    var title: String {
        switch self {
        case .cli: "CLI"
        case .api: "API"
        }
    }
}

enum AgentExecutionTarget: Hashable, Sendable {
    case cli(AgentKind)
    case api(AIAPITarget)

    var source: AgentExecutionSource {
        switch self {
        case .cli: .cli
        case .api: .api
        }
    }

    var displayName: String {
        switch self {
        case let .cli(agent): agent.displayName
        case let .api(target): target.displayName
        }
    }

    var shortName: String {
        switch self {
        case let .cli(agent): "\(agent.shortName) CLI"
        case let .api(target): target.provider.shortName
        }
    }

    var fallbackAgentKind: AgentKind {
        switch self {
        case let .cli(agent): agent
        case let .api(target):
            switch target.provider {
            case .deepSeek: .deepSeek
            case .openAI: .codex
            case .anthropic: .claudeCode
            case .openRouter, .googleGemini: .antigravity
            }
        }
    }
}

struct AIAPIExecutionRequest: Hashable, Sendable {
    let target: AIAPITarget
    let prompt: String
    let systemPrompt: String?
    let maximumOutputTokens: Int

    init(
        target: AIAPITarget,
        prompt: String,
        systemPrompt: String? = nil,
        maximumOutputTokens: Int = 4_096
    ) {
        self.target = target
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.maximumOutputTokens = maximumOutputTokens
    }
}

struct AIAPIExecutionResponse: Hashable, Sendable {
    let text: String
    let target: AIAPITarget
}

protocol AIAPIExecuting: Sendable {
    func availableTargets() -> [AIAPITarget]
    func execute(_ request: AIAPIExecutionRequest) async throws -> AIAPIExecutionResponse
}

struct DisabledAIAPIExecutor: AIAPIExecuting {
    func availableTargets() -> [AIAPITarget] { [] }

    func execute(_ request: AIAPIExecutionRequest) async throws -> AIAPIExecutionResponse {
        throw AIAPIError.notConfigured(request.target.provider)
    }
}

enum AIAPIPreferences {
    static let automaticFallbackEnabledKey = "apiAutomaticFallbackEnabled"
    static let preferredProviderKey = "apiPreferredProvider"
    static let handoffEnabledKey = "apiHandoffEnabled"
    static let handoffProviderKey = "apiHandoffProvider"
    static let handoffModelIDKey = "apiHandoffModelID"
    static let casualConversationEnabledKey = "apiCasualConversationEnabled"

    static func primaryModelKey(for provider: AIAPIProvider) -> String {
        "apiPrimaryModel.\(provider.rawValue)"
    }

    static func modelCatalogKey(for provider: AIAPIProvider) -> String {
        "apiModelCatalog.\(provider.rawValue)"
    }

    static func primaryModelID(
        for provider: AIAPIProvider,
        defaults: UserDefaults = .standard
    ) -> String {
        let stored = defaults.string(forKey: primaryModelKey(for: provider))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty { return stored }

        if provider == .openRouter {
            let legacy = defaults.string(forKey: OpenRouterPreferences.handoffModelIDKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return legacy.isEmpty ? OpenRouterPreferences.freeConversationModelID : legacy
        }
        if provider == .deepSeek {
            return "deepseek-v4-flash"
        }
        return ""
    }

    static func preferredProvider(defaults: UserDefaults = .standard) -> AIAPIProvider {
        defaults.string(forKey: preferredProviderKey)
            .flatMap(AIAPIProvider.init(rawValue:)) ?? .openRouter
    }

    static func isAutomaticFallbackEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: automaticFallbackEnabledKey) == nil
            ? true
            : defaults.bool(forKey: automaticFallbackEnabledKey)
    }

    static func isCasualConversationEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: casualConversationEnabledKey) != nil {
            return defaults.bool(forKey: casualConversationEnabledKey)
        }
        return OpenRouterPreferences.loadConversation(defaults: defaults).isEnabled
    }

    static func primaryTarget(defaults: UserDefaults = .standard) -> AIAPITarget? {
        let preferred = preferredProvider(defaults: defaults)
        let order = [preferred] + AIAPIProvider.allCases.filter { $0 != preferred }
        return order.compactMap { provider in
            let modelID = primaryModelID(for: provider, defaults: defaults)
            return modelID.isEmpty ? nil : AIAPITarget(provider: provider, modelID: modelID)
        }.first
    }

    static func automaticTargets(defaults: UserDefaults = .standard) -> [AIAPITarget] {
        guard isAutomaticFallbackEnabled(defaults: defaults) else { return [] }
        let preferred = preferredProvider(defaults: defaults)
        let order = [preferred] + AIAPIProvider.allCases.filter { $0 != preferred }
        return order.compactMap { provider in
            let modelID = primaryModelID(for: provider, defaults: defaults)
            return modelID.isEmpty ? nil : AIAPITarget(provider: provider, modelID: modelID)
        }
    }

    static func handoffTarget(defaults: UserDefaults = .standard) -> AIAPITarget? {
        let hasNewEnabledValue = defaults.object(forKey: handoffEnabledKey) != nil
        let isEnabled = hasNewEnabledValue
            ? defaults.bool(forKey: handoffEnabledKey)
            : defaults.bool(forKey: OpenRouterPreferences.handoffEnabledKey)
        guard isEnabled else { return nil }

        let provider = defaults.string(forKey: handoffProviderKey)
            .flatMap(AIAPIProvider.init(rawValue:)) ?? .openRouter
        let explicitModel = defaults.string(forKey: handoffModelIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let legacyModel = defaults.string(forKey: OpenRouterPreferences.handoffModelIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelID = explicitModel.isEmpty
            ? (provider == .openRouter && !legacyModel.isEmpty
                ? legacyModel
                : primaryModelID(for: provider, defaults: defaults))
            : explicitModel
        return modelID.isEmpty ? nil : AIAPITarget(provider: provider, modelID: modelID)
    }

    static func cachedModels(
        for provider: AIAPIProvider,
        defaults: UserDefaults = .standard
    ) -> [AIAPIModelOption] {
        guard let data = defaults.data(forKey: modelCatalogKey(for: provider)),
              let models = try? JSONDecoder().decode([AIAPIModelOption].self, from: data)
        else {
            return []
        }
        return models
    }

    static func saveCachedModels(
        _ models: [AIAPIModelOption],
        for provider: AIAPIProvider,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        defaults.set(data, forKey: modelCatalogKey(for: provider))
    }
}
