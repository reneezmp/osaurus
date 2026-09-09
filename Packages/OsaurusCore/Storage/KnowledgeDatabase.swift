import CryptoKit
import Foundation
import OsaurusSQLCipher

private let knowledgeSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum KnowledgeDatabaseError: LocalizedError {
    case keyUnavailable(String)
    case failedToOpen(String)
    case sqlite(String)
    case notOpen
    public var errorDescription: String? {
        switch self { case .keyUnavailable(let message): return "Knowledge storage key is unavailable: \(message)"; case .failedToOpen(let message): return "Failed to open the derived Knowledge index: \(message)"; case .sqlite(let message): return "Knowledge index error: \(message)"; case .notOpen: return "Knowledge index is not open." }
    }
}

public struct KnowledgeDatabaseCounts: Sendable, Equatable {
    public let documentCount: Int
    public let chunkCount: Int

    public init(documentCount: Int, chunkCount: Int) {
        self.documentCount = documentCount
        self.chunkCount = chunkCount
    }
}

/// Encrypted, rebuildable index for knowledge source folders. It deliberately
/// holds no corpus or write history: losing it costs an index pass, never user
/// material. That property makes cross-device key changes recoverable.
public final class KnowledgeDatabase: @unchecked Sendable {
    public static let shared = KnowledgeDatabase()
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.knowledge.database")
    private static let schemaVersion = 1
    private init() {}
    deinit { close() }

    public var isOpen: Bool { queue.sync { db != nil } }

    private static var directory: URL { OsaurusPaths.root().appendingPathComponent("knowledge", isDirectory: true) }
    private static var fileURL: URL { directory.appendingPathComponent("knowledge.sqlite") }

    public func open() throws {
        do { try openStrict() }
        catch let error as KnowledgeDatabaseError {
            if case .keyUnavailable = error { throw error }
            try recover(after: error)
        } catch { try recover(after: error) }
    }

    private func openStrict() throws {
        StorageMigrationCoordinator.blockingAwaitReady()
        try queue.sync {
            guard db == nil else { return }
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let key: SymmetricKey
            do { key = try StorageKeyManager.shared.currentKey() }
            catch { throw KnowledgeDatabaseError.keyUnavailable(error.localizedDescription) }
            do { db = try EncryptedSQLiteOpener.open(path: Self.fileURL.path, key: key) }
            catch { throw KnowledgeDatabaseError.failedToOpen(error.localizedDescription) }
            do { try migrate() }
            catch { closeLocked(); throw error }
        }
    }

    /// Opens the derived index, quarantining an Air-keyed/corrupt/schema-
    /// incompatible copy if necessary. Collection JSON and source folders are
    /// never touched. The next normal indexing pass recreates this file under
    /// the current machine's storage key.
    public func openOrRecoverDerivedIndex() throws {
        try open()
    }

    private func recover(after error: Error) throws {
            let reason = error.localizedDescription
            KnowledgeLogger.database.error("Knowledge derived index unavailable; quarantining only database sidecars before rebuild: \(reason, privacy: .public)")
            try resetDerivedIndex(quarantineReason: reason)
            try openStrict()
    }

