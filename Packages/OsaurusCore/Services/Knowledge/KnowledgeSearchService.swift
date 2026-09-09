import Foundation

/// Local hybrid search. Text search is always available. When the already-
/// cached potion model is present, vectors are stored in the encrypted derived
/// index and searched by bounded CPU cosine similarity—no MLX or VecturaKit.
public actor KnowledgeSearchService {
    public static let shared = KnowledgeSearchService()
    private var embedder: StaticEmbedder?
    private init() {}

    public func indexChunks(_ hits: [KnowledgeChunkHit]) async {
        guard !hits.isEmpty, let embedder = loadEmbedderIfAvailable() else { return }
        do {
            let text = hits.map { $0.headingPath.isEmpty ? $0.content : "\($0.headingPath)\n\($0.content)" }
            let vectors = try await embedder.embed(text)
            guard vectors.count == hits.count else { throw KnowledgeSearchError.embeddingCountMismatch }
            for (hit, vector) in zip(hits, vectors) { try KnowledgeDatabase.shared.storeEmbedding(collectionId: hit.collectionId, relPath: hit.relPath, chunkIndex: hit.chunkIndex, embedding: vector, model: embedder.identifier) }
        } catch { KnowledgeLogger.search.error("Knowledge semantic indexing failed; text index remains available: \(error)") }
    }

    /// Backfills vectors after the user downloads/changes the local potion
    /// model. Unchanged source files are otherwise correctly skipped by the
    /// content-hash indexer, so vector-model changes need their own check.
    public func ensureEmbeddings(collectionId: String) async {
        guard let embedder = loadEmbedderIfAvailable() else { return }
        do {
            let missing = try KnowledgeDatabase.shared.chunksNeedingEmbedding(collectionId: collectionId, model: embedder.identifier)
            await indexChunks(missing)
        } catch { KnowledgeLogger.search.error("Knowledge embedding backfill failed: \(error)") }
    }

    public func search(query: String, collectionIds: [String], topK: Int = 8) async -> [KnowledgeChunkHit] {
        guard topK > 0, !collectionIds.isEmpty else { return [] }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let lexical: [KnowledgeChunkHit]
        do { lexical = try KnowledgeDatabase.shared.searchChunksText(query: query, collectionIds: collectionIds, limit: topK * 2) }
        catch { KnowledgeLogger.search.error("Knowledge text search failed: \(error)"); lexical = [] }
        if let embedder = loadEmbedderIfAvailable() {
            do {
                let queryVector = try await embedder.embed([query]).first ?? []
                var candidates = try KnowledgeDatabase.shared.vectorChunks(collectionIds: collectionIds, model: embedder.identifier)
                if candidates.isEmpty {
                    for collectionId in collectionIds { await ensureEmbeddings(collectionId: collectionId) }
                    candidates = try KnowledgeDatabase.shared.vectorChunks(collectionIds: collectionIds, model: embedder.identifier)
                }
                let ranked = candidates.map { ($0.hit, cosine(queryVector, $0.embedding)) }.filter { $0.1 > 0.10 }.sorted { $0.1 > $1.1 }
                if !ranked.isEmpty {
                    // Semantic ranking supplies conceptual matches; FTS fills
                    // exact-name/detail matches the static model misses.
                    var seen: Set<String> = []
                    var merged: [KnowledgeChunkHit] = []
                    for hit in ranked.map(\.0) + lexical where seen.insert(hit.compositeKey).inserted {
                        merged.append(hit)
                        if merged.count == topK { return merged }
                    }
                    return merged
                }
            } catch { KnowledgeLogger.search.error("Knowledge semantic search failed; falling back to text: \(error)") }
        }
        return Array(lexical.prefix(topK))
    }

    /// Forces vectors to regenerate from the source-controlled SQLite chunks.
    /// Existing FTS rows remain queryable while the model is unavailable.
    public func rebuildCollection(collectionId: String) async {
        guard let embedder = loadEmbedderIfAvailable() else { KnowledgeLogger.search.info("Knowledge vectors await the cached potion model; text search is ready"); return }
        do {
            let chunks = try KnowledgeDatabase.shared.allChunks(collectionId: collectionId)
            await indexChunks(chunks)
            KnowledgeLogger.search.info("Rebuilt \(chunks.count) local Knowledge vectors with \(embedder.identifier, privacy: .public)")
        } catch { KnowledgeLogger.search.error("Knowledge vector rebuild failed: \(error)") }
    }

    private func loadEmbedderIfAvailable() -> StaticEmbedder? {
        if let embedder { return embedder }
        guard StaticEmbeddingModel.isAvailable else { return nil }
        do { let loaded = try StaticEmbedder(modelDirectory: StaticEmbeddingModel.cacheDirectory); embedder = loaded; return loaded }
        catch { KnowledgeLogger.search.error("Cached potion model could not load: \(error)"); return nil }
    }
    private func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        return zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }
}

public enum KnowledgeSearchError: LocalizedError { case embeddingCountMismatch
    public var errorDescription: String? { "The local embedder returned an unexpected vector count." }
}
