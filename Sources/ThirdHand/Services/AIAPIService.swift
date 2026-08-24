import Foundation

enum AIAPIError: LocalizedError, Sendable {
    case notConfigured(AIAPIProvider)
    case invalidResponse(AIAPIProvider)
    case httpStatus(AIAPIProvider, Int, String?)
    case emptyResponse(AIAPIProvider)
    case malformedHandoff

    var isQuotaExceeded: Bool {
        switch self {
        case let .httpStatus(_, status, message):
            if status == 402 || status == 429 { return true }
            let normalized = message?.lowercased() ?? ""
            return normalized.contains("insufficient_quota")
                || normalized.contains("quota exceeded")
                || normalized.contains("credit balance")
                || normalized.contains("usage limit")
        case .notConfigured, .invalidResponse, .emptyResponse, .malformedHandoff:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case let .notConfigured(provider):
            "Для \(provider.displayName) не сохранён API-ключ или не выбрана модель."
        case let .invalidResponse(provider):
            "\(provider.displayName) вернул некорректный HTTP-ответ."
        case let .httpStatus(provider, status, message):
            if let message, !message.isEmpty {
                "\(provider.displayName) вернул ошибку \(status): \(message)"
            } else {
                "\(provider.displayName) вернул ошибку \(status)."
            }
        case let .emptyResponse(provider):
            "\(provider.displayName) не вернул текстовый ответ."
        case .malformedHandoff:
            "API-модель вернула handoff в неподдерживаемом формате."
        }
    }
}

