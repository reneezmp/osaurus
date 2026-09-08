//
//  IntelCodexCredentials.swift
//  OsaurusCore
//
//  Credential resolution for the Intel Codex provider.
//

import Foundation

public enum IntelCodexCredentialsError: LocalizedError, Sendable, Equatable {
    case missing(providerId: UUID)
    case invalid(providerId: UUID)
    case refreshFailed(String)
    case persistenceFailed(providerId: UUID)

    public var errorDescription: String? {
        switch self {
        case .missing:
            return "ChatGPT/Codex sign-in is missing. Sign in again, then retry."
        case .invalid:
            return "Saved ChatGPT/Codex sign-in is incomplete. Sign in again, then retry."
        case .refreshFailed(let message):
            return "ChatGPT/Codex token refresh failed: \(OpenAICodexOAuthService.safeDiagnosticFragment(message))"
        case .persistenceFailed:
            return "ChatGPT/Codex tokens could not be saved securely. Sign in again, then retry."
        }
    }
}

/// Resolves saved Codex credentials once per provider and shares an in-flight refresh.
public actor IntelCodexCredentials {
    public static let shared = IntelCodexCredentials()

    private let load: @Sendable (UUID) async -> RemoteProviderOAuthTokens?
    private let refresh: @Sendable (RemoteProviderOAuthTokens) async throws -> RemoteProviderOAuthTokens
    private let save: @Sendable (RemoteProviderOAuthTokens, UUID) async -> Bool
    private var inFlight: [UUID: Task<RemoteProviderOAuthTokens, Error>] = [:]

    public init(
        load: @escaping @Sendable (UUID) async -> RemoteProviderOAuthTokens? = { providerId in
            await RemoteProviderKeychain.runOffCooperativeExecutor {
                RemoteProviderKeychain.getOAuthTokens(for: providerId)
            }
        },
        refresh: @escaping @Sendable (RemoteProviderOAuthTokens) async throws -> RemoteProviderOAuthTokens = { tokens in
            try await OpenAICodexOAuthService.refresh(tokens)
        },
        save: @escaping @Sendable (RemoteProviderOAuthTokens, UUID) async -> Bool = { tokens, providerId in
            await RemoteProviderKeychain.saveOAuthTokensOffMainActor(tokens, for: providerId)
        }
    ) {
        self.load = load
        self.refresh = refresh
        self.save = save
    }

    public func tokens(
        for providerId: UUID,
        forceRefresh: Bool = false
    ) async throws -> RemoteProviderOAuthTokens {
        if let task = inFlight[providerId] {
            return try await task.value
        }

        let task = Task { [load, refresh, save] in
            guard let current = await load(providerId) else {
                throw IntelCodexCredentialsError.missing(providerId: providerId)
            }
            guard !current.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !current.accountId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw IntelCodexCredentialsError.invalid(providerId: providerId)
            }
            guard forceRefresh || current.isExpired else { return current }

            let refreshed: RemoteProviderOAuthTokens
            do {
                refreshed = try await refresh(current)
            } catch {
                throw IntelCodexCredentialsError.refreshFailed(error.localizedDescription)
            }
            guard !refreshed.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !refreshed.accountId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !refreshed.isExpired
            else {
                throw IntelCodexCredentialsError.refreshFailed("The provider returned incomplete or expired credentials")
            }
            guard await save(refreshed, providerId) else {
                throw IntelCodexCredentialsError.persistenceFailed(providerId: providerId)
            }
            return refreshed
        }
        inFlight[providerId] = task

        do {
            let result = try await task.value
            inFlight.removeValue(forKey: providerId)
            return result
        } catch {
            inFlight.removeValue(forKey: providerId)
            throw error
        }
    }
}
