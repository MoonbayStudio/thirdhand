import Foundation

struct OpenRouterKeyInfo: Hashable, Sendable {
    let label: String?
}

enum OpenRouterAPIError: LocalizedError, Sendable {
    case invalidResponse
    case httpStatus(Int, String?)
    case emptyResponse
    case malformedHandoff

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "OpenRouter вернул некорректный HTTP-ответ."
        case let .httpStatus(status, message):
            if let message, !message.isEmpty {
                "OpenRouter вернул ошибку \(status): \(message)"
            } else {
                "OpenRouter вернул ошибку \(status)."
            }
        case .emptyResponse:
            "OpenRouter не вернул сжатый контекст."
        case .malformedHandoff:
            "OpenRouter вернул handoff в неподдерживаемом формате."
        }
    }
}

struct OpenRouterAPIClient: Sendable {
    private let session: URLSession
    private let baseURL: URL

    init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    func validateAPIKey(_ apiKey: String) async throws -> OpenRouterKeyInfo {
        let request = try authorizedRequest(
            path: "key",
            method: "GET",
            apiKey: apiKey
        )
        let data = try await responseData(for: request)
        let envelope = try? JSONDecoder().decode(KeyEnvelope.self, from: data)
        return OpenRouterKeyInfo(label: envelope?.data.label)
    }

    func fetchModels(apiKey: String) async throws -> [OpenRouterModelOption] {
        let request = try authorizedRequest(
            path: "models",
            method: "GET",
            apiKey: apiKey
        )
        let data = try await responseData(for: request)
        let envelope = try JSONDecoder().decode(ModelsEnvelope.self, from: data)
        return envelope.data.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    func compressHandoff(
        apiKey: String,
        modelID: String,
        request compressionRequest: AgentHandoffCompressionRequest
    ) async throws -> CompressedAgentHandoff {
        var request = try authorizedRequest(
            path: "chat/completions",
            method: "POST",
            apiKey: apiKey
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = ChatCompletionRequest(
            model: modelID,
            messages: [
                ChatCompletionMessage(
                    role: "system",
                    content: """
                    You compile loss-minimizing handoffs between coding agents. Return only one JSON object with exactly these fields: decisions, progress, knownIssues, nextStep. The first three fields are arrays of at most four short factual strings. nextStep is one concrete action. Preserve constraints and uncertainty, do not invent completed work, do not include code or Markdown fences.
                    """
                ),
                ChatCompletionMessage(
                    role: "user",
                    content: compressionRequest.context
                )
            ],
            temperature: 0.1,
            maxTokens: 900
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let data = try await responseData(for: request)
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = response.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw OpenRouterAPIError.emptyResponse
        }
        return try OpenRouterHandoffResponseParser.parse(
            content,
            modelID: modelID
        )
    }

    private func authorizedRequest(
        path: String,
        method: String,
        apiKey: String
    ) throws -> URLRequest {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            throw OpenRouterCredentialError.emptyKey
        }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(normalizedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Third Hand", forHTTPHeaderField: "X-Title")
        return request
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterAPIError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            let message = (try? JSONDecoder().decode(
                ErrorEnvelope.self,
                from: data
            ))?.error.message
            throw OpenRouterAPIError.httpStatus(
                httpResponse.statusCode,
                message.map { String($0.prefix(300)) }
            )
        }
        return data
    }
}

struct OpenRouterHandoffService: AgentHandoffCompressing {
    private let client: OpenRouterAPIClient
    private let credentialStore: any OpenRouterCredentialStoring
    private let configurationProvider: @Sendable () -> OpenRouterHandoffConfiguration

    init(
        client: OpenRouterAPIClient = OpenRouterAPIClient(),
        credentialStore: any OpenRouterCredentialStoring = KeychainOpenRouterCredentialStore(),
        configurationProvider: @escaping @Sendable () -> OpenRouterHandoffConfiguration = {
            OpenRouterPreferences.load()
        }
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.configurationProvider = configurationProvider
    }

    func compress(
        _ request: AgentHandoffCompressionRequest
    ) async throws -> CompressedAgentHandoff? {
        let configuration = configurationProvider()
        guard configuration.isReady,
              let apiKey = try credentialStore.loadAPIKey()
        else {
            return nil
        }
        return try await client.compressHandoff(
            apiKey: apiKey,
            modelID: configuration.modelID,
            request: request
        )
    }
}

private enum OpenRouterHandoffResponseParser {
    static func parse(
        _ content: String,
        modelID: String
    ) throws -> CompressedAgentHandoff {
        guard let openingBrace = content.firstIndex(of: "{"),
              let closingBrace = content.lastIndex(of: "}"),
              openingBrace <= closingBrace
        else {
            throw OpenRouterAPIError.malformedHandoff
        }
        let json = String(content[openingBrace...closingBrace])
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(HandoffPayload.self, from: data)
        else {
            throw OpenRouterAPIError.malformedHandoff
        }

        let nextStep = normalized(payload.nextStep, maximumCharacters: 1_000)
        guard !nextStep.isEmpty else {
            throw OpenRouterAPIError.malformedHandoff
        }
        return CompressedAgentHandoff(
            decisions: normalized(payload.decisions),
            progress: normalized(payload.progress),
            knownIssues: normalized(payload.knownIssues),
            nextStep: nextStep,
            modelID: modelID
        )
    }

    private static func normalized(_ values: [String]) -> [String] {
        Array(
            values
                .map { normalized($0, maximumCharacters: 700) }
                .filter { !$0.isEmpty }
                .prefix(4)
        )
    }

    private static func normalized(
        _ value: String,
        maximumCharacters: Int
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumCharacters else { return trimmed }
        return String(trimmed.prefix(maximumCharacters))
    }
}

private struct ModelsEnvelope: Decodable {
    let data: [OpenRouterModelOption]
}

private struct KeyEnvelope: Decodable {
    struct KeyData: Decodable {
        let label: String?
    }

    let data: KeyData
}

private struct ErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String?
    }

    let error: APIError
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatCompletionMessage]
    let temperature: Double
    let maxTokens: Int

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
    }
}

private struct ChatCompletionMessage: Codable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        let message: ChatCompletionMessage
    }

    let choices: [Choice]
}

private struct HandoffPayload: Decodable {
    let decisions: [String]
    let progress: [String]
    let knownIssues: [String]
    let nextStep: String
}