struct AIAPIClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchModels(
        provider: AIAPIProvider,
        apiKey: String
    ) async throws -> [AIAPIModelOption] {
        let request = try modelsRequest(provider: provider, apiKey: apiKey)
        let data = try await responseData(for: request, provider: provider)
        let models: [AIAPIModelOption]

        switch provider {
        case .openRouter:
            let envelope = try JSONDecoder().decode(OpenRouterModelsEnvelope.self, from: data)
            models = envelope.data.map {
                AIAPIModelOption(id: $0.id, name: $0.name, contextLength: $0.contextLength)
            }
        case .deepSeek:
            let envelope = try JSONDecoder().decode(OpenAIModelsEnvelope.self, from: data)
            models = envelope.data.map { AIAPIModelOption(id: $0.id) }
        case .openAI:
            let envelope = try JSONDecoder().decode(OpenAIModelsEnvelope.self, from: data)
            models = envelope.data
                .map { AIAPIModelOption(id: $0.id) }
                .filter { Self.looksLikeTextModel($0.id) }
        case .anthropic:
            let envelope = try JSONDecoder().decode(AnthropicModelsEnvelope.self, from: data)
            models = envelope.data.map {
                AIAPIModelOption(
                    id: $0.id,
                    name: $0.displayName,
                    contextLength: $0.maxInputTokens
                )
            }
        case .googleGemini:
            let envelope = try JSONDecoder().decode(GeminiModelsEnvelope.self, from: data)
            models = envelope.models.compactMap { model in
                let methods = model.supportedGenerationMethods ?? model.supportedActions ?? []
                guard methods.contains("generateContent") else { return nil }
                let id = model.name.hasPrefix("models/")
                    ? String(model.name.dropFirst("models/".count))
                    : model.name
                return AIAPIModelOption(
                    id: id,
                    name: model.displayName,
                    contextLength: model.inputTokenLimit
                )
            }
        }

        return models.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    func complete(
        provider: AIAPIProvider,
        apiKey: String,
        modelID: String,
        prompt: String,
        systemPrompt: String? = nil,
        maximumOutputTokens: Int = 4_096
    ) async throws -> AIAPIExecutionResponse {
        let target = AIAPITarget(provider: provider, modelID: modelID)
        let request = try completionRequest(
            target: target,
            apiKey: apiKey,
            prompt: prompt,
            systemPrompt: systemPrompt,
            maximumOutputTokens: maximumOutputTokens
        )
        let data = try await responseData(for: request, provider: provider)
        let text: String?

        switch provider {
        case .openRouter, .deepSeek:
            text = try JSONDecoder().decode(ChatCompletionEnvelope.self, from: data)
                .choices.first?.message.content
        case .openAI:
            let envelope = try JSONDecoder().decode(OpenAIResponseEnvelope.self, from: data)
            text = envelope.output
                .flatMap { $0.content ?? [] }
                .compactMap(\.text)
                .joined(separator: "\n")
        case .anthropic:
            text = try JSONDecoder().decode(AnthropicMessageEnvelope.self, from: data)
                .content.compactMap(\.text).joined(separator: "\n")
        case .googleGemini:
            text = try JSONDecoder().decode(GeminiGenerateEnvelope.self, from: data)
                .candidates.first?.content.parts.compactMap(\.text).joined(separator: "\n")
        }

        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else { throw AIAPIError.emptyResponse(provider) }
        return AIAPIExecutionResponse(text: normalized, target: target)
    }

    private func modelsRequest(
        provider: AIAPIProvider,
        apiKey: String
    ) throws -> URLRequest {
        let key = try normalizedKey(apiKey, provider: provider)
        let url: URL
        switch provider {
        case .openRouter:
            url = URL(string: "https://openrouter.ai/api/v1/models")!
        case .deepSeek:
            url = URL(string: "https://api.deepseek.com/models")!
        case .openAI:
            url = URL(string: "https://api.openai.com/v1/models")!
        case .anthropic:
            url = URL(string: "https://api.anthropic.com/v1/models?limit=1000")!
        case .googleGemini:
            url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")!
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuthorization(provider: provider, apiKey: key, to: &request)
        request.timeoutInterval = 30
        return request
    }

    private func completionRequest(
        target: AIAPITarget,
        apiKey: String,
        prompt: String,
        systemPrompt: String?,
        maximumOutputTokens: Int
    ) throws -> URLRequest {
        let key = try normalizedKey(apiKey, provider: target.provider)
        let url: URL
        switch target.provider {
        case .openRouter:
            url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .deepSeek:
            url = URL(string: "https://api.deepseek.com/chat/completions")!
        case .openAI:
            url = URL(string: "https://api.openai.com/v1/responses")!
        case .anthropic:
            url = URL(string: "https://api.anthropic.com/v1/messages")!
        case .googleGemini:
            let encodedModel = target.modelID.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ) ?? target.modelID
            url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent")!
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthorization(provider: target.provider, apiKey: key, to: &request)

        switch target.provider {
        case .openRouter, .deepSeek:
            var messages: [[String: String]] = []
            if let systemPrompt, !systemPrompt.isEmpty {
                messages.append(["role": "system", "content": systemPrompt])
            }
            messages.append(["role": "user", "content": prompt])
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": target.modelID,
                "messages": messages,
                "max_tokens": maximumOutputTokens
            ])
        case .openAI:
            var payload: [String: Any] = [
                "model": target.modelID,
                "input": prompt,
                "max_output_tokens": maximumOutputTokens,
                "store": false
            ]
            if let systemPrompt, !systemPrompt.isEmpty {
                payload["instructions"] = systemPrompt
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        case .anthropic:
            var payload: [String: Any] = [
                "model": target.modelID,
                "max_tokens": maximumOutputTokens,
                "messages": [["role": "user", "content": prompt]]
            ]
            if let systemPrompt, !systemPrompt.isEmpty {
                payload["system"] = systemPrompt
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        case .googleGemini:
            var payload: [String: Any] = [
                "contents": [["role": "user", "parts": [["text": prompt]]]],
                "generationConfig": ["maxOutputTokens": maximumOutputTokens]
            ]
            if let systemPrompt, !systemPrompt.isEmpty {
                payload["systemInstruction"] = ["parts": [["text": systemPrompt]]]
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        return request
    }

    private func applyAuthorization(
        provider: AIAPIProvider,
        apiKey: String,
        to request: inout URLRequest
    ) {
        switch provider {
        case .openRouter:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("Third Hand", forHTTPHeaderField: "X-Title")
        case .deepSeek:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .openAI:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .googleGemini:
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
    }

    private func normalizedKey(_ apiKey: String, provider: AIAPIProvider) throws -> String {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AIAPICredentialError.emptyKey(provider) }
        return value
    }

    private func responseData(
        for request: URLRequest,
        provider: AIAPIProvider
    ) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AIAPIError.invalidResponse(provider)
        }
        guard 200..<300 ~= response.statusCode else {
            throw AIAPIError.httpStatus(
                provider,
                response.statusCode,
                Self.errorMessage(in: data).map { String($0.prefix(400)) }
            )
        }
        return data
    }

    private static func errorMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return String(data: data, encoding: .utf8) }
        if let error = object["error"] as? [String: Any] {
            return error["message"] as? String ?? error["status"] as? String
        }
        return object["message"] as? String
    }

    private static func looksLikeTextModel(_ id: String) -> Bool {
        let excluded = [
            "embedding", "whisper", "tts", "dall-e", "image", "moderation",
            "audio", "realtime", "transcribe", "search-preview"
        ]
        let normalized = id.lowercased()
        return !excluded.contains(where: normalized.contains)
    }
}

struct MultiProviderAPIService: AIAPIExecuting, AgentHandoffCompressing, OpenRouterConversationResponding {
    private let client: AIAPIClient
    private let credentialStore: any AIAPICredentialStoring

    init(
        client: AIAPIClient = AIAPIClient(),
        credentialStore: any AIAPICredentialStoring = KeychainAIAPICredentialStore()
    ) {
        self.client = client
        self.credentialStore = credentialStore
    }

    func availableTargets() -> [AIAPITarget] {
        AIAPIPreferences.automaticTargets().filter { target in
            (try? credentialStore.loadAPIKey(for: target.provider)) != nil
        }
    }

