import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel Knowledge core", .serialized)
struct KnowledgeCoreTests {
    @Test
    func parsesFrontmatterAndHeadingAwareChunks() {
        let document = """
            ---
            type: guide
            title: Recovery Handbook
            description: Steps for moving between devices
            tags: [Storage, Migration]
            owner: Rosy
            ---
            # Restore

            Keep the recovery phrase offline.

            ## Verify

            Confirm the restored address before importing data.
            """

        let parsed = KnowledgeDocumentParser.parse(markdown: document)
        #expect(parsed.frontmatter.docType == "guide")
        #expect(parsed.frontmatter.title == "Recovery Handbook")
        #expect(parsed.frontmatter.summary == "Steps for moving between devices")
        #expect(parsed.frontmatter.tags == ["storage", "migration"])
        #expect(parsed.frontmatter.extras == [.init(key: "owner", value: "Rosy")])

        let chunks = KnowledgeDocumentParser.chunk(body: parsed.body)
        #expect(chunks.map(\.headingPath) == ["Restore", "Restore > Verify"])
        #expect(chunks[0].content.contains("recovery phrase"))
        #expect(chunks[1].content.contains("restored address"))
    }

    @Test
    func includeAndExcludeGlobsRespectDirectoryBoundaries() {
        #expect(KnowledgeGlob.matches("guides/setup.md", include: ["guides/**/*.md"], exclude: []))
        #expect(KnowledgeGlob.matches("guides/setup.md", include: ["**/*.md"], exclude: ["drafts/**"]))
        #expect(!KnowledgeGlob.matches("drafts/setup.md", include: ["**/*.md"], exclude: ["drafts/**"]))
        #expect(!KnowledgeGlob.matches("guides/setup.txt", include: ["**/*.md"], exclude: []))
        #expect(KnowledgeGlob.matchesPattern("notes/a1.md", pattern: "notes/a?.md"))
    }

    @Test
    func olderCollectionMetadataDecodesWithSafeDefaults() throws {
        let id = UUID()
        let data = Data("""
            {
              "id": "\(id.uuidString)",
              "name": "Migrated Notes",
              "folderPath": "~/Documents/Notes"
            }
            """.utf8)

        let collection = try JSONDecoder().decode(KnowledgeCollection.self, from: data)
        #expect(collection.id == id)
        #expect(collection.summary.isEmpty)
        #expect(collection.isEnabled)
        #expect(collection.includeGlobs.isEmpty)
        #expect(collection.excludeGlobs.isEmpty)
    }

    @Test
    func encryptedIndexSearchesAndRecoversFromAnotherDeviceKey() async throws {
        try await StoragePathsTestLock.shared.run {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory.appendingPathComponent(
                "osaurus-knowledge-tests-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

            let previousRoot = OsaurusPaths.overrideRoot
            KnowledgeDatabase.shared.close()
            OsaurusPaths.overrideRoot = root
            StorageKeyManager.shared._setKeyForTesting(
                SymmetricKey(data: Data(repeating: 0x31, count: 32))
            )
            defer {
                KnowledgeDatabase.shared.close()
                StorageKeyManager.shared.wipeCache()
                OsaurusPaths.overrideRoot = previousRoot
                try? fileManager.removeItem(at: root)
            }

            try KnowledgeDatabase.shared.open()
            let documentId = try KnowledgeDatabase.shared.upsertDocument(
                collectionId: "collection-a",
                relPath: "guides/recovery.md",
                title: "Recovery",
                docType: "guide",
                summary: "",
                tagsCSV: "storage,migration",
                contentHash: "hash-a",
                sizeBytes: 42,
                modifiedAt: "2026-09-08T12:00:00Z"
            )
            _ = try KnowledgeDatabase.shared.replaceChunks(
                documentId: documentId,
                chunks: [("Restore", "Keep the recovery phrase offline and verify the address.")]
            )
            #expect(try KnowledgeDatabase.shared.counts(collectionId: "collection-a") == .init(documentCount: 1, chunkCount: 1))
            let firstHits = try KnowledgeDatabase.shared.searchChunksText(
                query: "recovery phrase",
                collectionIds: ["collection-a"],
                limit: 5
            )
            #expect(firstHits.count == 1)
            #expect(firstHits.first?.relPath == "guides/recovery.md")

            let databaseURL = root.appendingPathComponent("knowledge/knowledge.sqlite")
            let header = try Data(contentsOf: databaseURL).prefix(15)
            #expect(header != Data("SQLite format 3".utf8))

            KnowledgeDatabase.shared.close()
            StorageKeyManager.shared._setKeyForTesting(
                SymmetricKey(data: Data(repeating: 0x62, count: 32))
            )
            try KnowledgeDatabase.shared.open()

            let recoveredHits = try KnowledgeDatabase.shared.searchChunksText(
                query: "recovery phrase",
                collectionIds: ["collection-a"],
                limit: 5
            )
            #expect(recoveredHits.isEmpty)

            let quarantine = root.appendingPathComponent("knowledge/quarantine", isDirectory: true)
            let quarantinedFiles = try fileManager.subpathsOfDirectory(atPath: quarantine.path)
            #expect(quarantinedFiles.contains { $0.hasSuffix("knowledge.sqlite") })
        }
    }
}
