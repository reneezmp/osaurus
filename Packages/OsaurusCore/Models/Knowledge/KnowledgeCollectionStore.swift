import Foundation

/// JSON registry for collections. It intentionally stores only metadata;
/// neither importing nor indexing ever copies or edits the user's folder.
public enum KnowledgeCollectionStore {
    private static var directory: URL {
        OsaurusPaths.root().appendingPathComponent("knowledge/collections", isDirectory: true)
    }

    public static func loadAllAsync() async -> [KnowledgeCollection] {
        await Task.detached(priority: .utility) { loadAll() }.value
    }

    public static func loadAll() -> [KnowledgeCollection] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "json", let data = try? Data(contentsOf: url) else { return nil }
            do { return try decoder.decode(KnowledgeCollection.self, from: data) }
            catch { KnowledgeLogger.index.error("Ignoring unreadable collection registry entry \(url.lastPathComponent, privacy: .public): \(error)"); return nil }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func save(_ collection: KnowledgeCollection) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(collection).write(to: url(for: collection.id), options: .atomic)
    }

    @discardableResult public static func delete(id: UUID) -> Bool {
        do { try FileManager.default.removeItem(at: url(for: id)); return true }
        catch CocoaError.fileNoSuchFile { return true }
        catch { KnowledgeLogger.index.error("Could not remove collection registry \(id.uuidString, privacy: .public): \(error)"); return false }
    }

    private static func url(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
}
