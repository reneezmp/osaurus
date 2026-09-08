//
//  CodexOAuthHeadersTests.swift
//  OsaurusCoreTests
//
//  `resolvedHeaders()` grew a Bearer branch for xAI OAuth but never one for
//  ChatGPT/Codex, so every generic caller built a credential-free request. And
//  a Bearer alone is not enough for `chatgpt.com/backend-api`: without
//  `chatgpt-account-id` the backend answers `401 {"detail":"Unauthorized"}`
//  even for a live subscription with usage remaining.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct CodexOAuthHeadersTests {

    private func makeProvider(authType: RemoteProviderAuthType, id: UUID) -> RemoteProvider {
        RemoteProvider(
            id: id,
            name: "Codex",
            host: "chatgpt.com",
            providerProtocol: .https,
            port: nil,
            basePath: "/backend-api",
            customHeaders: [:],
            authType: authType,
            providerType: .openAICodex,
            enabled: true,
            autoConnect: false,
            timeout: 30
        )
    }

    private func withTokens(
        accountId: String = "acct_test_123",
        expiresAt: Date = Date().addingTimeInterval(3600),
        _ body: (RemoteProvider) -> Void
    ) async {
        let id = UUID()
        let tokens = RemoteProviderOAuthTokens(
            accessToken: "access-token-value",
            refreshToken: "refresh-token-value",
            expiresAt: expiresAt,
            accountId: accountId
        )
        await RemoteProviderKeychain.saveOAuthTokensOffMainActor(tokens, for: id)
        defer { RemoteProviderKeychain.deleteOAuthTokens(for: id) }
        body(makeProvider(authType: .openAICodexOAuth, id: id))
    }

    @Test
    func codexSendsBearerAccountIdBetaAndOriginator() async {
        await withTokens { provider in
            let headers = provider.resolvedHeaders()
            #expect(headers["Authorization"] == "Bearer access-token-value")
            #expect(headers["chatgpt-account-id"] == "acct_test_123")
            #expect(headers["OpenAI-Beta"] == "responses=experimental")
            #expect(headers["originator"] == "codex_cli_rs")
        }
    }

    @Test
    func anEmptyAccountIdIsOmittedRatherThanSentBlank() async {
        await withTokens(accountId: "") { provider in
            let headers = provider.resolvedHeaders()
            #expect(headers["Authorization"] == "Bearer access-token-value")
            #expect(headers["chatgpt-account-id"] == nil)
        }
    }

    @Test
    func userSuppliedHeadersAreNotOverwritten() async {
        let id = UUID()
        let tokens = RemoteProviderOAuthTokens(
            accessToken: "access-token-value",
            refreshToken: "r",
            expiresAt: Date().addingTimeInterval(3600),
            accountId: "acct_test_123"
        )
        await RemoteProviderKeychain.saveOAuthTokensOffMainActor(tokens, for: id)
        defer { RemoteProviderKeychain.deleteOAuthTokens(for: id) }

        var provider = makeProvider(authType: .openAICodexOAuth, id: id)
        provider.customHeaders = ["originator": "mine", "Authorization": "Bearer manual"]
        let headers = provider.resolvedHeaders()
        #expect(headers["originator"] == "mine")
        #expect(headers["Authorization"] == "Bearer manual")
        // The ones the user did not set are still filled in.
        #expect(headers["chatgpt-account-id"] == "acct_test_123")
    }

    @Test
    func nonCodexProvidersGainNoCodexHeaders() {
        let provider = RemoteProvider(
            id: UUID(),
            name: "Generic",
            host: "example.com",
            providerProtocol: .https,
            port: nil,
            basePath: "/v1",
            customHeaders: [:],
            authType: .none,
            providerType: .openaiLegacy,
            enabled: true,
            autoConnect: false,
            timeout: 30
        )
        let headers = provider.resolvedHeaders()
        #expect(headers["chatgpt-account-id"] == nil)
        #expect(headers["OpenAI-Beta"] == nil)
        #expect(headers["originator"] == nil)
    }
}