    /// Explicit safe-reset seam for Settings. It affects only known derived
    /// SQLite files and leaves `knowledge/collections/*.json`, managed corpus
    /// folders, and any future independent write-log database intact.
    public func resetDerivedIndex(quarantineReason: String = "manual reset") throws {
        close()
        let manager = FileManager.default
        try manager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let quarantine = Self.directory.appendingPathComponent("quarantine/\(stamp)", isDirectory: true)
        var moved = 0
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: Self.fileURL.path + suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            try manager.createDirectory(at: quarantine, withIntermediateDirectories: true)
            try manager.moveItem(at: source, to: quarantine.appendingPathComponent(source.lastPathComponent))
            moved += 1
        }
        KnowledgeLogger.database.warning("Quarantined \(moved) derived Knowledge index file(s): \(quarantineReason, privacy: .public)")
    }

    public func close() { queue.sync { closeLocked() } }
    private func closeLocked() { if let db { sqlite3_close(db) }; db = nil }

    private func migrate() throws {
        guard let connection = db else { throw KnowledgeDatabaseError.notOpen }
        try execute(connection, "PRAGMA journal_mode=WAL")
        var version = 0
        try query(connection, "PRAGMA user_version") { statement in if sqlite3_step(statement) == SQLITE_ROW { version = Int(sqlite3_column_int(statement, 0)) } }
        guard version <= Self.schemaVersion else { throw KnowledgeDatabaseError.sqlite("schema v\(version) is newer than this build") }
        guard version == 0 else { return }
        try execute(connection, "BEGIN")
        do {
            try execute(connection, """
                CREATE TABLE documents (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    collection_id TEXT NOT NULL, rel_path TEXT NOT NULL,
                    title TEXT NOT NULL DEFAULT '', doc_type TEXT NOT NULL DEFAULT '',
                    summary TEXT NOT NULL DEFAULT '', tags_csv TEXT NOT NULL DEFAULT '',
                    content_hash TEXT NOT NULL, size_bytes INTEGER NOT NULL DEFAULT 0,
                    modified_at TEXT NOT NULL DEFAULT '', indexed_at TEXT NOT NULL,
                    UNIQUE(collection_id, rel_path)
                )
                """)
            try execute(connection, "CREATE INDEX idx_knowledge_documents_collection ON documents(collection_id)")
            try execute(connection, """
                CREATE TABLE chunks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, document_id INTEGER NOT NULL,
                    chunk_index INTEGER NOT NULL, heading_path TEXT NOT NULL DEFAULT '',
                    content TEXT NOT NULL, embedding BLOB, embedding_model TEXT NOT NULL DEFAULT '',
                    UNIQUE(document_id, chunk_index)
                )
                """)
            try execute(connection, "CREATE INDEX idx_knowledge_chunks_document ON chunks(document_id)")
            try execute(connection, "CREATE VIRTUAL TABLE chunks_fts USING fts5(content, heading_path, content='chunks', content_rowid='id', tokenize='unicode61 remove_diacritics 2')")
            try execute(connection, "CREATE TRIGGER chunks_ai AFTER INSERT ON chunks BEGIN INSERT INTO chunks_fts(rowid, content, heading_path) VALUES(new.id, new.content, new.heading_path); END")
            try execute(connection, "CREATE TRIGGER chunks_ad AFTER DELETE ON chunks BEGIN INSERT INTO chunks_fts(chunks_fts, rowid, content, heading_path) VALUES('delete', old.id, old.content, old.heading_path); END")
            try execute(connection, "PRAGMA user_version = 1")
            try execute(connection, "COMMIT")
        } catch { try? execute(connection, "ROLLBACK"); throw error }
    }

    public func documentHashes(collectionId: String) throws -> [String: String] {
        try sync { connection in
            var result: [String: String] = [:]
            try query(connection, "SELECT rel_path, content_hash FROM documents WHERE collection_id = ?1", bind: { bindText($0, 1, collectionId) }) { statement in
                while sqlite3_step(statement) == SQLITE_ROW { result[columnText(statement, 0)] = columnText(statement, 1) }
            }
            return result
        }
    }

    public func upsertDocument(collectionId: String, relPath: String, title: String, docType: String, summary: String, tagsCSV: String, contentHash: String, sizeBytes: Int, modifiedAt: String) throws -> Int {
        try sync { connection in
            var id = 0
            try query(connection, """
                INSERT INTO documents(collection_id,rel_path,title,doc_type,summary,tags_csv,content_hash,size_bytes,modified_at,indexed_at)
                VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)
                ON CONFLICT(collection_id,rel_path) DO UPDATE SET title=excluded.title,doc_type=excluded.doc_type,summary=excluded.summary,tags_csv=excluded.tags_csv,content_hash=excluded.content_hash,size_bytes=excluded.size_bytes,modified_at=excluded.modified_at,indexed_at=excluded.indexed_at
                RETURNING id
                """, bind: { statement in
                    bindText(statement, 1, collectionId); bindText(statement, 2, relPath); bindText(statement, 3, title); bindText(statement, 4, docType); bindText(statement, 5, summary); bindText(statement, 6, tagsCSV); bindText(statement, 7, contentHash); sqlite3_bind_int(statement, 8, Int32(sizeBytes)); bindText(statement, 9, modifiedAt); bindText(statement, 10, now())
                }) { statement in if sqlite3_step(statement) == SQLITE_ROW { id = Int(sqlite3_column_int64(statement, 0)) } }
            guard id != 0 else { throw KnowledgeDatabaseError.sqlite("document upsert did not return an id") }
            return id
        }
    }

    @discardableResult public func replaceChunks(documentId: Int, chunks: [(headingPath: String, content: String)]) throws -> Int {
        try sync { connection in
            try execute(connection, "BEGIN")
            do {
                var removed = 0
                try query(connection, "DELETE FROM chunks WHERE document_id = ?1", bind: { sqlite3_bind_int64($0, 1, Int64(documentId)) }) { statement in guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError(connection) }; removed = Int(sqlite3_changes(connection)) }
                for (index, chunk) in chunks.enumerated() {
                    try query(connection, "INSERT INTO chunks(document_id,chunk_index,heading_path,content) VALUES(?1,?2,?3,?4)", bind: { statement in sqlite3_bind_int64(statement, 1, Int64(documentId)); sqlite3_bind_int(statement, 2, Int32(index)); bindText(statement, 3, chunk.headingPath); bindText(statement, 4, chunk.content) }) { statement in guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError(connection) } }
                }
                try execute(connection, "COMMIT"); return removed
            } catch { try? execute(connection, "ROLLBACK"); throw error }
        }
    }

    public func storeEmbedding(collectionId: String, relPath: String, chunkIndex: Int, embedding: [Float], model: String) throws {
        guard !embedding.isEmpty else { return }
        try sync { connection in
            let data = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
            try query(connection, """
                UPDATE chunks SET embedding = ?1, embedding_model = ?2
                WHERE chunk_index = ?3 AND document_id = (SELECT id FROM documents WHERE collection_id = ?4 AND rel_path = ?5)
                """, bind: { statement in
                    _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), knowledgeSQLiteTransient) }
                    bindText(statement, 2, model); sqlite3_bind_int(statement, 3, Int32(chunkIndex)); bindText(statement, 4, collectionId); bindText(statement, 5, relPath)
                }) { statement in guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError(connection) } }
        }
    }

    public func deleteDocument(collectionId: String, relPath: String) throws {
        try sync { connection in
            try query(connection, "DELETE FROM chunks WHERE document_id = (SELECT id FROM documents WHERE collection_id=?1 AND rel_path=?2)", bind: { bindText($0, 1, collectionId); bindText($0, 2, relPath) }) { _ = sqlite3_step($0) }
            try query(connection, "DELETE FROM documents WHERE collection_id=?1 AND rel_path=?2", bind: { bindText($0, 1, collectionId); bindText($0, 2, relPath) }) { _ = sqlite3_step($0) }
        }
    }

    public func deleteCollection(collectionId: String) throws {
        try sync { connection in
            try query(connection, "DELETE FROM chunks WHERE document_id IN (SELECT id FROM documents WHERE collection_id=?1)", bind: { bindText($0, 1, collectionId) }) { _ = sqlite3_step($0) }
            try query(connection, "DELETE FROM documents WHERE collection_id=?1", bind: { bindText($0, 1, collectionId) }) { _ = sqlite3_step($0) }
        }
    }

    public func searchChunksText(query text: String, collectionIds: [String], limit: Int) throws -> [KnowledgeChunkHit] {
        guard !collectionIds.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return try sync { connection in
            let placeholders = collectionIds.indices.map { "?\($0 + 2)" }.joined(separator: ",")
            let sql = """
                SELECT d.id,c.chunk_index,c.heading_path,c.content,d.collection_id,d.rel_path,d.title,d.doc_type,d.tags_csv
                FROM chunks c JOIN chunks_fts ON chunks_fts.rowid=c.id JOIN documents d ON d.id=c.document_id
                WHERE chunks_fts MATCH ?1 AND d.collection_id IN (\(placeholders)) ORDER BY bm25(chunks_fts) LIMIT ?\(collectionIds.count + 2)
                """
            var hits: [KnowledgeChunkHit] = []
            do {
                try query(connection, sql, bind: { statement in
                    bindText(statement, 1, ftsQuery(text)); for (index, id) in collectionIds.enumerated() { bindText(statement, Int32(index + 2), id) }; sqlite3_bind_int(statement, Int32(collectionIds.count + 2), Int32(limit))
                }) { statement in while sqlite3_step(statement) == SQLITE_ROW { hits.append(readHit(statement)) } }
            } catch { return try searchChunksLike(connection, text: text, collectionIds: collectionIds, limit: limit) }
            return hits
        }
    }

    public func vectorChunks(collectionIds: [String], model: String) throws -> [KnowledgeVectorChunk] {
        guard !collectionIds.isEmpty else { return [] }
        return try sync { connection in
            let placeholders = collectionIds.indices.map { "?\($0 + 2)" }.joined(separator: ",")
            var result: [KnowledgeVectorChunk] = []
            try query(connection, """
                SELECT d.id,c.chunk_index,c.heading_path,c.content,d.collection_id,d.rel_path,d.title,d.doc_type,d.tags_csv,c.embedding,c.embedding_model
                FROM chunks c JOIN documents d ON d.id=c.document_id
                WHERE c.embedding_model=?1 AND d.collection_id IN (\(placeholders))
                """, bind: { statement in bindText(statement, 1, model); for (index, id) in collectionIds.enumerated() { bindText(statement, Int32(index + 2), id) } }) { statement in
                    while sqlite3_step(statement) == SQLITE_ROW, let vector = readVector(statement, index: 9) { result.append(.init(hit: readHit(statement), embedding: vector, embeddingModel: columnText(statement, 10))) }
                }
            return result
        }
    }

    public func allChunks(collectionId: String) throws -> [KnowledgeChunkHit] {
        try sync { connection in
            var result: [KnowledgeChunkHit] = []
            try query(connection, """
                SELECT d.id,c.chunk_index,c.heading_path,c.content,d.collection_id,d.rel_path,d.title,d.doc_type,d.tags_csv
                FROM chunks c JOIN documents d ON d.id=c.document_id
                WHERE d.collection_id=?1 ORDER BY d.rel_path,c.chunk_index
                """, bind: { bindText($0, 1, collectionId) }) { statement in
                while sqlite3_step(statement) == SQLITE_ROW { result.append(readHit(statement)) }
            }
            return result
        }
    }

    public func counts(collectionId: String) throws -> KnowledgeDatabaseCounts {
        try sync { connection in
            var documents = 0
            var chunks = 0
            try query(connection, "SELECT COUNT(*) FROM documents WHERE collection_id = ?1", bind: { bindText($0, 1, collectionId) }) { statement in
                guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError(connection) }
                documents = Int(sqlite3_column_int64(statement, 0))
            }
            try query(connection, "SELECT COUNT(*) FROM chunks WHERE document_id IN (SELECT id FROM documents WHERE collection_id = ?1)", bind: { bindText($0, 1, collectionId) }) { statement in
                guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError(connection) }
                chunks = Int(sqlite3_column_int64(statement, 0))
            }
            return KnowledgeDatabaseCounts(documentCount: documents, chunkCount: chunks)
        }
    }

    public func chunksNeedingEmbedding(collectionId: String, model: String, limit: Int = 50_000) throws -> [KnowledgeChunkHit] {
        try sync { connection in
            var result: [KnowledgeChunkHit] = []
            try query(connection, """
                SELECT d.id,c.chunk_index,c.heading_path,c.content,d.collection_id,d.rel_path,d.title,d.doc_type,d.tags_csv
                FROM chunks c JOIN documents d ON d.id=c.document_id
                WHERE d.collection_id=?1 AND (c.embedding IS NULL OR c.embedding_model != ?2)
                ORDER BY d.rel_path,c.chunk_index LIMIT ?3
                """, bind: { statement in
                    bindText(statement, 1, collectionId); bindText(statement, 2, model); sqlite3_bind_int(statement, 3, Int32(max(0, limit)))
                }) { statement in
                while sqlite3_step(statement) == SQLITE_ROW { result.append(readHit(statement)) }
            }
            return result
        }
    }

    private func searchChunksLike(_ connection: OpaquePointer, text: String, collectionIds: [String], limit: Int) throws -> [KnowledgeChunkHit] {
        let placeholders = collectionIds.indices.map { "?\($0 + 2)" }.joined(separator: ",")
        var hits: [KnowledgeChunkHit] = []
        try query(connection, """
            SELECT d.id,c.chunk_index,c.heading_path,c.content,d.collection_id,d.rel_path,d.title,d.doc_type,d.tags_csv
            FROM chunks c JOIN documents d ON d.id=c.document_id
            WHERE c.content LIKE '%' || ?1 || '%' AND d.collection_id IN (\(placeholders)) LIMIT ?\(collectionIds.count + 2)
            """, bind: { statement in bindText(statement, 1, text); for (index, id) in collectionIds.enumerated() { bindText(statement, Int32(index + 2), id) }; sqlite3_bind_int(statement, Int32(collectionIds.count + 2), Int32(limit)) }) { statement in while sqlite3_step(statement) == SQLITE_ROW { hits.append(readHit(statement)) } }
        return hits
    }

    private func sync<T>(_ body: (OpaquePointer) throws -> T) throws -> T { try queue.sync { guard let db else { throw KnowledgeDatabaseError.notOpen }; return try body(db) } }
    private func execute(_ connection: OpaquePointer, _ sql: String) throws { guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw lastError(connection) } }
    private func query(_ connection: OpaquePointer, _ sql: String, bind: (OpaquePointer) -> Void = { _ in }, process: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw lastError(connection) }; defer { sqlite3_finalize(statement) }; bind(statement); try process(statement)
    }
    private func lastError(_ connection: OpaquePointer) -> KnowledgeDatabaseError { .sqlite(String(cString: sqlite3_errmsg(connection))) }
    private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) { sqlite3_bind_text(statement, index, value, -1, knowledgeSQLiteTransient) }
    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String { guard let value = sqlite3_column_text(statement, index) else { return "" }; return String(cString: value) }
    private func readHit(_ statement: OpaquePointer) -> KnowledgeChunkHit { .init(documentId: Int(sqlite3_column_int64(statement, 0)), chunkIndex: Int(sqlite3_column_int(statement, 1)), headingPath: columnText(statement, 2), content: columnText(statement, 3), collectionId: columnText(statement, 4), relPath: columnText(statement, 5), title: columnText(statement, 6), docType: columnText(statement, 7), tagsCSV: columnText(statement, 8)) }
    private func readVector(_ statement: OpaquePointer, index: Int32) -> [Float]? { guard let bytes = sqlite3_column_blob(statement, index) else { return nil }; let count = Int(sqlite3_column_bytes(statement, index)); guard count > 0, count % MemoryLayout<Float>.stride == 0 else { return nil }; return Array(UnsafeRawBufferPointer(start: bytes, count: count).bindMemory(to: Float.self)) }
    private func now() -> String { ISO8601DateFormatter().string(from: Date()) }
    private func ftsQuery(_ query: String) -> String { query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { "\($0)*" }.joined(separator: " AND ") }
}
