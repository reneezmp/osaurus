//
//  IntelCodexResponsesAdapter.swift
//  OsaurusCore
//
//  Self-contained Intel bridge for Codex's Responses wire protocol.  This file
//  deliberately does not route requests, resolve credentials, or execute tools.
//  CloudChatEngine owns those concerns and can adopt this adapter per round.
//

#if OSAURUS_INTEL

import Foundation

/// Converts an OpenAI chat-completions-shaped dictionary to a conservative
/// Codex Responses request. Unsupported fields fail loudly so a caller never
/// sends a request whose meaning was changed by an invisible omission.
enum IntelCodexResponsesAdapter {
    enum Error: LocalizedError, Equatable {
        case invalidInput(String)
        case unsupportedInput(String)
        case malformedEvent(String)
        case unsupportedOutput(String)
        case unknownTool(String)
        case terminalFailure(String)
        case incompleteStream

        var errorDescription: String? {
            switch self {
            case .invalidInput(let detail): return "Invalid Codex Responses input: \(detail)"
            case .unsupportedInput(let detail): return "Unsupported Codex Responses input: \(detail)"
            case .malformedEvent(let detail): return "Malformed Codex Responses event: \(detail)"
            case .unsupportedOutput(let detail): return "Unsupported Codex Responses output: \(detail)"
            case .unknownTool(let name): return "Codex requested unknown tool \"\(name)\"."
            case .terminalFailure(let detail): return "Codex Responses failed: \(detail)"
            case .incompleteStream: return "Codex Responses stream ended without response.completed."
            }
        }
    }

