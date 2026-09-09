import Foundation

/// Metadata for an indexed source document.
public struct KnowledgeDocument: Sendable, Equatable, Identifiable {
    public var id: Int
    public var collectionId: String
    public var relPath: String
    public var title: String
    public var docType: String
    public var summary: String
    public var tagsCSV: String
    public var contentHash: String
    public var sizeBytes: Int
    public var modifiedAt: String
    public var indexedAt: String

    public init(id: Int, collectionId: String, relPath: String, title: String, docType: String,
                summary: String, tagsCSV: String, contentHash: String, sizeBytes: Int,
                modifiedAt: String, indexedAt: String) {
        self.id = id; self.collectionId = collectionId; self.relPath = relPath; self.title = title
        self.docType = docType; self.summary = summary; self.tagsCSV = tagsCSV
        self.contentHash = contentHash; self.sizeBytes = sizeBytes; self.modifiedAt = modifiedAt; self.indexedAt = indexedAt
    }

    public var tags: [String] { tagsCSV.split(separator: ",").map(String.init).filter { !$0.isEmpty } }
}

/// A heading-aware searchable piece of a document.
public struct KnowledgeChunkHit: Sendable, Equatable {
    public var documentId: Int
    public var chunkIndex: Int
    public var headingPath: String
    public var content: String
    public var collectionId: String
    public var relPath: String
    public var title: String
    public var docType: String
    public var tagsCSV: String

    public init(documentId: Int, chunkIndex: Int, headingPath: String, content: String,
                collectionId: String, relPath: String, title: String, docType: String, tagsCSV: String) {
        self.documentId = documentId; self.chunkIndex = chunkIndex; self.headingPath = headingPath
        self.content = content; self.collectionId = collectionId; self.relPath = relPath
        self.title = title; self.docType = docType; self.tagsCSV = tagsCSV
    }

    public var compositeKey: String { "\(collectionId):\(relPath):\(chunkIndex)" }
}

public struct KnowledgeVectorChunk: Sendable {
    public var hit: KnowledgeChunkHit
    public var embedding: [Float]
    public var embeddingModel: String
    public init(hit: KnowledgeChunkHit, embedding: [Float], embeddingModel: String) {
        self.hit = hit; self.embedding = embedding; self.embeddingModel = embeddingModel
    }
}
