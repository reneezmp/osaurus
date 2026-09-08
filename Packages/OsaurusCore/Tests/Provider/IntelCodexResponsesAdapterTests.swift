import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct IntelCodexResponsesAdapterTests {
    @Test func convertsConversationToolsAndToolResultsWithoutDroppingContext() throws {
        let request: [String: Any] = [
            "model": "gpt-5.6-codex",
            "stream": true,
            "max_tokens": 1200,
            "reasoning_effort": "medium",
            "messages": [
                ["role": "system", "content": "Be concise."],
                ["role": "user", "content": "Find the file."],
                ["role": "assistant", "tool_calls": [[
                    "id": "call_1", "type": "function",
                    "function": ["name": "files.find", "arguments": "{\"name\":\"x\"}"],
                ]]],
                ["role": "tool", "tool_call_id": "call_1", "content": "x.swift"],
            ],
            "tools": [[
                "type": "function",
                "function": ["name": "files.find", "description": "Find a file", "parameters": ["type": "object"]],
            ]],
            "tool_choice": ["type": "function", "function": ["name": "files.find"]],
        ]

        let payload = try IntelCodexResponsesAdapter.makeRequest(chatCompletions: request)
        #expect(payload["model"] as? String == "gpt-5.6-codex")
        #expect(payload["instructions"] as? String == "Be concise.")
        #expect(payload["max_output_tokens"] == nil)
        #expect(payload["store"] as? Bool == false)
        #expect(payload["include"] as? [String] == ["reasoning.encrypted_content"])
        #expect((payload["reasoning"] as? [String: Any])?["summary"] as? String == "auto")
        #expect((payload["reasoning"] as? [String: Any])?["context"] as? String == "all_turns")
        let input = try #require(payload["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String } == ["message", "function_call", "function_call_output"])
        #expect((input[1]["call_id"] as? String) == "call_1")
        #expect((payload["tools"] as? [[String: Any]])?.first?["name"] as? String == "files.find")
        #expect((payload["tool_choice"] as? [String: Any])?["name"] as? String == "files.find")
    }

    @Test func rejectsInputsThatWouldOtherwiseBeSilentlyChanged() {
        let unsupported: [String: Any] = ["model": "gpt", "messages": [], "temperature": 0.2]
        #expect(throws: IntelCodexResponsesAdapter.Error.unsupportedInput("field \"temperature\"") ) {
            try IntelCodexResponsesAdapter.makeRequest(chatCompletions: unsupported)
        }
        let reasoning: [String: Any] = [
            "model": "gpt", "messages": [["role": "assistant", "content": "x", "reasoning_content": "plain chain"]],
        ]
        #expect(throws: IntelCodexResponsesAdapter.Error.unsupportedInput("messages[0].reasoning_content; replay completed Responses output items instead")) {
            try IntelCodexResponsesAdapter.makeRequest(chatCompletions: reasoning)
        }
    }

    @Test func decodesPartialTextReasoningAndToolMarkersThenPreservesReplayItems() throws {
        var decoder = IntelCodexResponsesSSEDecoder(allowedToolNames: ["files.find"])
        let frames = [
            "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"Hello\"}\n\n",
            "data: {\"type\":\"response.reasoning_summary_text.delta\",\"output_index\":0,\"summary_index\":0,\"delta\":\"Inspecting\"}\n\n",
            "data: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_7\",\"name\":\"files.find\",\"arguments\":\"\"}}\n\n",
            "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"{}\"}\n\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"opaque\"},{\"type\":\"function_call\",\"call_id\":\"call_7\",\"name\":\"files.find\",\"arguments\":\"{}\"}]}}\n\n",
        ]
        var emissions: [String] = []
        for frame in frames { emissions += try decoder.append(Data(frame.utf8)) }
        let final = try decoder.finish()
        emissions += final.emissions

        #expect(emissions[0] == "Hello")
        #expect(StreamingReasoningHint.decode(emissions[1]) == "Inspecting")
        #expect(StreamingToolHint.decode(emissions[2]) == "files.find")
        #expect(StreamingToolHint.decodeArgs(emissions[3]) == "{}")
        #expect(final.completion.toolCalls == [IntelCodexResponsesToolCall(callID: "call_7", name: "files.find", arguments: "{}")])
        let replay = try final.completion.replayInputItems(toolResults: [.init(callID: "call_7", output: "found")])
        #expect(replay.count == 3)
        #expect(replay[0]["encrypted_content"] as? String == "opaque")
        #expect(replay[2]["type"] as? String == "function_call_output")
    }

    @Test func rejectsUnknownToolAndNonCompletedTerminalsBeforeCompletionIsAvailable() throws {
        var decoder = IntelCodexResponsesSSEDecoder(allowedToolNames: ["safe.tool"])
        let unknown = "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_x\",\"name\":\"rm.everything\",\"arguments\":\"{}\"}}\n\n"
        #expect(throws: IntelCodexResponsesAdapter.Error.unknownTool("rm.everything")) {
            try decoder.append(Data(unknown.utf8))
        }

        var failed = IntelCodexResponsesSSEDecoder(allowedToolNames: [])
        let failure = "data: {\"type\":\"response.failed\",\"error\":{\"message\":\"quota\"}}\n\n"
        #expect(throws: IntelCodexResponsesAdapter.Error.terminalFailure("quota")) {
            try failed.append(Data(failure.utf8))
        }
    }

    @Test func requiresCompletedTerminalAndRejectsUnknownOutputKinds() throws {
        var noTerminal = IntelCodexResponsesSSEDecoder(allowedToolNames: [])
        _ = try noTerminal.append(Data("data: {\"type\":\"response.created\"}\n\n".utf8))
        #expect(throws: IntelCodexResponsesAdapter.Error.incompleteStream) { try noTerminal.finish() }

        var decoder = IntelCodexResponsesSSEDecoder(allowedToolNames: [])
        let unknown = "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"computer_call\"}}\n\n"
        #expect(throws: IntelCodexResponsesAdapter.Error.unsupportedOutput("output item type \"computer_call\"")) {
            try decoder.append(Data(unknown.utf8))
        }
    }

    @Test func emitsAuthoritativeCompletedTextWhenNoDeltaArrived() throws {
        var decoder = IntelCodexResponsesSSEDecoder(allowedToolNames: [])
        let completed = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"late text\"}]}]}}\n\n"
        let emissions = try decoder.append(Data(completed.utf8))
        let final = try decoder.finish()
        #expect(emissions + final.emissions == ["late text"])
    }
}