    /// The only supported integration entry point for request conversion.
    /// `chatCompletions` is the dictionary CloudChatEngine already builds for
    /// its OpenAI-compatible path. The returned value is directly JSON-serializable.
    static func makeRequest(
        chatCompletions: [String: Any],
        responsesLiteSessionId: String? = nil
    ) throws -> [String: Any] {
        let supportedKeys: Set<String> = [
            "model", "messages", "stream", "max_tokens", "max_completion_tokens",
            "tools", "tool_choice", "reasoning_effort", "reasoning",
        ]
        for key in chatCompletions.keys where !supportedKeys.contains(key) {
            throw Error.unsupportedInput("field \"\(key)\"")
        }

        guard let model = nonEmptyString(chatCompletions["model"]) else {
            throw Error.invalidInput("model must be a non-empty string")
        }
        guard let messages = chatCompletions["messages"] as? [[String: Any]] else {
            throw Error.invalidInput("messages must be an array of objects")
        }

        var instructions: [String] = []
        var input: [[String: Any]] = []
        for (messageIndex, message) in messages.enumerated() {
            try validateKeys(message, allowed: ["role", "content", "tool_calls", "tool_call_id", "reasoning_content"], path: "messages[\(messageIndex)]")
            guard let role = nonEmptyString(message["role"]) else {
                throw Error.invalidInput("messages[\(messageIndex)].role must be a non-empty string")
            }
            if message["reasoning_content"] != nil {
                // Plain chat-completions reasoning is not a replayable Codex reasoning item.
                // Replaying it as ordinary text would mutate model context, so refuse it.
                throw Error.unsupportedInput("messages[\(messageIndex)].reasoning_content; replay completed Responses output items instead")
            }
            let content = try stringContent(message["content"], path: "messages[\(messageIndex)].content")

            switch role {
            case "system", "developer":
                guard let content else {
                    throw Error.invalidInput("messages[\(messageIndex)] \(role) message needs string content")
                }
                instructions.append(content)

            case "user":
                guard let content else {
                    throw Error.invalidInput("messages[\(messageIndex)] user message needs string content")
                }
                input.append(messageItem(role: "user", content: content, contentType: "input_text"))

            case "assistant":
                if let content, !content.isEmpty {
                    // Completed assistant history is model output. Codex accepts
                    // `input_text` only for input roles; replaying an assistant
                    // turn with that tag fails on the first follow-up.
                    input.append(messageItem(role: "assistant", content: content, contentType: "output_text"))
                }
                if let callsValue = message["tool_calls"] {
                    guard let calls = callsValue as? [[String: Any]], !calls.isEmpty else {
                        throw Error.invalidInput("messages[\(messageIndex)].tool_calls must be a non-empty array")
                    }
                    for (callIndex, call) in calls.enumerated() {
                        input.append(try functionCallItem(call, messageIndex: messageIndex, callIndex: callIndex))
                    }
                } else if content == nil {
                    throw Error.invalidInput("messages[\(messageIndex)] assistant message needs content or tool_calls")
                }

            case "tool":
                guard let callID = nonEmptyString(message["tool_call_id"]), let content else {
                    throw Error.invalidInput("messages[\(messageIndex)] tool message needs tool_call_id and string content")
                }
                input.append(["type": "function_call_output", "call_id": callID, "output": content])

            default:
                throw Error.unsupportedInput("messages[\(messageIndex)].role \"\(role)\"")
            }
        }

        var payload: [String: Any] = [
            "model": model,
            "input": input,
            "store": false,
            "include": ["reasoning.encrypted_content"],
        ]
        if !instructions.isEmpty { payload["instructions"] = instructions.joined(separator: "\n") }
        if let stream = chatCompletions["stream"] {
            guard let value = stream as? Bool else { throw Error.invalidInput("stream must be Bool") }
            payload["stream"] = value
        }
        // ChatGPT-account Codex rejects output-token controls on this endpoint.
        // Accept them from the shared request shape but intentionally omit them,
        // matching upstream's OAuth payload transform.
        if let tools = chatCompletions["tools"] {
            payload["tools"] = try convertTools(tools)
        }
        if let choice = chatCompletions["tool_choice"] {
            payload["tool_choice"] = try convertToolChoice(choice)
        }
        if let effort = chatCompletions["reasoning_effort"] {
            guard let effort = nonEmptyString(effort) else { throw Error.invalidInput("reasoning_effort must be a non-empty string") }
            payload["reasoning"] = ["effort": effort, "summary": "auto", "context": "all_turns"]
        }
        if let reasoning = chatCompletions["reasoning"] {
            guard let reasoning = reasoning as? [String: Any] else { throw Error.invalidInput("reasoning must be an object") }
            try validateKeys(reasoning, allowed: ["effort", "summary", "context"], path: "reasoning")
            guard let effort = nonEmptyString(reasoning["effort"]) else { throw Error.invalidInput("reasoning.effort must be a non-empty string") }
            var codexReasoning: [String: Any] = ["effort": effort]
            if let summary = reasoning["summary"] {
                guard let summary = nonEmptyString(summary) else { throw Error.invalidInput("reasoning.summary must be a non-empty string") }
                codexReasoning["summary"] = summary
            } else {
                codexReasoning["summary"] = "auto"
            }
            if let context = reasoning["context"] {
                guard let context = nonEmptyString(context) else { throw Error.invalidInput("reasoning.context must be a non-empty string") }
                codexReasoning["context"] = context
            } else {
                codexReasoning["context"] = "all_turns"
            }
            payload["reasoning"] = codexReasoning
        }

        if let responsesLiteSessionId {
            let tools = payload["tools"] as? [Any] ?? []
            var prefix: [[String: Any]] = [
                ["type": "additional_tools", "role": "developer", "tools": tools]
            ]
            if let instructions = payload["instructions"] as? String, !instructions.isEmpty {
                prefix.append([
                    "type": "message",
                    "role": "developer",
                    "content": [["type": "input_text", "text": instructions]],
                ])
            }
            payload["input"] = prefix + input
            payload.removeValue(forKey: "tools")
            payload.removeValue(forKey: "instructions")
            payload["tool_choice"] = "auto"
            payload["parallel_tool_calls"] = false
            payload["prompt_cache_key"] = responsesLiteSessionId
            var reasoning = payload["reasoning"] as? [String: Any] ?? [:]
            reasoning["context"] = "all_turns"
            payload["reasoning"] = reasoning
        }
        return payload
    }

