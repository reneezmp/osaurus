import Foundation
import Testing

@testable import OsaurusCore

@Suite("Identity override deduplication")
struct IdentityOverrideTests {
    private func makeTempDB() throws -> MemoryDatabase {
        let db = MemoryDatabase()
        try db.openInMemory()
        return db
    }

    @Test func keyNormalizesArticlesWhitespaceCaseAndTypography() {
        #expect(TextSimilarity.identityOverrideKey("  The User’s   Name is Alex. ") == "user's name is alex.")
        #expect(TextSimilarity.identityOverrideKey("User's name is Alex.") == "user's name is alex.")
        #expect(TextSimilarity.identityOverrideKey("The Who") != TextSimilarity.identityOverrideKey("Who"))
    }

    @Test func dedupKeepsFirstOriginalOrderAndDistinctFacts() {
        let values = TextSimilarity.deduplicatedIdentityOverrides([
            "The User’s name is Alex.", "User's name is Alex.", "User likes tea",
            "User dislikes tea", "User does not like tea", "User likes coffee", "User likes tea"
        ])
        #expect(values == ["The User’s name is Alex.", "User likes tea", "User dislikes tea", "User does not like tea", "User likes coffee"])
    }

    @Test func appendBatchDeduplicatesAndPreservesMetadata() throws {
        let db = try makeTempDB()
        try db.saveIdentity(Identity(
            content: "Profile", overrides: ["The user’s name is Alex."], tokenCount: 7,
            version: 3, model: "manual", generatedAt: "yesterday"
        ))
        let added = try db.appendIdentityOverrides([
            "User's name is Alex.", "User likes tea", "user likes tea", "User dislikes tea"
        ], model: "distiller")
        let loaded = try db.loadIdentity()
        #expect(added == 2)
        #expect(loaded?.overrides == ["The user’s name is Alex.", "User likes tea", "User dislikes tea"])
        #expect(loaded?.content == "Profile")
        #expect(loaded?.tokenCount == 7)
        #expect(loaded?.version == 3)
        #expect(loaded?.model == "distiller")
        #expect(loaded?.generatedAt != "yesterday")
    }

    @Test func cleanupPreservesMetadataAndFirstText() throws {
        let db = try makeTempDB()
        try db.saveIdentity(Identity(
            content: "Profile", overrides: ["The user’s name is Alex.", "User's name is Alex."],
            tokenCount: 7, version: 3, model: "manual", generatedAt: "yesterday"
        ))
        #expect(try db.deduplicateIdentityOverrides() == 1)
        let loaded = try db.loadIdentity()
        #expect(loaded?.overrides == ["The user’s name is Alex."])
        #expect(loaded?.content == "Profile")
        #expect(loaded?.tokenCount == 7)
        #expect(loaded?.version == 3)
        #expect(loaded?.model == "manual")
        #expect(loaded?.generatedAt == "yesterday")
    }

    @Test func removeUsesDisplayedTextAfterDeduplicationShiftsItsIndex() throws {
        let db = try makeTempDB()
        try db.saveIdentity(Identity(overrides: ["duplicate", "duplicate", "intended", "other"]))

        // The UI rendered "intended" at index 2, then a consolidation pass
        // removed the duplicate before the user clicked its delete button.
        #expect(try db.deduplicateIdentityOverrides() == 1)
        try db.removeIdentityOverride(at: 2, expectedText: "intended")
        #expect(try db.loadIdentity()?.overrides == ["duplicate", "other"])

        // A row that vanished before the click must not delete whichever row
        // has moved into the stale index.
        try db.removeIdentityOverride(at: 0, expectedText: "already removed")
        #expect(try db.loadIdentity()?.overrides == ["duplicate", "other"])
    }
}
