//
//  IntelClaudeCodeTests.swift
//  OsaurusCoreTests
//

#if OSAURUS_INTEL

import Foundation
import Testing
@testable import OsaurusCore

@Suite("Intel Claude Code integration")
struct IntelClaudeCodeTests {
    @Test func pickerIdsRouteOnlyClaudeAliases() {
        for model in ClaudeCodeModel.allCases {
            #expect(ClaudeCodeModel.fromPickerId(model.pickerId) == model)
            #expect(IntelClaudeCodeService.handles(model.pickerId))
        }
        #expect(!IntelClaudeCodeService.handles(nil))
        #expect(!IntelClaudeCodeService.handles("default"))
        #expect(!IntelClaudeCodeService.handles("claude-code/unknown"))
    }

    @Test func textOnlyArgumentsDisableToolsAndPreserveStreaming() throws {
        let args = ClaudeCodeConfiguration.arguments(
            model: .sonnet,
            mode: .textOnly,
            allowedTools: ["Read", "Bash"],
            systemPrompt: "Be concise."
        )
        let toolsIndex = try #require(args.firstIndex(of: "--tools"))
        #expect(args[toolsIndex + 1].isEmpty)
        #expect(!args.contains("--allowedTools"))
        #expect(!args.contains("--permission-mode"))
        #expect(args.contains("--include-partial-messages"))
        #expect(args.contains("--no-session-persistence"))
        #expect(args.contains("--strict-mcp-config"))
        #expect(args.contains("--append-system-prompt"))
    }

    @Test func promptRenderingHoistsSystemAndLabelsHistory() {
        let rendered = IntelClaudeCodeService.renderPrompt(messages: [
            ChatMessage(role: "system", content: "Be brief."),
            ChatMessage(role: "user", content: "one"),
            ChatMessage(role: "assistant", content: "two"),
            ChatMessage(role: "user", content: "three"),
        ])
        #expect(rendered.systemPrompt == "Be brief.")
        #expect(rendered.prompt == "User: one\n\nAssistant: two\n\nUser: three")
    }

    @Test func singleUserPromptIsBare() {
        let rendered = IntelClaudeCodeService.renderPrompt(messages: [
            ChatMessage(role: "user", content: "hello")
        ])
        #expect(rendered.prompt == "hello")
        #expect(rendered.systemPrompt == nil)
    }

    @Test func authStatusShapesDecodeWithoutCredentialAccess() throws {
        let signedIn = try #require(ClaudeCodeConfiguration.decodeAuthStatus(Data(
            #"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max","newField":1}"#.utf8
        )))
        #expect(signedIn.loggedIn)
        #expect(signedIn.displayPlan == "Max")
        #expect(signedIn.usesSubscription)

        let signedOut = try #require(ClaudeCodeConfiguration.decodeAuthStatus(Data(
            #"{"loggedIn":false}"#.utf8
        )))
        #expect(!signedOut.loggedIn)
    }

    @Test func executableSearchIncludesOfficialInstallerLocation() {
        let entries = ExecutableLocator.searchPath(env: ["PATH": "/usr/bin"])
            .split(separator: ":").map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(entries.contains("\\(home)/.local/bin"))
        #expect(entries.contains("/usr/local/bin"))
    }
}

#endif
