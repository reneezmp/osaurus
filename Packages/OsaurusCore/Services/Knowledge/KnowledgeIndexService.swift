import CryptoKit
import Foundation

public struct KnowledgeIndexSummary: Sendable, Equatable {
    public var indexed = 0
    public var skipped = 0
    public var pruned = 0
    public var failed = 0
    public init() {}
}

/// Incremental importer for user-owned source folders. It never writes to the
/// collection folder: hashes decide what to reparse and deleted source files
/// merely prune their derived rows.
public actor KnowledgeIndexService {
    public static let shared = KnowledgeIndexService()
    private static let extensions: Set<String> = ["md", "markdown", "mdx", "txt"]
    private static let excludedDirectories: Set<String> = [".git", "node_modules", "build", "dist", ".build", "DerivedData", "Pods", "vendor", "__pycache__"]
    private static let maxMarkdownBytes = 2 * 1024 * 1024
    private static let maxAdapterBytes = 10 * 1024 * 1024
    private static let maxFiles = 5_000
    private var opened = false
    private init() {}

    public func indexAll(_ collections: [KnowledgeCollection]) async {
        for collection in collections where collection.isEnabled { _ = await indexCollection(collection) }
    }

    @discardableResult public func indexCollection(_ collection: KnowledgeCollection, force: Bool = false) async -> KnowledgeIndexSummary {
        var summary = KnowledgeIndexSummary()
        guard collection.isEnabled else { return summary }
        guard collection.folderExists else { KnowledgeLogger.index.error("Knowledge folder is unavailable: \(collection.folderPath, privacy: .public)"); return summary }
        guard openDatabaseIfNeeded() else { summary.failed += 1; return summary }
        DocumentAdaptersBootstrap.registerBuiltIns()
        let collectionId = collection.id.uuidString
        let files = scan(folder: collection.folderURL, collection: collection)
        let hashes = (try? KnowledgeDatabase.shared.documentHashes(collectionId: collectionId)) ?? [:]
        var present: Set<String> = []
        for file in files {
            let relative = relativePath(file, root: collection.folderURL)
            guard !relative.isEmpty else { continue }
            present.insert(relative)
            guard let data = try? Data(contentsOf: file) else { summary.failed += 1; KnowledgeLogger.index.error("Could not read knowledge document \(relative, privacy: .public)"); continue }
            let hash = digest(data)
            if !force, hashes[relative] == hash { summary.skipped += 1; continue }
            do {
                let text = try await extractedText(file: file, data: data)
                let parsed = KnowledgeDocumentParser.parse(markdown: text)
                let chunks = KnowledgeDocumentParser.chunk(body: parsed.body)
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let id = try KnowledgeDatabase.shared.upsertDocument(
                    collectionId: collectionId, relPath: relative,
                    title: KnowledgeDocumentParser.resolveTitle(frontmatter: parsed.frontmatter, body: parsed.body, relPath: relative),
                    docType: parsed.frontmatter.docType, summary: parsed.frontmatter.summary,
                    tagsCSV: parsed.frontmatter.tagsCSV, contentHash: hash,
                    sizeBytes: values?.fileSize ?? data.count,
                    modifiedAt: values?.contentModificationDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
                )
                _ = try KnowledgeDatabase.shared.replaceChunks(documentId: id, chunks: chunks)
                let hits = chunks.enumerated().map { index, chunk in
                    KnowledgeChunkHit(documentId: id, chunkIndex: index, headingPath: chunk.headingPath, content: chunk.content,
                                      collectionId: collectionId, relPath: relative,
                                      title: KnowledgeDocumentParser.resolveTitle(frontmatter: parsed.frontmatter, body: parsed.body, relPath: relative),
                                      docType: parsed.frontmatter.docType, tagsCSV: parsed.frontmatter.tagsCSV)
                }
                await KnowledgeSearchService.shared.indexChunks(hits)
                summary.indexed += 1
            } catch { summary.failed += 1; KnowledgeLogger.index.error("Knowledge indexing failed for \(relative, privacy: .public): \(error)") }
        }
        for path in hashes.keys where !present.contains(path) { do { try KnowledgeDatabase.shared.deleteDocument(collectionId: collectionId, relPath: path); summary.pruned += 1 } catch { summary.failed += 1 } }
        await KnowledgeSearchService.shared.ensureEmbeddings(collectionId: collectionId)
        KnowledgeLogger.index.info("Knowledge index \(collection.name, privacy: .public): \(summary.indexed) indexed, \(summary.skipped) unchanged, \(summary.pruned) pruned, \(summary.failed) failed")
        return summary
    }

    public func removeCollectionArtifacts(collectionId: UUID) async {
        guard openDatabaseIfNeeded() else { return }
        do { try KnowledgeDatabase.shared.deleteCollection(collectionId: collectionId.uuidString) }
        catch { KnowledgeLogger.index.error("Could not remove derived Knowledge rows: \(error)") }
    }

    /// Settings-facing recovery operation for a copied or damaged derived
    /// index. Only `knowledge.sqlite` and its WAL/SHM sidecars move into the
    /// quarantine; collection JSON and every source folder stay in place.
    public func resetDerivedIndexAndRebuild(_ collections: [KnowledgeCollection], reason: String = "user requested rebuild") async {
        do {
            try KnowledgeDatabase.shared.resetDerivedIndex(quarantineReason: reason)
            opened = false
            await indexAll(collections)
        } catch {
            KnowledgeLogger.index.error("Knowledge derived-index reset failed: \(error)")
        }
    }

    private func openDatabaseIfNeeded() -> Bool {
        guard !opened else { return true }
        do { try KnowledgeDatabase.shared.openOrRecoverDerivedIndex(); opened = true; return true }
        catch { KnowledgeLogger.index.error("Knowledge derived-index recovery failed: \(error)"); return false }
    }

    private func scan(folder: URL, collection: KnowledgeCollection) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let ignores = KnowledgeIgnoreRules.forFolder(folder)
        var files: [URL] = []
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: keys)
            if values?.isDirectory == true { if Self.excludedDirectories.contains(file.lastPathComponent) { enumerator.skipDescendants() }; continue }
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let isPlainText = Self.extensions.contains(file.pathExtension.lowercased())
            let isAdapted = DocumentFormatRegistry.shared.adapter(for: file) != nil
            guard isPlainText || isAdapted else { continue }
            let limit = isPlainText ? Self.maxMarkdownBytes : Self.maxAdapterBytes
            guard (values?.fileSize ?? 0) <= limit else { continue }
            let relative = relativePath(file, root: folder)
            guard collection.indexPathAllowed(relative), !ignores.isIgnored(relative) else { continue }
            files.append(file)
            if files.count >= Self.maxFiles { KnowledgeLogger.index.warning("Knowledge collection reached the \(Self.maxFiles) document cap"); break }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func relativePath(_ file: URL, root: URL) -> String {
        let prefix = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let path = file.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : ""
    }
    private func extractedText(file: URL, data: Data) async throws -> String {
        if Self.extensions.contains(file.pathExtension.lowercased()) {
            guard let text = String(data: data, encoding: .utf8) else { throw KnowledgeIndexError.notUTF8(file.lastPathComponent) }
            return text
        }
        guard let adapter = DocumentFormatRegistry.shared.adapter(for: file) else { throw KnowledgeIndexError.noAdapter(file.lastPathComponent) }
        return try await adapter.parse(url: file, sizeLimit: Int64(Self.maxAdapterBytes)).textFallback
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public enum KnowledgeIndexError: LocalizedError { case notUTF8(String), noAdapter(String)
    public var errorDescription: String? { switch self { case .notUTF8(let name): return "\(name) is not valid UTF-8."; case .noAdapter(let name): return "No document adapter can read \(name)." } }
}
