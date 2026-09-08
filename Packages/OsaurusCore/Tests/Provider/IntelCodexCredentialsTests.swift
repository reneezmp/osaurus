import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct IntelCodexCredentialsTests {
    private actor FakeStore {
        var value: RemoteProviderOAuthTokens?
        var saveCount = 0

        init(_ value: RemoteProviderOAuthTokens? = nil) { self.value = value }

        func load(_ providerId: UUID) async -> RemoteProviderOAuthTokens? { value }

        func save(_ tokens: RemoteProviderOAuthTokens, _ providerId: UUID) async -> Bool {
            saveCount += 1
            value = tokens
            return true
        }

        func saves() -> Int { saveCount }
    }

    private func tokens(expiresAt: Date = Date().addingTimeInterval(3600)) -> RemoteProviderOAuthTokens {
        RemoteProviderOAuthTokens(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: expiresAt,
            accountId: "account"
        )
    }

    @Test
    func missingCredentialsThrow() async {
        let id = UUID()
        let store = FakeStore()
        let credentials = IntelCodexCredentials(load: { await store.load($0) }, refresh: { _ in tokens() }, save: { value, id in await store.save(value, id) })
        await #expect(throws: IntelCodexCredentialsError.missing(providerId: id)) {
            try await credentials.tokens(for: id)
        }
    }

    @Test
    func expiredCredentialsRefreshAndPersist() async throws {
        let store = FakeStore(tokens(expiresAt: Date().addingTimeInterval(-1)))
        let credentials = IntelCodexCredentials(load: { await store.load($0) }, refresh: { current in
            RemoteProviderOAuthTokens(
                accessToken: "new-access",
                refreshToken: current.refreshToken,
                expiresAt: Date().addingTimeInterval(3600),
                accountId: current.accountId
            )
        }, save: { value, id in await store.save(value, id) })
        let result = try await credentials.tokens(for: UUID())
        #expect(result.accessToken == "new-access")
        #expect(await store.saves() == 1)
    }

    @Test
    func refreshFailureIsNotHiddenByFallback() async {
        let id = UUID()
        let store = FakeStore(tokens(expiresAt: Date().addingTimeInterval(-1)))
        let credentials = IntelCodexCredentials(load: { await store.load($0) }, refresh: { _ in
            struct Failure: LocalizedError { var errorDescription: String? { "invalid refresh token" } }
            throw Failure()
        }, save: { value, id in await store.save(value, id) })
        await #expect(throws: IntelCodexCredentialsError.refreshFailed("invalid refresh token")) {
            try await credentials.tokens(for: id)
        }
    }

    @Test
    func concurrentRequestsShareOneRefresh() async throws {
        let store = FakeStore(tokens(expiresAt: Date().addingTimeInterval(-1)))
        let lock = RefreshCounter()
        let credentials = IntelCodexCredentials(load: { await store.load($0) }, refresh: { current in
            await lock.increment()
            try await Task.sleep(for: .milliseconds(20))
            return RemoteProviderOAuthTokens(
                accessToken: "new-access",
                refreshToken: current.refreshToken,
                expiresAt: Date().addingTimeInterval(3600),
                accountId: current.accountId
            )
        }, save: { value, id in await store.save(value, id) })
        let id = UUID()
        async let first = credentials.tokens(for: id)
        async let second = credentials.tokens(for: id)
        _ = try await (first, second)
        #expect(await lock.value() == 1)
    }

    private actor RefreshCounter {
        var count = 0
        func increment() { count += 1 }
        func value() -> Int { count }
    }
}
