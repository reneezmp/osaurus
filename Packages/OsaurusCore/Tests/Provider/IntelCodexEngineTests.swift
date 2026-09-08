import Foundation
import Testing
@testable import OsaurusCore

/// Exercises the real engine against an in-process HTTP fixture, never a paid endpoint.
@Suite(.serialized)
struct IntelCodexEngineTests {
    private func engine(response: String, status: Int = 200, codex: Bool = true) -> ChatEngine {
        FixtureProtocol.configure(response: response, status: status)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let provider = RemoteProvider(name: "Fixture", host: "codex-fixture.invalid", providerProtocol: .https,
                                      port: nil, basePath: "/backend-api", customHeaders: [:],
                                      authType: codex ? .openAICodexOAuth : .none,
                                      providerType: codex ? .openAICodex : .openaiLegacy,
                                      enabled: true, autoConnect: false, timeout: 5)
        let credentials = IntelCodexCredentials(
            load: { _ in
                RemoteProviderOAuthTokens(
                    accessToken: "fixture-access", refreshToken: "fixture-refresh",
                    expiresAt: Date().addingTimeInterval(3600), accountId: "fixture-account"
                )
            },
            refresh: { $0 },
            save: { _, _ in true }
        )
        return ChatEngine(
            provider: provider, session: URLSession(configuration: configuration),
            credentials: credentials
        )
    }

    private func request() -> ChatCompletionRequest {
        ChatCompletionRequest(model: "fixture-model", messages: [ChatMessage(role: "system", content: "Be brief"),
                                                                 ChatMessage(role: "user", content: "Hello")])
    }

    private var success: String {
        """
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"Hello Rosy"}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_fixture","status":"completed","output":[{"id":"msg_1","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello Rosy"}]}],"usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12}}}

        """
    }

    @Test func streamingUsesResponsesBodyAndOAuthHeaders() async throws {
        let engine = engine(response: success)
        var output = ""
        for try await text in try await engine.streamChat(request: request()) { output += text }
        #expect(output == "Hello Rosy")
        let sent = try #require(FixtureProtocol.lastRequest)
        #expect(sent.url?.path == "/backend-api/codex/responses")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
        #expect(sent.value(forHTTPHeaderField: "chatgpt-account-id") == "fixture-account")
        let body = try #require(FixtureProtocol.lastBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["messages"] == nil)
        #expect(json["input"] is [[String: Any]])
        #expect(json["store"] as? Bool == false)
        #expect(json["stream"] as? Bool == true)
        #expect(json["stream_options"] == nil)
    }

    @Test func completeChatCollectsResponsesStream() async throws {
        let result = try await engine(response: success).completeChat(request: request())
        #expect(result.choices.first?.message?.content == "Hello Rosy")
    }

    @Test func streamWithoutTerminalCompletionFails() async throws {
        let engine = engine(response: "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":\"partial\"}\n\n")
        await #expect(throws: (any Error).self) {
            for try await _ in try await engine.streamChat(request: request()) {}
        }
    }

    @Test func failureEventIsNotAnEmptySuccess() async throws {
        let engine = engine(response: "data: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"message\":\"fixture rejected\"}}}\n\n")
        await #expect(throws: (any Error).self) {
            for try await _ in try await engine.streamChat(request: request()) {}
        }
    }

    @Test func forbiddenHTTPIsReported() async throws {
        let engine = engine(response: "{\"error\":{\"message\":\"fixture forbidden\"}}", status: 403)
        await #expect(throws: (any Error).self) {
            for try await _ in try await engine.streamChat(request: request()) {}
        }
    }

    @Test func ordinaryChatCompletionStreamStillWorks() async throws {
        let engine = engine(response: "data: {\"choices\":[{\"delta\":{\"content\":\"ordinary\"}}]}\n\ndata: [DONE]\n\n", codex: false)
        var output = ""
        for try await text in try await engine.streamChat(request: request()) { output += text }
        #expect(output == "ordinary")
        let body = try #require(FixtureProtocol.lastBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["messages"] != nil)
        #expect(json["input"] == nil)
    }
}

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseText = ""
    nonisolated(unsafe) private static var statusCode = 200
    nonisolated(unsafe) private static var captured: URLRequest?
    nonisolated(unsafe) private static var capturedBody: Data?
    static var lastRequest: URLRequest? { lock.lock(); defer { lock.unlock() }; return captured }
    static var lastBody: Data? { lock.lock(); defer { lock.unlock() }; return capturedBody }
    static func configure(response: String, status: Int) {
        lock.lock(); defer { lock.unlock() }
        responseText = response; statusCode = status; captured = nil; capturedBody = nil
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "codex-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            var collected = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                collected.append(contentsOf: bytes.prefix(count))
            }
            body = collected
        }
        Self.lock.lock()
        Self.captured = request; Self.capturedBody = body
        let text = Self.responseText; let code = Self.statusCode
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
