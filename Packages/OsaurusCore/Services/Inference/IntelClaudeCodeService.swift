//
//  IntelClaudeCodeService.swift
//  OsaurusCore
//
//  Claude Code CLI inference adapter for the Intel build.
//

#if OSAURUS_INTEL

import Foundation

/// Runs text-only Claude Code turns through the user's installed CLI.
/// Authentication remains owned by Claude Code; Osaurus never reads or stores
/// the subscription credential.
actor IntelClaudeCodeService {
    static let shared = IntelClaudeCodeService()

    nonisolated static func handles(_ model: String?) -> Bool {
        guard let model else { return false }
        return ClaudeCodeModel.fromPickerId(model) != nil
    }

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        let model = ClaudeCodeModel.fromPickerId(request.model ?? "") ?? .sonnet
        guard let executable = ClaudeCodeConfiguration.resolveExecutable() else {
            throw ClaudeCodeError.binaryNotFound(searchedPath: ClaudeCodeConfiguration.searchedPath())
        }

        let rendered = Self.renderPrompt(messages: request.messages)
        let systemNote = "Claude Code is connected in text-only mode. Its file, shell, and MCP tools are disabled for this chat."
        let systemPrompt = [rendered.systemPrompt, systemNote]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let arguments = ClaudeCodeConfiguration.arguments(
            model: model,
            mode: .textOnly,
            allowedTools: [],
            systemPrompt: systemPrompt
        )
        let events = ClaudeCodeProcessRunner.stream(
            executable: executable,
            arguments: arguments,
            prompt: rendered.prompt,
            workingDirectory: Self.scratchDirectory()
        )

        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let producer = Task {
            do {
                for try await event in events {
                    if Task.isCancelled { break }
                    switch event {
                    case .text(let text):
                        continuation.yield(text)
                    case .reasoning(let text):
                        continuation.yield(StreamingReasoningHint.encode(text))
                    case .stats, .toolTrace:
                        break
                    case .rateLimit(let status, let utilization, _):
                        if status != "allowed" {
                            let percent = Int((utilization * 100).rounded())
                            continuation.finish(throwing: ClaudeCodeError.rateLimited(detail: "Claude Code reported \(status) at \(percent)% utilization."))
                            return
                        }
                    case .failure(let detail):
                        continuation.finish(throwing: ClaudeCodeProcessRunner.error(forFailureDetail: detail))
                        return
                    }
                }
                continuation.finish()
            } catch {
                if Task.isCancelled { continuation.finish() }
                else { continuation.finish(throwing: error) }
            }
        }
        continuation.onTermination = { @Sendable _ in producer.cancel() }
        return stream
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        let stream = try await streamChat(request: request)
        var content = ""
        for try await delta in stream where !StreamingToolHint.isSentinel(delta) {
            content += delta
        }
        return ChatCompletionResponse(
            id: "claude-code-\(UUID().uuidString)",
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: request.model,
            choices: [
                .init(
                    index: 0,
                    message: .init(role: "assistant", content: content, tool_calls: nil, reasoning_content: nil),
                    finish_reason: "stop"
                )
            ],
            usage: nil
        )
    }

    struct RenderedPrompt: Equatable {
        let systemPrompt: String?
        let prompt: String
    }

    static func renderPrompt(messages: [ChatMessage]) -> RenderedPrompt {
        var systemParts: [String] = []
        var transcript: [String] = []
        for message in messages {
            let text = (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch message.role {
            case "system": systemParts.append(text)
            case "assistant": transcript.append("Assistant: \(text)")
            case "tool": transcript.append("Tool result: \(text)")
            default: transcript.append("User: \(text)")
            }
        }
        let prompt: String
        if transcript.count == 1, let only = transcript.first, only.hasPrefix("User: ") {
            prompt = String(only.dropFirst("User: ".count))
        } else {
            prompt = transcript.joined(separator: "\n\n")
        }
        return RenderedPrompt(
            systemPrompt: systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n"),
            prompt: prompt
        )
    }

    private static func scratchDirectory() -> URL {
        let dir = OsaurusPaths.root().appendingPathComponent("claude-code", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

#endif
