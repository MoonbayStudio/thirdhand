import Foundation
import XCTest
@testable import ThirdHand

final class OpenRouterServiceTests: XCTestCase {
    override func tearDown() {
        OpenRouterURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testPromptBuilderBoundsContextAndDoesNotExposeAttachmentPathsOrFileContents() {
        let messages = (0..<12).map { index in
            TaskMessage(
                role: index.isMultiple(of: 2) ? .user : .agent,
                text: "message-\(index)",
                attachments: index == 11
                    ? [
                        TaskAttachment(
                            fileName: "design.png",
                            filePath: "/private/sensitive/design.png"
                        )
                    ]
                    : nil
            )
        }
        let task = CodingTask(
            title: "Muni",
            originalRequest: "Build the feature",
            repositoryPath: "/private/repository",
            currentAgent: .codex,
            routingMode: .automatic,
            specification: TaskSpecification(
                objective: "Keep the interface stable",
                constraints: ["No destructive Git commands"]
            ),
            messages: messages,
            persona: AgentPersona(prompt: "Calm senior developer")
        )
        let snapshot = GitSnapshot(
            branch: "main",
            head: "abc123",
            changedFiles: [ChangedFile(status: "M", path: "Sources/App.swift")],
            diffStat: "Sources/App.swift | 4 ++--",
            capturedAt: .now,
            isGitRepository: true
        )
        let longOutput = "SHOULD_BE_TRUNCATED" + String(repeating: "x", count: 6_000) + "LATEST_OUTPUT"

        let request = OpenRouterHandoffPromptBuilder.build(
            task: task,
            from: .codex,
            to: .claudeCode,
            gitSnapshot: snapshot,
            lastAgentOutput: longOutput
        )

        XCTAssertLessThanOrEqual(request.context.count, 32_001)
        XCTAssertFalse(request.context.contains("message-0"))
        XCTAssertTrue(request.context.contains("message-11"))
        XCTAssertTrue(request.context.contains("design.png"))
        XCTAssertFalse(request.context.contains("/private/sensitive/design.png"))
        XCTAssertFalse(request.context.contains("SHOULD_BE_TRUNCATED"))
        XCTAssertTrue(request.context.contains("LATEST_OUTPUT"))
        XCTAssertTrue(request.context.contains("Sources/App.swift"))
    }

    func testConversationHandoffPreservesDialogueWithoutRepositoryContext() {
        let task = CodingTask(
            title: "Стеша",
            originalRequest: "",
            repositoryPath: "/private/REPOSITORY_MUST_NOT_APPEAR",
            messages: [
                TaskMessage(role: .user, text: "Мне нравится тёплый жёлтый цвет"),
                TaskMessage(role: .agent, text: "Запомню — он правда уютный")
            ],
            persona: AgentPersona(
                prompt: "Ты — Стеша, добрая собеседница.",
                interactionMode: .automatic
            )
        )

        let request = OpenRouterHandoffPromptBuilder.build(
            task: task,
            from: .codex,
            to: .claudeCode,
            gitSnapshot: .unavailable,
            lastAgentOutput: "А ещё можно попробовать…",
            interactionMode: .conversation
        )

        XCTAssertEqual(request.interactionMode, .conversation)
        XCTAssertTrue(request.context.contains("тёплый жёлтый цвет"))
        XCTAssertTrue(request.context.contains("А ещё можно попробовать"))
        XCTAssertFalse(request.context.contains("/private/REPOSITORY_MUST_NOT_APPEAR"))
        XCTAssertFalse(request.context.contains("<git_summary"))
        XCTAssertFalse(request.context.contains("independently inspect the repository"))
    }

    func testChatCompletionUsesSelectedModelAndParsesCompactHandoff() async throws {
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        var capturedRequest: URLRequest?
        var capturedBody: Data?
        OpenRouterURLProtocolStub.handler = { request in
            capturedRequest = request
            capturedBody = requestBodyData(request)
            let handoff = try JSONSerialization.data(withJSONObject: [
                "decisions": ["Keep adapters isolated"],
                "progress": ["Split view fixed"],
                "knownIssues": ["Resize still needs QA"],
                "nextStep": "Run minimum-window UI checks"
            ])
            let response = try JSONSerialization.data(withJSONObject: [
                "choices": [[
                    "message": [
                        "role": "assistant",
                        "content": String(decoding: handoff, as: UTF8.self)
                    ]
                ]]
            ])
            return (200, response)
        }

        let client = OpenRouterAPIClient(session: session)
        let handoff = try await client.compressHandoff(
            apiKey: "secret-test-key",
            modelID: "provider/handoff-model",
            request: AgentHandoffCompressionRequest(
                previousAgent: .codex,
                nextAgent: .claudeCode,
                context: "bounded context"
            )
        )

        XCTAssertEqual(handoff.modelID, "provider/handoff-model")
        XCTAssertEqual(handoff.decisions, ["Keep adapters isolated"])
        XCTAssertEqual(handoff.nextStep, "Run minimum-window UI checks")
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-test-key")
        let body = try XCTUnwrap(capturedBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(payload["model"] as? String, "provider/handoff-model")
        let encodedBody = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(encodedBody.contains("bounded context"))
    }

    func testCasualConversationUsesOfficialFreeRouterAndReportsSelectedModel() async throws {
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        var capturedBody: Data?
        OpenRouterURLProtocolStub.handler = { request in
            capturedBody = requestBodyData(request)
            return (
                200,
                Data(
                    #"{"model":"provider/social-model:free","choices":[{"message":{"role":"assistant","content":"Привет! Как ты сегодня?"}}]}"#.utf8
                )
            )
        }

        let response = try await OpenRouterAPIClient(session: session)
            .completeConversation(
                apiKey: "secret-test-key",
                prompt: "Ты — Стеша. Ответь пользователю: привет"
            )

        XCTAssertEqual(response.text, "Привет! Как ты сегодня?")
        XCTAssertEqual(response.modelID, "provider/social-model:free")
        let body = try XCTUnwrap(capturedBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(
            payload["model"] as? String,
            OpenRouterPreferences.freeConversationModelID
        )
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("Ты — Стеша"))
    }

    func testConversationServiceSkipsOpenRouterWhenDisabledOrMissingKey() async throws {
        let disabled = OpenRouterConversationService(
            credentialStore: StubOpenRouterCredentialStore(apiKey: "secret"),
            configurationProvider: {
                OpenRouterConversationConfiguration(isEnabled: false)
            }
        )
        let missingKey = OpenRouterConversationService(
            credentialStore: StubOpenRouterCredentialStore(apiKey: nil),
            configurationProvider: {
                OpenRouterConversationConfiguration(isEnabled: true)
            }
        )
        let request = OpenRouterConversationRequest(prompt: "Привет")
        let disabledResponse = try await disabled.respond(to: request)
        let missingKeyResponse = try await missingKey.respond(to: request)

        XCTAssertNil(disabledResponse)
        XCTAssertNil(missingKeyResponse)
    }

    func testKeyValidationAndModelCatalogUseOfficialEndpoints() async throws {
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        var requestedPaths: [String] = []
        OpenRouterURLProtocolStub.handler = { request in
            requestedPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/v1/key":
                return (200, Data(#"{"data":{"label":"Third Hand"}}"#.utf8))
            case "/api/v1/models":
                return (
                    200,
                    Data(
                        #"{"data":[{"id":"z/model","name":"Zulu","context_length":8000},{"id":"a/model","name":"Alpha","context_length":16000,"supported_parameters":["response_format"]}]}"#.utf8
                    )
                )
            default:
                return (404, Data())
            }
        }

        let client = OpenRouterAPIClient(session: session)
        let key = try await client.validateAPIKey("test-key")
        let models = try await client.fetchModels(apiKey: "test-key")

        XCTAssertEqual(key.label, "Third Hand")
        XCTAssertEqual(requestedPaths, ["/api/v1/key", "/api/v1/models"])
        XCTAssertEqual(models.map(\.id), ["a/model", "z/model"])
        XCTAssertEqual(models.first?.contextLength, 16_000)
    }

    func testHTTPFailureDoesNotIncludeCredentialInLocalizedError() async throws {
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        OpenRouterURLProtocolStub.handler = { _ in
            (
                401,
                Data(#"{"error":{"message":"Invalid bearer token"}}"#.utf8)
            )
        }

        do {
            _ = try await OpenRouterAPIClient(session: session)
                .validateAPIKey("never-leak-this-key")
            XCTFail("Expected an HTTP error")
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(description.contains("401"))
            XCTAssertFalse(description.contains("never-leak-this-key"))
        }
    }

    private func makeStubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenRouterURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private struct StubOpenRouterCredentialStore: OpenRouterCredentialStoring {
    let apiKey: String?

    func loadAPIKey() throws -> String? { apiKey }
    func saveAPIKey(_ apiKey: String) throws {}
    func deleteAPIKey() throws {}
}

private func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            return nil
        }
        if count == 0 {
            break
        }
        data.append(buffer, count: count)
    }
    return data
}

private final class OpenRouterURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
