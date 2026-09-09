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

    @Test func responsesLiteMovesToolsAndInstructionsIntoInputItems() throws {
        let payload = try IntelCodexResponsesAdapter.makeRequest(
            chatCompletions: [
                "model": "gpt-5.6-luna",
                "stream": true,
                "messages": [
                    ["role": "system", "content": "Be exact."],
                    ["role": "user", "content": "Hello"],
                ],
                "tools": [[
                    "type": "function",
                    "function": ["name": "list_knowledge", "parameters": ["type": "object"]],
                ]],
            ],
            responsesLiteSessionId: "0198f2ab-7b38-7a11-88ba-123456789abc"
        )

        #expect(payload["tools"] == nil)
        #expect(payload["instructions"] == nil)
        #expect(payload["tool_choice"] as? String == "auto")
        #expect(payload["parallel_tool_calls"] as? Bool == false)
        #expect(payload["prompt_cache_key"] as? String == "0198f2ab-7b38-7a11-88ba-123456789abc")
        #expect((payload["reasoning"] as? [String: Any])?["context"] as? String == "all_turns")
        let input = try #require(payload["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String } == ["additional_tools", "message", "message"])
        #expect(input[0]["role"] as? String == "developer")
        #expect(input[1]["role"] as? String == "developer")
        #expect(input[2]["role"] as? String == "user")
    }

    @Test func replaysAssistantTextAsOutputAndNewUserTextAsInput() throws {
        let payload = try IntelCodexResponsesAdapter.makeRequest(
            chatCompletions: [
                "model": "gpt-5.6-luna",
                "messages": [
                    ["role": "user", "content": "First turn"],
                    ["role": "assistant", "content": "First answer"],
                    ["role": "user", "content": "Follow-up"],
                ],
            ]
        )
        let input = try #require(payload["input"] as? [[String: Any]])
        let types = input.map { item -> String? in
            (item["content"] as? [[String: Any]])?.first?["type"] as? String
        }
        #expect(input.map { $0["role"] as? String } == ["user", "assistant", "user"])
        #expect(types == ["input_text", "output_text", "input_text"])
    }

    @Test func uuidV7HasExpectedVersionAndVariant() {
        let value = ChatEngine.makeUUIDv7(
            now: Date(timeIntervalSince1970: 1_750_000_000),
            randomUUID: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        )
        let uuid = UUID(uuidString: value)
        #expect(uuid != nil)
        #expect(value.split(separator: "-")[2].first == "7")
        #expect(["8", "9", "a", "b"].contains(String(value.split(separator: "-")[3].first!)))
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

    @Test func acceptsNormalContentAndReasoningLifecycleEvents() throws {
        var decoder = IntelCodexResponsesSSEDecoder(allowedToolNames: [])
        let frames = [
            "data: {\"type\":\"response.reasoning_summary_part.added\",\"output_index\":0,\"summary_index\":0,\"part\":{\"type\":\"summary_text\",\"text\":\"\"}}\n\n",
            "data: {\"type\":\"response.reasoning_summary_part.done\",\"output_index\":0,\"summary_index\":0,\"part\":{\"type\":\"summary_text\",\"text\":\"brief\"}}\n\n",
            "data: {\"type\":\"response.content_part.added\",\"output_index\":1,\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n\n",
            "data: {\"type\":\"response.output_text.delta\",\"output_index\":1,\"content_index\":0,\"delta\":\"Hello\"}\n\n",
            "data: {\"type\":\"response.output_text.done\",\"output_index\":1,\"content_index\":0,\"text\":\"Hello\"}\n\n",
            "data: {\"type\":\"response.content_part.done\",\"output_index\":1,\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"Hello\"}}\n\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"summary\":[]},{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"}]}]}}\n\n",
        ]
        var emissions: [String] = []
        for frame in frames { emissions += try decoder.append(Data(frame.utf8)) }
        emissions += try decoder.finish().emissions
        #expect(emissions == ["Hello"])
    }
}