    func execute(_ request: AIAPIExecutionRequest) async throws -> AIAPIExecutionResponse {
        guard let apiKey = try credentialStore.loadAPIKey(for: request.target.provider),
              !request.target.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AIAPIError.notConfigured(request.target.provider)
        }
        return try await client.complete(
            provider: request.target.provider,
            apiKey: apiKey,
            modelID: request.target.modelID,
            prompt: request.prompt,
            systemPrompt: request.systemPrompt,
            maximumOutputTokens: request.maximumOutputTokens
        )
    }

    func respond(
        to request: OpenRouterConversationRequest
    ) async throws -> OpenRouterConversationResponse? {
        guard AIAPIPreferences.isCasualConversationEnabled(),
              let target = AIAPIPreferences.primaryTarget(),
              (try? credentialStore.loadAPIKey(for: target.provider)) != nil
        else {
            return nil
        }
        let response = try await execute(
            AIAPIExecutionRequest(
                target: target,
                prompt: request.prompt,
                maximumOutputTokens: 1_200
            )
        )
        return OpenRouterConversationResponse(
            text: response.text,
            modelID: response.target.displayName
        )
    }

    func compress(
        _ request: AgentHandoffCompressionRequest
    ) async throws -> CompressedAgentHandoff? {
        guard let target = AIAPIPreferences.handoffTarget(),
              (try? credentialStore.loadAPIKey(for: target.provider)) != nil
        else {
            return nil
        }
        let response = try await execute(
            AIAPIExecutionRequest(
                target: target,
                prompt: request.context,
                systemPrompt: handoffSystemPrompt(for: request.interactionMode),
                maximumOutputTokens: 900
            )
        )
        return try parseHandoff(response.text, modelID: response.target.displayName)
    }

    private func handoffSystemPrompt(for mode: AgentInteractionMode) -> String {
        switch mode {
        case .conversation:
            """
            Return only one JSON object with exactly these fields: decisions, progress, knownIssues, nextStep. The first three fields are arrays of at most four short factual strings. Preserve the user's preferences, emotional context, tone and uncertainty. Do not add repository or coding context unless the user discussed it.
            """
        case .automatic, .workspace:
            """
            Return only one JSON object with exactly these fields: decisions, progress, knownIssues, nextStep. The first three fields are arrays of at most four short factual strings. nextStep is one concrete action. Preserve constraints and uncertainty; do not invent completed work or include Markdown fences.
            """
        }
    }

    private func parseHandoff(
        _ content: String,
        modelID: String
    ) throws -> CompressedAgentHandoff {
        guard let opening = content.firstIndex(of: "{"),
              let closing = content.lastIndex(of: "}"),
              opening <= closing,
              let data = String(content[opening...closing]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(HandoffPayload.self, from: data)
        else {
            throw AIAPIError.malformedHandoff
        }
        let nextStep = normalized(payload.nextStep, limit: 1_000)
        guard !nextStep.isEmpty else { throw AIAPIError.malformedHandoff }
        return CompressedAgentHandoff(
            decisions: normalized(payload.decisions),
            progress: normalized(payload.progress),
            knownIssues: normalized(payload.knownIssues),
            nextStep: nextStep,
            modelID: modelID
        )
    }

    private func normalized(_ values: [String]) -> [String] {
        Array(values.map { normalized($0, limit: 700) }.filter { !$0.isEmpty }.prefix(4))
    }

    private func normalized(_ value: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) : trimmed
    }
}

private struct OpenRouterModelsEnvelope: Decodable {
    struct Model: Decodable {
        let id: String
        let name: String?
        let contextLength: Int?

        private enum CodingKeys: String, CodingKey {
            case id, name
            case contextLength = "context_length"
        }
    }
    let data: [Model]
}

private struct OpenAIModelsEnvelope: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
}

private struct AnthropicModelsEnvelope: Decodable {
    struct Model: Decodable {
        let id: String
        let displayName: String?
        let maxInputTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case maxInputTokens = "max_input_tokens"
        }
    }
    let data: [Model]
}

private struct GeminiModelsEnvelope: Decodable {
    struct Model: Decodable {
        let name: String
        let displayName: String?
        let inputTokenLimit: Int?
        let supportedGenerationMethods: [String]?
        let supportedActions: [String]?
    }
    let models: [Model]
}

private struct ChatCompletionEnvelope: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }
    let choices: [Choice]
}

private struct OpenAIResponseEnvelope: Decodable {
    struct Output: Decodable {
        struct Content: Decodable { let text: String? }
        let content: [Content]?
    }
    let output: [Output]
}

private struct AnthropicMessageEnvelope: Decodable {
    struct Content: Decodable { let text: String? }
    let content: [Content]
}

private struct GeminiGenerateEnvelope: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { let text: String? }
            let parts: [Part]
        }
        let content: Content
    }
    let candidates: [Candidate]
}

private struct HandoffPayload: Decodable {
    let decisions: [String]
    let progress: [String]
    let knownIssues: [String]
    let nextStep: String
}