    private static func messageItem(role: String, content: String, contentType: String) -> [String: Any] {
        ["type": "message", "role": role, "content": [["type": contentType, "text": content]]]
    }

    private static func functionCallItem(_ call: [String: Any], messageIndex: Int, callIndex: Int) throws -> [String: Any] {
        try validateKeys(call, allowed: ["id", "type", "function"], path: "tool_calls[\(callIndex)]")
        guard let callID = nonEmptyString(call["id"]), let function = call["function"] as? [String: Any] else {
            throw Error.invalidInput("tool_calls[\(callIndex)] needs id and function")
        }
        try validateKeys(function, allowed: ["name", "arguments"], path: "tool_calls[\(callIndex)].function")
        guard let name = nonEmptyString(function["name"]), let arguments = function["arguments"] as? String else {
            throw Error.invalidInput("tool_calls[\(callIndex)].function needs name and string arguments")
        }
        return [
            "type": "function_call",
            // Responses requires an item id for replay; deterministic ids preserve
            // prompt-cache identity across a restored Intel conversation.
            "id": "fc_\(messageIndex)_\(callIndex)",
            "call_id": callID,
            "name": name,
            "arguments": arguments,
        ]
    }

    private static func convertTools(_ value: Any) throws -> [[String: Any]] {
        guard let tools = value as? [[String: Any]] else { throw Error.invalidInput("tools must be an array of objects") }
        return try tools.enumerated().map { index, tool in
            try validateKeys(tool, allowed: ["type", "function"], path: "tools[\(index)]")
            guard (tool["type"] as? String) == "function", let function = tool["function"] as? [String: Any] else {
                throw Error.unsupportedInput("tools[\(index)] must be a function tool")
            }
            try validateKeys(function, allowed: ["name", "description", "parameters", "strict"], path: "tools[\(index)].function")
            guard let name = nonEmptyString(function["name"]) else { throw Error.invalidInput("tools[\(index)].function.name must be a non-empty string") }
            var converted: [String: Any] = ["type": "function", "name": name]
            for key in ["description", "parameters", "strict"] where function[key] != nil { converted[key] = function[key] }
            return converted
        }
    }

    private static func convertToolChoice(_ value: Any) throws -> Any {
        if let string = value as? String, ["auto", "none", "required"].contains(string) { return string }
        guard let object = value as? [String: Any] else { throw Error.invalidInput("tool_choice must be auto, none, required, or a function object") }
        try validateKeys(object, allowed: ["type", "function"], path: "tool_choice")
        guard (object["type"] as? String) == "function", let function = object["function"] as? [String: Any] else {
            throw Error.unsupportedInput("tool_choice object")
        }
        try validateKeys(function, allowed: ["name"], path: "tool_choice.function")
        guard let name = nonEmptyString(function["name"]) else { throw Error.invalidInput("tool_choice.function.name must be a non-empty string") }
        return ["type": "function", "name": name]
    }

    private static func copyInteger(_ source: [String: Any], from: String, into: String, payload: inout [String: Any]) throws {
        guard let value = source[from] else { return }
        guard let integer = value as? Int, integer > 0 else { throw Error.invalidInput("\(from) must be a positive integer") }
        payload[into] = integer
    }

    fileprivate static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    fileprivate static func validateKeys(_ value: [String: Any], allowed: Set<String>, path: String) throws {
        for key in value.keys where !allowed.contains(key) { throw Error.unsupportedInput("\(path).\(key)") }
    }

