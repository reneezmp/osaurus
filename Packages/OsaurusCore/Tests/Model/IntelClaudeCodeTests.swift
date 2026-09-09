//
//  IntelClaudeCodeTests.swift
//  OsaurusCoreTests
//

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

    @Test func folderAgentArgumentsAllowAuthorizedWorkspaceToolsWithoutBypass() throws {
        let tools = ClaudeCodeConfiguration.allowedTools(allowWrites: true, allowShell: true)
        let args = ClaudeCodeConfiguration.arguments(
            model: .haiku,
            mode: .agent,
            allowedTools: tools,
            systemPrompt: "Stay in the selected folder."
        )
        let permissionIndex = try #require(args.firstIndex(of: "--permission-mode"))
        let toolsIndex = try #require(args.firstIndex(of: "--allowedTools"))
        #expect(args[permissionIndex + 1] == "dontAsk")
        #expect(Set(args[toolsIndex + 1].split(separator: ",").map(String.init)) == Set([
            "Read", "Grep", "Glob", "Edit", "Write", "NotebookEdit", "Bash",
        ]))
        #expect(!args.contains("--dangerously-skip-permissions"))
        #expect(!args.contains("--allow-dangerously-skip-permissions"))
    }

    @Test func nonStreamingCompatibilityKeepsOnlyVisibleText() {
        #expect(IntelClaudeCodeService.visibleTextDelta("answer") == "answer")
        #expect(IntelClaudeCodeService.visibleTextDelta(StreamingToolHint.encode("Read")) == nil)
        #expect(IntelClaudeCodeService.visibleTextDelta(StreamingReasoningHint.encode("thinking")) == nil)
        #expect(IntelClaudeCodeService.visibleTextDelta(
            StreamingStatsHint.encode(tokenCount: 4, tokensPerSecond: 2)
        ) == nil)
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
        #expect(entries.contains("\(home)/.local/bin"))
        #expect(entries.contains("/usr/local/bin"))
    }

    @Test func warningRateStatusDoesNotAbortTurn() {
        #expect(IntelClaudeCodeService.rateLimitError(status: "allowed", utilization: 0.1) == nil)
        #expect(IntelClaudeCodeService.rateLimitError(status: "allowed_warning", utilization: 0.82) == nil)
        #expect(
            IntelClaudeCodeService.rateLimitError(status: "rejected", utilization: 0.82)
                == .rateLimited(detail: "Claude Code reported rejected at 82% utilization.")
        )
    }

    @Test func subprocessEnvironmentExcludesCredentialAndRoutingOverrides() {
        let environment = ClaudeCodeConfiguration.subprocessEnvironment(source: [
            "PATH": "/fixture/bin",
            "HOME": "/fixture/home",
            "USER": "fixture-user",
            "LANG": "en_US.UTF-8",
            "ANTHROPIC_API_KEY": "secret",
            "ANTHROPIC_AUTH_TOKEN": "secret",
            "ANTHROPIC_BASE_URL": "https://redirect.invalid",
            "CLAUDE_CODE_USE_BEDROCK": "1",
            "AWS_SECRET_ACCESS_KEY": "secret",
            "HTTPS_PROXY": "https://proxy.invalid",
        ])
        #expect(environment["HOME"] == "/fixture/home")
        #expect(environment["USER"] == "fixture-user")
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["PATH"]?.contains("/fixture/bin") == true)
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(environment["ANTHROPIC_BASE_URL"] == nil)
        #expect(environment["CLAUDE_CODE_USE_BEDROCK"] == nil)
        #expect(environment["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(environment["HTTPS_PROXY"] == nil)
    }
}
