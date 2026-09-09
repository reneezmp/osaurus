//
//  CloudChatEngine.swift
//  OsaurusCore
//
//  M10 Phase 1: cloud-backed ChatEngine for Intel fork.
//  Replaces the excluded ChatEngine.swift and ChatEngineProtocol.swift.
//

#if OSAURUS_INTEL

import Foundation

// MARK: - Protocol (mirrors excluded ChatEngineProtocol.swift)

protocol ChatEngineProtocol: Sendable {
    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error>
    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse
}

// MARK: - Response type (mirrors excluded OpenAIAPI.swift)

struct ChatCompletionResponse: Codable, Sendable {
    let id: String?
    let object: String?
    let created: Int?
    let model: String?
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Codable, Sendable {
        let index: Int?
        let message: ResponseMessage?
        let finish_reason: String?
    }

    struct ResponseMessage: Codable, Sendable {
        let role: String?
        let content: String?
        let tool_calls: [ToolCall]?
        let reasoning_content: String?
    }

    struct Usage: Codable, Sendable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
    }
}

// MARK: - Errors

/// Surfaced when the provider returns a non-2xx HTTP status. Previously the
/// streaming path logged the status but then fell into the SSE parse loop,
/// found no `data:` lines in the JSON error body, reported "0 chunks", and
/// finished silently — the user saw an empty "poof" turn with no explanation.
enum CloudChatError: LocalizedError {
    case httpError(provider: String, status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case let .httpError(provider, status, message):
            let detail = message.isEmpty ? "no details returned" : message
            return "\(provider) API error \(status): \(detail)"
        }
    }
}

/// Pull a human-readable message out of an OpenAI-style error body
/// (`{"error":{"message":"…"}}`), falling back to the raw text.
private func extractAPIErrorMessage(_ body: String) -> String {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if let data = trimmed.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
        if let err = json["error"] as? [String: Any],
            let msg = err["message"] as? String, !msg.isEmpty
        {
            return msg
        }
        if let msg = json["message"] as? String, !msg.isEmpty { return msg }
    }
    return trimmed
}

// MARK: - Cloud Chat Engine