    private static func stringContent(_ value: Any?, path: String) throws -> String? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        guard let text = value as? String else { throw Error.unsupportedInput("\(path) must be string; multipart content is not implemented") }
        return text
    }
}

/// A completed call is deliberately separate from marker emissions. The main
/// layer should use this after `response.completed` validation, then apply its
/// own permission policy before executing a tool.
struct IntelCodexResponsesToolCall: Equatable {
    let callID: String
    let name: String
    let arguments: String
}

struct IntelCodexResponsesToolResult: Equatable {
    let callID: String
    let output: String
}

struct IntelCodexResponsesCompletion {
    let outputItems: [[String: Any]]
    let toolCalls: [IntelCodexResponsesToolCall]

    /// Returns the exact completed output items (including encrypted reasoning)
    /// followed by results for every completed function call. This is the input
    /// to append to the next Responses round; callers retain prior input items.
    func replayInputItems(toolResults: [IntelCodexResponsesToolResult]) throws -> [[String: Any]] {
        let expected = Set(toolCalls.map(\.callID))
        let supplied = Set(toolResults.map(\.callID))
        guard expected == supplied, toolResults.count == supplied.count else {
            throw IntelCodexResponsesAdapter.Error.invalidInput("tool results must contain exactly one result for every completed function call")
        }
        return outputItems + toolResults.map { ["type": "function_call_output", "call_id": $0.callID, "output": $0.output] }
    }
}

struct IntelCodexResponsesFinalization {
    let emissions: [String]
    let completion: IntelCodexResponsesCompletion
}

/// Incremental SSE decoder for Codex Responses. It validates all output item
/// kinds and terminal states before exposing a completion to tool execution.
struct IntelCodexResponsesSSEDecoder {
    private struct PendingTool {
        var callID: String
        var name: String
        var arguments: String
        var announced = false
        var emittedArguments = false
    }

    private let allowedToolNames: Set<String>
    private var line = Data()
    private var eventDataLines: [Data] = []
    private var waitingForLF = false
    private var pendingTools: [Int: PendingTool] = [:]
    private var emittedText: [String: String] = [:]
    private var emittedReasoning: [String: String] = [:]
    private var completed: IntelCodexResponsesCompletion?

    init(allowedToolNames: Set<String>) {
        self.allowedToolNames = allowedToolNames
    }

    /// Feed arbitrary network byte chunks. Returned strings are directly
    /// compatible with CloudChatEngine's text/reasoning/tool marker contract.
    mutating func append(_ bytes: Data) throws -> [String] {
        var emissions: [String] = []
        for byte in bytes {
            if waitingForLF {
                waitingForLF = false
                if byte == 10 { continue }
            }
            if byte == 10 {
                try consumeLine(&emissions)
            } else if byte == 13 {
                try consumeLine(&emissions)
                waitingForLF = true
            } else {
                line.append(byte)
            }
        }
        return emissions
    }

    /// Flushes a final unterminated event and requires a valid completed state.
    mutating func finish() throws -> IntelCodexResponsesFinalization {
        var emissions: [String] = []
        if !line.isEmpty {
            try consumeLine(&emissions)
        }
        if !eventDataLines.isEmpty {
            try dispatchEvent(&emissions)
        }
        guard let completed else { throw IntelCodexResponsesAdapter.Error.incompleteStream }
        return IntelCodexResponsesFinalization(emissions: emissions, completion: completed)
    }

