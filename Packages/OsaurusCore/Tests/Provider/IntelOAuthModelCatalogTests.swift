//
//  IntelOAuthModelCatalogTests.swift
//  OsaurusCoreTests
//
//  The Intel `RemoteProviderManager` mirror resolved every provider's models
//  with a plain `/models` GET, attaching credentials only for `.apiKey` auth.
//  A ChatGPT/Codex provider is `.openAICodexOAuth`, so the probe went out with
//  no Authorization header at all, came back non-2xx, and was swallowed into an
//  empty list — models showed during sign-in and never again, and "Test"
//  reported a bare HTTP failure. `oauthModelCatalog` is the branch that was
//  missing.
//
//  Deliberately NOT wrapped in `#if OSAURUS_INTEL`: the test target carries no
//  such define, so a guarded file compiles to nothing and the suite silently
//  never runs. The library target defines it, so these symbols exist here.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel OAuth model catalog")
struct IntelOAuthModelCatalogTests {

    @Test
    func codexWithoutTokensFallsBackToTheBuiltInCatalog() async throws {
        let models = try await RemoteProviderManager.oauthModelCatalog(
            providerType: .openAICodex, authType: .openAICodexOAuth, providerId: nil)
        #expect(models == OpenAICodexOAuthService.supportedModels)
        #expect(!(models ?? []).isEmpty)
    }

    @Test
    func codexIsRecognizedByAuthTypeAloneWhenTheProviderTypeDisagrees() async throws {
        // The edit sheet can hand us a provider whose `providerType` was never
        // migrated to `.openAICodex`; the OAuth auth type is the reliable signal.
        let models = try await RemoteProviderManager.oauthModelCatalog(
            providerType: .openaiLegacy, authType: .openAICodexOAuth, providerId: nil)
        #expect(models == OpenAICodexOAuthService.supportedModels)
    }

    @Test
    func codexIsRecognizedByProviderTypeAloneWhenTheAuthTypeDisagrees() async throws {
        let models = try await RemoteProviderManager.oauthModelCatalog(
            providerType: .openAICodex, authType: .none, providerId: nil)
        #expect(models == OpenAICodexOAuthService.supportedModels)
    }

    @Test
    func xaiOAuthReturnsItsBuiltInCatalog() async throws {
        let models = try await RemoteProviderManager.oauthModelCatalog(
            providerType: .openaiLegacy, authType: .xaiOAuth, providerId: nil)
        #expect(models == XAIOAuthService.supportedModels)
    }

    @Test
    func apiKeyProvidersStillFallThroughToTheGenericProbe() async throws {
        for providerType in [RemoteProviderType.openaiLegacy, .anthropic, .gemini, .osaurus] {
            let models = try await RemoteProviderManager.oauthModelCatalog(
                providerType: providerType, authType: .apiKey, providerId: nil)
            #expect(models == nil, "\(providerType) should use the generic /models probe")
        }
    }

    @Test
    func unauthenticatedProvidersStillFallThroughToTheGenericProbe() async throws {
        let models = try await RemoteProviderManager.oauthModelCatalog(
            providerType: .openaiLegacy, authType: .none, providerId: nil)
        #expect(models == nil)
    }
}