actor ChatEngine: Sendable, ChatEngineProtocol {
    private let model: String
    private let apiBase: String
    private let providerOverride: RemoteProvider?
    private let session: URLSession
    private let credentials: IntelCodexCredentials
    private var codexResponsesLiteSessionIds: [String: String] = [:]
    private var codexResponsesLiteSessionOrder: [String] = []

    init(
        source: InferenceSource = .httpAPI,
        model: String = "deepseek-v4-pro",
        provider: RemoteProvider? = nil,
        session: URLSession = .shared,
        credentials: IntelCodexCredentials = .shared
    ) {
        self.model = model
        self.providerOverride = provider
        self.session = session
        self.credentials = credentials
        self.apiBase = "https://api.deepseek.com/v1/chat/completions"
    }

    /// Accumulates one streamed tool call across DeepSeek's incremental
    /// `delta.tool_calls` fragments (id + name arrive first, arguments stream
    /// in pieces, keyed by `index`).
    private struct PartialToolCall {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }

    /// Serialize a ChatMessage into the OpenAI-compatible request shape,
    /// INCLUDING `tool_calls` (assistant) and `tool_call_id` (tool results) —
    /// the original Intel engine dropped both, so multi-turn tool context was
    /// lost. (M12 Gap 3.)
    private func encodeMessage(_ msg: ChatMessage) -> [String: Any] {
        var m: [String: Any] = ["role": msg.role]
        m["content"] = msg.content ?? ""
        if let calls = msg.tool_calls, !calls.isEmpty {
            m["tool_calls"] = calls.map { call -> [String: Any] in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.function.name,
                        "arguments": call.function.arguments,
                    ],
                ]
            }
        }
        if let tcid = msg.tool_call_id { m["tool_call_id"] = tcid }
        return m
    }

    /// Repair a (possibly restored) wire-message sequence so it satisfies
    /// DeepSeek's strict tool-call schema. Sessions persisted by earlier Intel
    /// builds could drop `tool_call_id` on tool-result turns; DeepSeek then
    /// rejects the ENTIRE request with `400 … messages[N]: missing field
    /// tool_call_id`, permanently bricking that conversation. We rebuild a
    /// valid sequence:
    ///   • each `assistant.tool_calls` entry is guaranteed a non-empty id;
    ///   • each following `tool` message is matched, in order, to a pending
    ///     call id (preserving an already-valid id, backfilling a missing one);
    ///   • a `tool` message with no pending call is demoted to plain user text
    ///     so its content survives without breaking the schema;
    ///   • an `assistant.tool_calls` left unanswered gets synthetic empty tool
    ///     results so it isn't a dangling call.
    static func sanitizeToolSequence(_ input: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var pending: [String] = []  // call ids awaiting a tool result, in order
        // Deterministic counter for backfilling missing call ids (see below).
        var synthCounter = 0

        func flushPending() {
            for id in pending {
                out.append(["role": "tool", "tool_call_id": id, "content": "(no result)"])
            }
            pending.removeAll()
        }

        for var msg in input {
            switch msg["role"] as? String {
            case "assistant":
                flushPending()
                if var calls = msg["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                    var ids: [String] = []
                    for i in calls.indices {
                        var id = (calls[i]["id"] as? String) ?? ""
                        if id.isEmpty {
                            // DETERMINISTIC synthetic id. This used to be a random
                            // UUID, regenerated on EVERY resend — so a tool-call
                            // message with a missing id (e.g. a conversation restored
                            // from an older build that dropped ids) produced different
                            // bytes each request, and DeepSeek's prefix cache missed on
                            // everything after the first tool call, re-billing the whole
                            // conversation every turn. A position-stable id keeps the
                            // resent history byte-identical so the cache holds.
                            // (Renée, 2026-06-12 — 11M cache-miss tokens.)
                            id = "call_synth_\(synthCounter)"
                            synthCounter += 1
                        }
                        calls[i]["id"] = id
                        ids.append(id)
                    }
                    msg["tool_calls"] = calls
                    pending = ids
                }
                out.append(msg)
            case "tool":
                let existing = (msg["tool_call_id"] as? String) ?? ""
                if !existing.isEmpty, let idx = pending.firstIndex(of: existing) {
                    pending.remove(at: idx)
                    out.append(msg)  // already valid
                } else if !pending.isEmpty {
                    msg["tool_call_id"] = pending.removeFirst()
                    out.append(msg)  // backfilled
                } else {
                    // Orphan tool result — preserve content as user text.
                    let content = (msg["content"] as? String) ?? ""
                    out.append(["role": "user", "content": content.isEmpty ? "(tool result)" : content])
                }
            default:
                flushPending()
                out.append(msg)
            }
        }
        flushPending()
        return out
    }

    /// OpenAI-compatible `tools` array from the request's tool specs. The
    /// JSON-Schema `parameters` come through `JSONValue.anyValue`.
    private func encodeTools(_ tools: [Tool]?) -> [[String: Any]]? {
        guard let tools, !tools.isEmpty else { return nil }
        return tools.map { tool in
            var fn: [String: Any] = ["name": tool.function.name]
            if let desc = tool.function.description { fn["description"] = desc }
            if let params = tool.function.parameters { fn["parameters"] = params.anyValue }
            return ["type": "function", "function": fn]
        }
    }

    private func applyReasoningMode(_ request: ChatCompletionRequest, into body: inout [String: Any]) {
        // DSV4 reasoning-mode translation (see RemoteProviderService.dsv4RemoteEffort).
        let effort = request.modelOptions?["reasoningEffort"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch effort {
        case "instruct", "chat", "none", "no_think", "nothink", "off", "disabled", "false":
            body["thinking"] = ["type": "disabled"]
        case .some(let nonEmpty) where !nonEmpty.isEmpty:
            body["reasoning_effort"] = nonEmpty
        case .some, .none:
            body["thinking"] = ["type": "disabled"]
        }
    }

    /// Resolve the API key. Order: the `DEEPSEEK_API_KEY` env var (dev
    /// convenience on the build machine), then the key the user saved in
    /// Settings → Providers (stored in the Keychain via RemoteProviderKeychain).
    /// The provider fallback is what lets a double-clicked app — e.g. on Rosy —
    /// work without launching from a terminal with an env var.
    private func resolveAPIKey() async -> String? {
        if let env = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"],
            !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env
        }
        return await MainActor.run {
            let providers = RemoteProviderManager.shared.configuration.providers.filter { $0.enabled }
            // Prefer a provider pointed at this engine's host (DeepSeek); fall
            // back to any enabled provider that has a stored key.
            let ordered = providers.sorted { a, b in
                a.host.localizedCaseInsensitiveContains("deepseek")
                    && !b.host.localizedCaseInsensitiveContains("deepseek")
            }
            for p in ordered {
                if let key = RemoteProviderKeychain.getAPIKey(for: p.id),
                    !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return key
                }
            }
            return nil
        }
    }

    /// The resolved HTTP target for a chat request: which URL to POST to and
    /// the auth/extra headers to send.
    private struct ResolvedEndpoint {
        let url: String
        var headers: [String: String]
        let providerLabel: String
        let modelId: String
        /// When true, the request body must be EIP-191 wallet-signed via
        /// `OsaurusRouterAuthSigner` (the hosted Osaurus Router uses signed
        /// `x-wallet-*` headers instead of a Bearer key).
        var isOsaurusRouter: Bool = false
        var provider: RemoteProvider? = nil
        var isCodex: Bool { provider?.providerType == .openAICodex || provider?.authType == .openAICodexOAuth }
    }

    /// Resolve the endpoint + headers for `model`. On Intel a request can route
    /// to EITHER the built-in DeepSeek path (hardcoded URL + `DEEPSEEK_API_KEY`
    /// / saved key) OR any user-configured provider that lists `model` in its
    /// `manualModelIds`. The latter is what lets a local llama.cpp server
    /// (Bonsai) or any OpenAI-compatible endpoint actually receive the request
    /// instead of it silently going to DeepSeek. Order:
    ///   1. An enabled provider that declares `model` wins — its baseURL +
    ///      per-`authType` headers. A no-auth local server is fine (no key).
    ///   2. Otherwise the built-in DeepSeek fallback.
    /// Returns nil only when neither a provider endpoint nor a DeepSeek key is
    /// available, so the caller can surface a clear error.
    private func resolveEndpoint(forModel model: String) async throws -> ResolvedEndpoint? {
        if let provider = providerOverride {
            let path = provider.authType == .openAICodexOAuth ? "/codex/responses" : provider.providerType.chatEndpoint
            guard let url = provider.url(for: path) else { throw EngineError(message: "Invalid provider URL") }
            return ResolvedEndpoint(url: url.absoluteString, headers: [:], providerLabel: provider.name,
                                    modelId: Self.bareModelId(model, for: provider),
                                    isOsaurusRouter: provider.providerType == .osaurusRouter, provider: provider)
        }
        let providerEndpoint: ResolvedEndpoint? = await MainActor.run {
            let manager = RemoteProviderManager.shared
            let providers = manager.configuration.providers.filter { $0.enabled }
            // Match the selected model against each provider's known ids:
            // live-discovered (`/models` probe) ∪ user-typed `manualModelIds`.
            let matchingProviders = providers.filter { provider in
                let discovered = manager.providerStates[provider.id]?.discoveredModels ?? []
                let bare = Self.bareModelId(model, for: provider)
                return discovered.contains(bare) || provider.manualModelIds.contains(bare)
            }
            let owner: RemoteProvider?
            if model.contains("/") {
                owner = matchingProviders.first {
                    model.lowercased().hasPrefix(Self.providerPrefix($0.name) + "/")
                }
            } else {
                // Backward compatibility for old bare-id sessions. Route only
                // when ownership is unambiguous; duplicate ids stay inert until
                // the picker saves a provider-qualified id.
                owner = matchingProviders.count == 1 ? matchingProviders[0] : nil
            }
            // Use the provider's own chat endpoint, not a hardcoded path: the
            // Osaurus Router serves OpenAI-compatible inference under `/v1/...`
            // (its account API lives at root) while its provider `basePath` is
            // empty, so the `/v1` must come from `chatEndpoint`. Standard
            // OpenAI-compatible providers still resolve to `/chat/completions`
            // with any `/v1` carried by their own `basePath`.
            guard let owner else { return nil }
            let path = owner.authType == .openAICodexOAuth ? "/codex/responses" : owner.providerType.chatEndpoint
            guard let url = owner.url(for: path) else { return nil }

            // Credential reads happen after leaving MainActor, below.
            return ResolvedEndpoint(
                url: url.absoluteString,
                headers: [:],
                providerLabel: owner.name,
                modelId: Self.bareModelId(model, for: owner),
                isOsaurusRouter: owner.providerType == .osaurusRouter,
                provider: owner
            )
        }
        if var providerEndpoint {
            providerEndpoint.headers = try await requestHeaders(for: providerEndpoint)
            NSLog(
                "[CloudChatEngine] Routing model=\(model) → provider '\(providerEndpoint.providerLabel)' @ \(providerEndpoint.url)"
            )
            return providerEndpoint
        }
        // Built-in DeepSeek fallback.
        guard let key = await resolveAPIKey() else { return nil }
        return ResolvedEndpoint(
            url: apiBase,
            headers: ["Content-Type": "application/json", "Authorization": "Bearer \(key)"],
            providerLabel: "DeepSeek",
            modelId: model.split(separator: "/", maxSplits: 1).last.map(String.init) ?? model
        )
    }

    private nonisolated static func providerPrefix(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }

    private nonisolated static func bareModelId(_ model: String, for provider: RemoteProvider) -> String {
        let prefix = providerPrefix(provider.name) + "/"
        guard model.lowercased().hasPrefix(prefix) else { return model }
        return String(model.dropFirst(prefix.count))
    }

    private func requestHeaders(for endpoint: ResolvedEndpoint) async throws -> [String: String] {
        guard let provider = endpoint.provider else { return endpoint.headers }
        if endpoint.isCodex {
            let tokens = try await credentials.tokens(for: provider.id)
            var headers = await provider.resolvedHeadersOffMainActor()
            // Use the refreshed value, not an independently cached token.
            headers["Authorization"] = "Bearer \(tokens.accessToken)"
            headers["chatgpt-account-id"] = tokens.accountId
            headers["OpenAI-Beta"] = "responses=experimental"
            headers["originator"] = "codex_cli_rs"
            headers["User-Agent"] = OpenAICodexOAuthService.codexUserAgent()
            headers["Accept"] = "text/event-stream"
            headers["Content-Type"] = "application/json"
            return headers
        }
        var headers = await provider.resolvedHeadersOffMainActor()
        if headers["Content-Type"] == nil { headers["Content-Type"] = "application/json" }
        return headers
    }

    private func codexResponsesLiteSessionId(for sourceKey: String?) -> String {
        let key = sourceKey.flatMap { $0.isEmpty ? nil : $0 } ?? "request-\(UUID().uuidString)"
        if let existing = codexResponsesLiteSessionIds[key] { return existing }
        if codexResponsesLiteSessionIds.count >= 1_024,
            let oldest = codexResponsesLiteSessionOrder.first
        {
            codexResponsesLiteSessionIds.removeValue(forKey: oldest)
            codexResponsesLiteSessionOrder.removeFirst()
        }
        let generated = Self.makeUUIDv7()
        codexResponsesLiteSessionIds[key] = generated
        codexResponsesLiteSessionOrder.append(key)
        return generated
    }

    static func makeUUIDv7(now: Date = Date(), randomUUID: UUID = UUID()) -> String {
        var bytes = withUnsafeBytes(of: randomUUID.uuid) { Array($0) }
        let milliseconds = UInt64(max(0, now.timeIntervalSince1970 * 1_000))
        bytes[0] = UInt8((milliseconds >> 40) & 0xff)
        bytes[1] = UInt8((milliseconds >> 32) & 0xff)
        bytes[2] = UInt8((milliseconds >> 24) & 0xff)
        bytes[3] = UInt8((milliseconds >> 16) & 0xff)
        bytes[4] = UInt8((milliseconds >> 8) & 0xff)
        bytes[5] = UInt8(milliseconds & 0xff)
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }
        return "\(hex[0...3].joined())-\(hex[4...5].joined())-\(hex[6...7].joined())-\(hex[8...9].joined())-\(hex[10...15].joined())"
    }

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        let resolvedModel = request.model ?? model
        if IntelClaudeCodeService.handles(resolvedModel) {
            return try await IntelClaudeCodeService.shared.streamChat(request: request)
        }
        let toolSpecs = encodeTools(request.tools)

        guard let endpoint = try await resolveEndpoint(forModel: resolvedModel) else {
            throw EngineError(
                message:
                    "No endpoint for model \"\(resolvedModel)\". Add a provider (and key, if it needs one) in Settings → Providers, or set the DEEPSEEK_API_KEY env var."
            )
        }
        let usesResponsesLite = endpoint.isCodex
            && OpenAICodexOAuthService.usesResponsesLite(modelId: endpoint.modelId)
        let responsesLiteSessionId = usesResponsesLite
            ? codexResponsesLiteSessionId(for: request.session_id)
            : nil

        NSLog("[CloudChatEngine] Starting streamChat — model=\(resolvedModel), via=\(endpoint.providerLabel), messages=\(request.messages.count), tools=\(request.tools?.count ?? 0)")

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Running conversation as wire dicts. We append the
                    // assistant tool-call message + tool-result messages after
                    // each tool round so the continuation request carries the
                    // full context. (M12 Gap 3 — engine-side agent loop, since
                    // the upstream RemoteProviderService tool path is amputated
                    // on Intel.)
                    var wireMessages = Self.sanitizeToolSequence(
                        request.messages.map { self.encodeMessage($0) }
                    )
                    var codexReplayItems: [[String: Any]] = []
                    let maxToolRounds = 12
                    var round = 0
                    var totalChunks = 0

                    while round < maxToolRounds {
                        try Task.checkCancellation()
                        round += 1

                        var body: [String: Any] = [
                            "model": endpoint.modelId,
                            "messages": wireMessages,
                            "stream": true,
                        ]
                        if let toolSpecs {
                            body["tools"] = toolSpecs
                            body["tool_choice"] = "auto"
                        }
                        if endpoint.isCodex {
                            if let effort = request.modelOptions?["reasoningEffort"]?.stringValue?
                                .trimmingCharacters(in: .whitespacesAndNewlines),
                                !effort.isEmpty,
                                !["off", "disabled", "false", "none"].contains(effort.lowercased())
                            {
                                body["reasoning_effort"] = effort.lowercased()
                            }
                            body = try IntelCodexResponsesAdapter.makeRequest(
                                chatCompletions: body,
                                responsesLiteSessionId: responsesLiteSessionId
                            )
                            var input = body["input"] as? [[String: Any]] ?? []
                            input.append(contentsOf: codexReplayItems)
                            body["input"] = input
                        } else {
                            // Ask for a final usage chunk so the prompt-cache hit/miss
                            // split is observable per request (logged below).
                            body["stream_options"] = ["include_usage": true]
                            self.applyReasoningMode(request, into: &body)
                        }

                        var urlRequest = URLRequest(url: URL(string: endpoint.url)!)
                        urlRequest.httpMethod = "POST"
                        for (k, v) in try await self.requestHeaders(for: endpoint) { urlRequest.setValue(v, forHTTPHeaderField: k) }
                        if let responsesLiteSessionId {
                            urlRequest.setValue(responsesLiteSessionId, forHTTPHeaderField: "session-id")
                            urlRequest.setValue(responsesLiteSessionId, forHTTPHeaderField: "x-session-affinity")
                            urlRequest.setValue(OpenAICodexOAuthService.codexClientVersion, forHTTPHeaderField: "version")
                            urlRequest.setValue("true", forHTTPHeaderField: "x-openai-internal-codex-responses-lite")
                        }
                        urlRequest.timeoutInterval = 300
                        // CANONICAL (sorted-key) serialization — bare JSONSerialization emits
        // keys in hash order, which differs across app launches (and can differ
        // per nested dict), changing the request bytes for a logically-identical
        // conversation. DeepSeek's prompt cache only matches a BYTE-identical
        // prefix, so non-canonical bytes meant every request missed the cache and
        // re-billed the whole history. Matches upstream's osaurusCanonical wire
        // contract (JSONDeterminism.swift). (Renée, 2026-06-13 — 11M cache miss.)
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: body, options: .osaurusCanonical)
                        // Osaurus Router: EIP-191 wallet-sign the request body.
                        if endpoint.isOsaurusRouter {
                            try await OsaurusRouterAuthSigner().sign(
                                request: &urlRequest, body: urlRequest.httpBody)
                        }
                        NSLog("[CloudChatEngine] Request body: model=\(resolvedModel) round=\(round) tools=\(toolSpecs?.count ?? 0)")

                        let (asyncBytes, response) = try await self.session.bytes(for: urlRequest)
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                        NSLog("[CloudChatEngine] HTTP status: \(statusCode)")
                        if !(200...299).contains(statusCode) {
                            // Non-2xx: the body is a JSON error, not an SSE
                            // stream. Drain it, log it, and surface it so the
                            // user sees WHY instead of a silent empty turn.
                            var errorBody = ""
                            for try await line in asyncBytes.lines { errorBody += line }
                            let message = extractAPIErrorMessage(errorBody)
                            NSLog("[CloudChatEngine] HTTP \(statusCode) error body: \(message)")
                            continuation.finish(
                                throwing: CloudChatError.httpError(
                                    provider: endpoint.providerLabel, status: statusCode, message: message)
                            )
                            return
                        }

                        var assistantContent = ""
                        var partials: [Int: PartialToolCall] = [:]
                        var announcedNames: Set<Int> = []

                        if endpoint.isCodex {
                            let allowedTools = Set(request.tools?.map { $0.function.name } ?? [])
                            var decoder = IntelCodexResponsesSSEDecoder(allowedToolNames: allowedTools)
                            var buffer = Data()
                            for try await byte in asyncBytes {
                                try Task.checkCancellation()
                                buffer.append(byte)
                                if buffer.count >= 2_048 {
                                    for emission in try decoder.append(buffer) {
                                        totalChunks += 1
                                        continuation.yield(emission)
                                    }
                                    buffer.removeAll(keepingCapacity: true)
                                }
                            }
                            if !buffer.isEmpty {
                                for emission in try decoder.append(buffer) {
                                    totalChunks += 1
                                    continuation.yield(emission)
                                }
                            }
                            let finalized = try decoder.finish()
                            for emission in finalized.emissions {
                                totalChunks += 1
                                continuation.yield(emission)
                            }
                            if finalized.completion.toolCalls.isEmpty {
                                NSLog("[CloudChatEngine] Codex stream finished — \(totalChunks) chunks, \(round) round(s)")
                                continuation.finish()
                                return
                            }

                            var results: [IntelCodexResponsesToolResult] = []
                            for call in finalized.completion.toolCalls {
                                try Task.checkCancellation()
                                guard request.tools?.contains(where: { $0.function.name == call.name }) == true else {
                                    throw EngineError(message: "The provider requested a tool that was not offered: \(call.name)")
                                }
                                let policy = ToolRegistry.shared.policyInfo(for: call.name)?.effectivePolicy ?? .auto
                                let approved: Bool
                                switch policy {
                                case .deny: approved = false
                                case .auto: approved = true
                                case .ask:
                                    let description = request.tools?.first(where: { $0.function.name == call.name })?.function.description ?? ""
                                    approved = await ToolPermissionPromptService.requestApproval(
                                        toolName: call.name,
                                        description: description,
                                        argumentsJSON: call.arguments
                                    )
                                }
                                let result: String
                                if !approved {
                                    let reason = policy == .deny
                                        ? "blocked by your tool permissions (Deny)"
                                        : "you declined to run it this time"
                                    result = "⛔️ “\(call.name)” was not run — \(reason)."
                                } else {
                                    do {
                                        result = try await ToolRegistry.shared.execute(
                                            name: call.name,
                                            argumentsJSON: call.arguments
                                        )
                                    } catch {
                                        result = ToolEnvelope.fromError(error, tool: call.name)
                                    }
                                }
                                continuation.yield(
                                    StreamingToolHint.encodeDone(
                                        callId: call.callID,
                                        name: call.name,
                                        arguments: call.arguments,
                                        result: result
                                    )
                                )
                                results.append(.init(callID: call.callID, output: result))
                            }
                            codexReplayItems.append(
                                contentsOf: try finalized.completion.replayInputItems(toolResults: results)
                            )
                            continue
                        }

                        for try await line in asyncBytes.lines {
                            try Task.checkCancellation()
                            guard line.hasPrefix("data: ") else { continue }
                            let dataStr = String(line.dropFirst(6))
                            if dataStr == "[DONE]" { break }

                            guard let chunkData = dataStr.data(using: .utf8),
                                let json = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any]
                            else {
                                // Shape only — never log payload bytes; SSE frames carry
                                // the user's conversation content.
                                NSLog(
                                    "[CloudChatEngine] Skipped unparseable SSE frame (\(dataStr.utf8.count) bytes)"
                                )
                                continue
                            }

                            // DeepSeek's final usage chunk (from stream_options) carries
                            // the prompt-cache split. Log it so cache hit/miss is
                            // measurable per request in Console.app.
                            if let usage = json["usage"] as? [String: Any] {
                                let hit = usage["prompt_cache_hit_tokens"] as? Int ?? -1
                                let miss = usage["prompt_cache_miss_tokens"] as? Int ?? -1
                                let promptTok = usage["prompt_tokens"] as? Int ?? -1
                                NSLog(
                                    "[CloudChatEngine] CACHE prompt=\(promptTok) hit=\(hit) miss=\(miss) round=\(round)"
                                )
                            }

                            guard let choices = json["choices"] as? [[String: Any]],
                                let delta = choices.first?["delta"] as? [String: Any]
                            else {
                                // Expected for usage-only frames; also the shape the
                                // Osaurus Router's billing-summary frame arrives in.
                                // Log top-level keys only — never the payload.
                                NSLog(
                                    "[CloudChatEngine] Non-delta SSE frame keys=\(json.keys.sorted().joined(separator: ","))"
                                )
                                continue
                            }

                            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                                totalChunks += 1
                                continuation.yield(StreamingReasoningHint.encode(reasoning))
                            }
                            if let content = delta["content"] as? String, !content.isEmpty {
                                totalChunks += 1
                                assistantContent += content
                                continuation.yield(content)
                            }
                            // Accumulate streamed tool calls (M12 Gap 3).
                            if let tcs = delta["tool_calls"] as? [[String: Any]] {
                                for tc in tcs {
                                    let idx = tc["index"] as? Int ?? 0
                                    var partial = partials[idx] ?? PartialToolCall()
                                    if let id = tc["id"] as? String, !id.isEmpty { partial.id = id }
                                    if let fn = tc["function"] as? [String: Any] {
                                        if let n = fn["name"] as? String, !n.isEmpty { partial.name += n }
                                        // Surface the tool name once, BEFORE
                                        // streaming args, so the call card
                                        // appears immediately and the query
                                        // fills into it live (mirrors upstream:
                                        // card-with-query first, result later).
                                        if !partial.name.isEmpty, !announcedNames.contains(idx) {
                                            announcedNames.insert(idx)
                                            continuation.yield(StreamingToolHint.encode(partial.name))
                                        }
                                        if let a = fn["arguments"] as? String, !a.isEmpty {
                                            partial.arguments += a
                                            // Stream the args into the pending
                                            // card so the user sees the query
                                            // build up — not just a bare name.
                                            continuation.yield(StreamingToolHint.encodeArgs(a))
                                        }
                                    }
                                    partials[idx] = partial
                                }
                            }
                        }

                        // No tools requested this round → the assistant's final
                        // answer has streamed; we're done.
                        if partials.isEmpty {
                            NSLog("[CloudChatEngine] Stream finished — \(totalChunks) chunks, \(round) round(s), no tool calls")
                            continuation.finish()
                            return
                        }

                        // Echo the assistant's tool-call message into the
                        // continuation context.
                        let orderedCalls = partials.sorted { $0.key < $1.key }.map { $0.value }
                        wireMessages.append([
                            "role": "assistant",
                            "content": assistantContent,
                            "tool_calls": orderedCalls.map { call in
                                [
                                    "id": call.id,
                                    "type": "function",
                                    "function": ["name": call.name, "arguments": call.arguments],
                                ]
                            },
                        ])

                        // Execute each tool, surface the result card, and feed
                        // the result back as a tool message.
                        for call in orderedCalls {
                            try Task.checkCancellation()
                            guard request.tools?.contains(where: { $0.function.name == call.name }) == true else {
                                throw EngineError(message: "The provider requested a tool that was not offered: \(call.name)")
                            }
                            let callId = call.id.isEmpty ? "call_\(UUID().uuidString.prefix(20))" : call.id
                            let result: String
                            let toolStart = Date()

                            // Enforce the user's per-tool permission policy
                            // (Tools / Permissions tab). Deny blocks the tool;
                            // Ask shows a confirmation before running; Auto runs.
                            let policy =
                                ToolRegistry.shared.policyInfo(for: call.name)?.effectivePolicy ?? .auto
                            let approved: Bool
                            switch policy {
                            case .deny:
                                approved = false
                            case .auto:
                                approved = true
                            case .ask:
                                // Real upstream permission card (ToolPermissionView via
                                // ToolPermissionPromptService) — Allow / Deny / Always Allow.
                                // "Always Allow" persists the policy internally.
                                let toolDescription =
                                    request.tools?
                                    .first(where: { $0.function.name == call.name })?
                                    .function.description ?? ""
                                approved = await ToolPermissionPromptService.requestApproval(
                                    toolName: call.name,
                                    description: toolDescription,
                                    argumentsJSON: call.arguments)
                            }

                            if !approved {
                                let reason =
                                    policy == .deny
                                    ? "blocked by your tool permissions (Deny)"
                                    : "you declined to run it this time"
                                NSLog("[CloudChatEngine] tool '\(call.name)' not run — \(reason)")
                                result = "⛔️ “\(call.name)” was not run — \(reason)."
                            } else {
                                NSLog("[CloudChatEngine] executing tool '\(call.name)' args=\(call.arguments.prefix(200))")
                                do {
                                    result = try await ToolRegistry.shared.execute(
                                        name: call.name,
                                        argumentsJSON: call.arguments
                                    )
                                    NSLog("[CloudChatEngine] tool '\(call.name)' finished in \(String(format: "%.1f", Date().timeIntervalSince(toolStart)))s (result \(result.count) chars)")
                                } catch {
                                    NSLog("[CloudChatEngine] tool '\(call.name)' THREW after \(String(format: "%.1f", Date().timeIntervalSince(toolStart)))s: \(error.localizedDescription)")
                                    result = ToolEnvelope.fromError(error, tool: call.name)
                                }
                            }
                            continuation.yield(
                                StreamingToolHint.encodeDone(
                                    callId: callId,
                                    name: call.name,
                                    arguments: call.arguments,
                                    result: result
                                )
                            )
                            wireMessages.append([
                                "role": "tool",
                                "tool_call_id": callId,
                                "content": result,
                            ])
                        }
                        // Loop: send the continuation request with tool results.
                    }

                    NSLog("[CloudChatEngine] Tool loop hit max rounds (\(maxToolRounds))")
                    continuation.finish(throwing: EngineError(message: "Tool-call limit reached before the response completed."))
                } catch {
                    NSLog("[CloudChatEngine] Stream error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        let resolvedModel = request.model ?? model
        if IntelClaudeCodeService.handles(resolvedModel) {
            return try await IntelClaudeCodeService.shared.completeChat(request: request)
        }
        guard let endpoint = try await resolveEndpoint(forModel: resolvedModel) else {
            throw EngineError(
                message:
                    "No endpoint for model \"\(resolvedModel)\". Add a provider (and key, if it needs one) in Settings → Providers, or set the DEEPSEEK_API_KEY env var."
            )
        }

        if endpoint.isCodex {
            let stream = try await streamChat(request: request)
            var content = ""
            for try await delta in stream where !StreamingToolHint.isSentinel(delta) {
                content += delta
            }
            return ChatCompletionResponse(
                id: "codex-\(UUID().uuidString)",
                object: "chat.completion",
                created: Int(Date().timeIntervalSince1970),
                model: resolvedModel,
                choices: [
                    .init(
                        index: 0,
                        message: .init(
                            role: "assistant", content: content,
                            tool_calls: nil, reasoning_content: nil
                        ),
                        finish_reason: "stop"
                    )
                ],
                usage: nil
            )
        }

        var urlRequest = URLRequest(url: URL(string: endpoint.url)!)
        urlRequest.httpMethod = "POST"
        for (k, v) in try await requestHeaders(for: endpoint) { urlRequest.setValue(v, forHTTPHeaderField: k) }
        urlRequest.timeoutInterval = 300

        var body: [String: Any] = [
            "model": endpoint.modelId,
            "messages": request.messages.map { msg -> [String: Any] in
                var m: [String: Any] = ["role": msg.role]
                if let content = msg.content { m["content"] = content }
                return m
            },
            "stream": false,
        ]
        // Honor max_tokens + temperature, and apply reasoning control. Without
        // this a reasoning core model could spend the whole budget on
        // reasoning_content and return empty content — which is exactly why
        // model-generated chat titles came back blank. With no modelOptions,
        // applyReasoningMode disables thinking (fast, deterministic for titles).
        if let maxTokens = request.max_tokens { body["max_tokens"] = maxTokens }
        if let temperature = request.temperature { body["temperature"] = temperature }
        applyReasoningMode(request, into: &body)

        // CANONICAL (sorted-key) serialization — bare JSONSerialization emits
        // keys in hash order, which differs across app launches (and can differ
        // per nested dict), changing the request bytes for a logically-identical
        // conversation. DeepSeek's prompt cache only matches a BYTE-identical
        // prefix, so non-canonical bytes meant every request missed the cache and
        // re-billed the whole history. Matches upstream's osaurusCanonical wire
        // contract (JSONDeterminism.swift). (Renée, 2026-06-13 — 11M cache miss.)
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: body, options: .osaurusCanonical)
        // Osaurus Router: EIP-191 wallet-sign the request body.
        if endpoint.isOsaurusRouter {
            try await OsaurusRouterAuthSigner().sign(request: &urlRequest, body: urlRequest.httpBody)
        }

        let (data, response) = try await session.data(for: urlRequest)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(statusCode) {
            let message = extractAPIErrorMessage(String(data: data, encoding: .utf8) ?? "")
            NSLog("[CloudChatEngine] completeChat HTTP \(statusCode) error body: \(message)")
            throw CloudChatError.httpError(
                provider: endpoint.providerLabel, status: statusCode, message: message)
        }
        return try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
    }

    struct EngineError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

#endif