    private mutating func consumeLine(_ emissions: inout [String]) throws {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            try dispatchEvent(&emissions)
            return
        }
        if line.first == 58 { return } // SSE comment
        guard line.starts(with: Data("data:".utf8)) else { return }
        var data = line.dropFirst(5)
        if data.first == 32 { data = data.dropFirst() }
        eventDataLines.append(Data(data))
    }

    private mutating func dispatchEvent(_ emissions: inout [String]) throws {
        defer { eventDataLines.removeAll(keepingCapacity: true) }
        guard !eventDataLines.isEmpty else { return }
        let joined = eventDataLines.enumerated().reduce(into: Data()) { result, pair in
            if pair.offset > 0 { result.append(10) }
            result.append(pair.element)
        }
        if String(data: joined, encoding: .utf8) == "[DONE]" { return }
        guard let event = try JSONSerialization.jsonObject(with: joined) as? [String: Any],
              let type = event["type"] as? String else {
            throw IntelCodexResponsesAdapter.Error.malformedEvent("event needs JSON object type")
        }
        try handle(event, type: type, emissions: &emissions)
    }

    private mutating func handle(_ event: [String: Any], type: String, emissions: inout [String]) throws {
        switch type {
        case "response.output_text.delta":
            let delta = try requiredString(event, key: "delta", context: type)
            let key = "\(try requiredIndex(event, context: type)):\(try requiredInteger(event, key: "content_index", context: type))"
            emittedText[key, default: ""] += delta
            if !delta.isEmpty { emissions.append(delta) }

        case "response.reasoning_summary_text.delta":
            let delta = try requiredString(event, key: "delta", context: type)
            let key = "\(try requiredIndex(event, context: type)):\(try requiredInteger(event, key: "summary_index", context: type))"
            emittedReasoning[key, default: ""] += delta
            if !delta.isEmpty { emissions.append(StreamingReasoningHint.encode(delta)) }

        case "response.output_item.added":
            let index = try requiredIndex(event, context: type)
            let item = try requiredObject(event, key: "item", context: type)
            try validateOutputItem(item, outputIndex: index, emissions: &emissions, capture: false)

        case "response.function_call_arguments.delta":
            let index = try requiredIndex(event, context: type)
            guard var tool = pendingTools[index] else {
                throw IntelCodexResponsesAdapter.Error.malformedEvent("function argument delta arrived before its function_call item")
            }
            let delta = try requiredString(event, key: "delta", context: type)
            tool.arguments += delta
            tool.emittedArguments = tool.emittedArguments || !delta.isEmpty
            pendingTools[index] = tool
            if !delta.isEmpty { emissions.append(StreamingToolHint.encodeArgs(delta)) }

        case "response.function_call_arguments.done":
            let index = try requiredIndex(event, context: type)
            guard var tool = pendingTools[index] else {
                throw IntelCodexResponsesAdapter.Error.malformedEvent("function argument completion arrived before its function_call item")
            }
            tool.arguments = try requiredString(event, key: "arguments", context: type)
            pendingTools[index] = tool

        case "response.output_item.done":
            let index = try requiredIndex(event, context: type)
            let item = try requiredObject(event, key: "item", context: type)
            try validateOutputItem(item, outputIndex: index, emissions: &emissions, capture: true)

        case "response.completed":
            try complete(event, emissions: &emissions)

        case "response.failed", "response.incomplete", "error":
            throw IntelCodexResponsesAdapter.Error.terminalFailure(terminalMessage(event, type: type))

        case "response.output_text.done":
            let text = try requiredString(event, key: "text", context: type)
            let key = "\(try requiredIndex(event, context: type)):\(try requiredInteger(event, key: "content_index", context: type))"
            try emitAuthoritative(text, prior: &emittedText[key, default: ""], asReasoning: false, context: type, emissions: &emissions)

        case "response.reasoning_summary_text.done":
            let text = try requiredString(event, key: "text", context: type)
            let key = "\(try requiredIndex(event, context: type)):\(try requiredInteger(event, key: "summary_index", context: type))"
            try emitAuthoritative(text, prior: &emittedReasoning[key, default: ""], asReasoning: true, context: type, emissions: &emissions)

        case "response.created", "response.in_progress", "response.queued",
            "response.content_part.added", "response.content_part.done",
            "response.reasoning_summary_part.added", "response.reasoning_summary_part.done":
            // Structural lifecycle markers. Their text is already handled by
            // the corresponding *.delta/*.done events and validated again in
            // output_item.done / response.completed. They carry no executable
            // tool payload of their own.
            break

        default:
            // Unknown protocol events can carry undisclosed tool-capable output;
            // rejecting them is safer than allowing a later function call through.
            throw IntelCodexResponsesAdapter.Error.unsupportedOutput("event type \"\(type)\"")
        }
    }

    private mutating func complete(_ event: [String: Any], emissions: inout [String]) throws {
        guard completed == nil else { throw IntelCodexResponsesAdapter.Error.malformedEvent("duplicate response.completed") }
        let response = try requiredObject(event, key: "response", context: "response.completed")
        guard response["status"] as? String == "completed" else {
            throw IntelCodexResponsesAdapter.Error.terminalFailure("response.completed carried status \"\(response["status"] as? String ?? "missing")\"")
        }
        guard let output = response["output"] as? [[String: Any]] else {
            throw IntelCodexResponsesAdapter.Error.malformedEvent("response.completed.response.output must be an array")
        }
        var calls: [IntelCodexResponsesToolCall] = []
        for (index, item) in output.enumerated() {
            try validateOutputItem(item, outputIndex: index, emissions: &emissions, capture: true)
            if item["type"] as? String == "function_call" {
                calls.append(try toolCall(from: item, context: "response.output[\(index)]"))
            }
        }
        completed = IntelCodexResponsesCompletion(outputItems: output, toolCalls: calls)
    }

    private mutating func validateOutputItem(_ item: [String: Any], outputIndex: Int, emissions: inout [String], capture: Bool) throws {
        guard let kind = item["type"] as? String else { throw IntelCodexResponsesAdapter.Error.malformedEvent("output item has no type") }
        switch kind {
        case "message":
            try validateMessage(item, outputIndex: outputIndex, capture: capture, emissions: &emissions)
            return
        case "reasoning":
            // Keep raw output on response.completed. In particular, `reasoning`
            // retains Codex encrypted_content for the next round's replay.
            try validateReasoning(item, outputIndex: outputIndex, capture: capture, emissions: &emissions)
            return
        case "function_call":
            let call = try toolCall(from: item, context: "output item")
            guard allowedToolNames.contains(call.name) else { throw IntelCodexResponsesAdapter.Error.unknownTool(call.name) }
            var pending = pendingTools[outputIndex] ?? PendingTool(callID: call.callID, name: call.name, arguments: "")
            guard pending.callID == call.callID, pending.name == call.name else {
                throw IntelCodexResponsesAdapter.Error.malformedEvent("function call changed identity at output index \(outputIndex)")
            }
            if !pending.announced {
                emissions.append(StreamingToolHint.encode(call.name))
                pending.announced = true
            }
            if capture || !call.arguments.isEmpty { pending.arguments = call.arguments }
            if capture, !call.arguments.isEmpty, !pending.emittedArguments {
                emissions.append(StreamingToolHint.encodeArgs(call.arguments))
                pending.emittedArguments = true
            }
            pendingTools[outputIndex] = pending
        default:
            throw IntelCodexResponsesAdapter.Error.unsupportedOutput("output item type \"\(kind)\"")
        }
    }

    private func toolCall(from item: [String: Any], context: String) throws -> IntelCodexResponsesToolCall {
        guard let callID = IntelCodexResponsesAdapter.nonEmptyString(item["call_id"]),
              let name = IntelCodexResponsesAdapter.nonEmptyString(item["name"]),
              let arguments = item["arguments"] as? String else {
            throw IntelCodexResponsesAdapter.Error.malformedEvent("\(context) function_call needs call_id, name, and string arguments")
        }
        return IntelCodexResponsesToolCall(callID: callID, name: name, arguments: arguments)
    }

    private mutating func validateMessage(_ item: [String: Any], outputIndex: Int, capture: Bool, emissions: inout [String]) throws {
        guard let content = item["content"] as? [[String: Any]] else {
            throw IntelCodexResponsesAdapter.Error.malformedEvent("message output item needs content array")
        }
        for (contentIndex, part) in content.enumerated() {
            guard part["type"] as? String == "output_text" else {
                let type = part["type"] as? String ?? "missing"
                throw IntelCodexResponsesAdapter.Error.unsupportedOutput("message content type \"\(type)\"")
            }
            guard capture, let text = part["text"] as? String else {
                if capture { throw IntelCodexResponsesAdapter.Error.malformedEvent("completed output_text needs text") }
                continue
            }
            let key = "\(outputIndex):\(contentIndex)"
            try emitAuthoritative(text, prior: &emittedText[key, default: ""], asReasoning: false, context: "completed output_text", emissions: &emissions)
        }
    }

    private mutating func validateReasoning(_ item: [String: Any], outputIndex: Int, capture: Bool, emissions: inout [String]) throws {
        guard let summary = item["summary"] as? [[String: Any]] else {
            // Empty/missing summaries are valid when the provider only returns
            // encrypted reasoning; preserve the raw item for replay either way.
            return
        }
        for (summaryIndex, part) in summary.enumerated() {
            guard part["type"] as? String == "summary_text" else {
                let type = part["type"] as? String ?? "missing"
                throw IntelCodexResponsesAdapter.Error.unsupportedOutput("reasoning summary type \"\(type)\"")
            }
            guard capture, let text = part["text"] as? String else {
                if capture { throw IntelCodexResponsesAdapter.Error.malformedEvent("completed summary_text needs text") }
                continue
            }
            let key = "\(outputIndex):\(summaryIndex)"
            try emitAuthoritative(text, prior: &emittedReasoning[key, default: ""], asReasoning: true, context: "completed reasoning summary", emissions: &emissions)
        }
    }

    private func emitAuthoritative(_ text: String, prior: inout String, asReasoning: Bool, context: String, emissions: inout [String]) throws {
        guard text.hasPrefix(prior) else {
            throw IntelCodexResponsesAdapter.Error.malformedEvent("\(context) disagrees with streamed delta")
        }
        let remainder = String(text.dropFirst(prior.count))
        prior = text
        guard !remainder.isEmpty else { return }
        emissions.append(asReasoning ? StreamingReasoningHint.encode(remainder) : remainder)
    }

    private func requiredObject(_ object: [String: Any], key: String, context: String) throws -> [String: Any] {
        guard let value = object[key] as? [String: Any] else { throw IntelCodexResponsesAdapter.Error.malformedEvent("\(context).\(key) must be an object") }
        return value
    }

    private func requiredString(_ object: [String: Any], key: String, context: String) throws -> String {
        guard let value = object[key] as? String else { throw IntelCodexResponsesAdapter.Error.malformedEvent("\(context).\(key) must be a string") }
        return value
    }

    private func requiredIndex(_ object: [String: Any], context: String) throws -> Int {
        let value = try requiredInteger(object, key: "output_index", context: context)
        guard value >= 0 else { throw IntelCodexResponsesAdapter.Error.malformedEvent("\(context).output_index must be a non-negative integer") }
        return value
    }

    private func requiredInteger(_ object: [String: Any], key: String, context: String) throws -> Int {
        guard let value = object[key] as? Int else { throw IntelCodexResponsesAdapter.Error.malformedEvent("\(context).\(key) must be an integer") }
        return value
    }

    private func terminalMessage(_ event: [String: Any], type: String) -> String {
        if let error = event["error"] as? [String: Any], let message = error["message"] as? String, !message.isEmpty { return message }
        if let message = event["message"] as? String, !message.isEmpty { return message }
        if let response = event["response"] as? [String: Any], let status = response["status"] as? String { return "\(type) (status \(status))" }
        return type
    }
}

#endif
