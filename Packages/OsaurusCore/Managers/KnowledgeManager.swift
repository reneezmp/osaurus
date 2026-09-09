import Combine
import Foundation

public extension Notification.Name {
    static let knowledgeCollectionsChanged = Notification.Name("knowledgeCollectionsChanged")
}

public struct KnowledgeIndexStatus: Sendable, Equatable {
    public var counts: KnowledgeDatabaseCounts?
    public var isAvailable: Bool
    public var message: String?

    public init(counts: KnowledgeDatabaseCounts? = nil, isAvailable: Bool = true, message: String? = nil) {
        self.counts = counts
        self.isAvailable = isAvailable
        self.message = message
    }
}

/// Main-actor collection registry. Indexing is deliberately delegated to the
/// actor so UI calls never enumerate or hash a source folder on the main thread.
@MainActor
public final class KnowledgeManager: ObservableObject {
    public static let shared = KnowledgeManager()
    @Published public private(set) var collections: [KnowledgeCollection] = []
    @Published public private(set) var indexingCollectionIds: Set<UUID> = []
    @Published public private(set) var indexStatuses: [UUID: KnowledgeIndexStatus] = [:]
    private var initialLoad: Task<Void, Never>?
    private var loaded = false

    private init() {
        initialLoad = Task.detached(priority: .utility) { [weak self] in
            let collections = KnowledgeCollectionStore.loadAll()
            let statuses = await KnowledgeManager.loadStatuses(for: collections)
            await MainActor.run {
                self?.adopt(collections)
                self?.indexStatuses = statuses
            }
        }
    }

    public func ensureLoaded() async { await initialLoad?.value }
    public func collection(for id: UUID) -> KnowledgeCollection? { collections.first { $0.id == id } }
    public func collection(named name: String) -> KnowledgeCollection? { collections.first { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame } }
    public func enabledCollections(withIds ids: [UUID]) -> [KnowledgeCollection] { ids.compactMap { collection(for: $0) }.filter(\.isEnabled) }

    public func reload() async {
        let values = await KnowledgeCollectionStore.loadAllAsync()
        adopt(values)
        indexStatuses = await Self.loadStatuses(for: values)
    }

    @discardableResult public func create(name: String, summary: String = "", folderPath: String, includeGlobs: [String] = [], excludeGlobs: [String] = []) async throws -> KnowledgeCollection {
        await ensureLoaded()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw KnowledgeManagerError.emptyName }
        guard !collections.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw KnowledgeManagerError.duplicateName }
        let collection = KnowledgeCollection(name: name, summary: summary, folderPath: folderPath, includeGlobs: includeGlobs, excludeGlobs: excludeGlobs)
        try KnowledgeCollectionStore.save(collection)
        upsert(collection)
        scheduleIndex(of: collection)
        return collection
    }

    public func update(_ collection: KnowledgeCollection) throws {
        var collection = collection; collection.updatedAt = Date()
        try KnowledgeCollectionStore.save(collection)
        upsert(collection)
        scheduleIndex(of: collection)
    }

    public func delete(id: UUID) {
        guard KnowledgeCollectionStore.delete(id: id) else { return }
        collections.removeAll { $0.id == id }
        NotificationCenter.default.post(name: .knowledgeCollectionsChanged, object: id)
        Task.detached(priority: .utility) { await KnowledgeIndexService.shared.removeCollectionArtifacts(collectionId: id) }
    }

    public func scheduleIndex(of collection: KnowledgeCollection, force: Bool = false) {
        guard collection.isEnabled else { return }
        indexingCollectionIds.insert(collection.id)
        Task.detached(priority: .utility) { [weak self] in
            let summary = await KnowledgeIndexService.shared.indexCollection(collection, force: force)
            let status = await Self.status(for: collection, summary: summary)
            await MainActor.run {
                self?.indexStatuses[collection.id] = status
                self?.indexingCollectionIds.remove(collection.id)
            }
        }
    }

    public func scheduleIndexAll() {
        let enabled = collections.filter(\.isEnabled)
        for collection in enabled { scheduleIndex(of: collection) }
    }

    private func adopt(_ values: [KnowledgeCollection]) { guard !loaded || !values.isEmpty else { return }; loaded = true; collections = values }
    private func upsert(_ collection: KnowledgeCollection) { loaded = true; collections.removeAll { $0.id == collection.id }; collections.append(collection); collections.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }; NotificationCenter.default.post(name: .knowledgeCollectionsChanged, object: collection.id) }

    private static func loadStatuses(for collections: [KnowledgeCollection]) async -> [UUID: KnowledgeIndexStatus] {
        await withTaskGroup(of: (UUID, KnowledgeIndexStatus).self, returning: [UUID: KnowledgeIndexStatus].self) { group in
            for collection in collections {
                group.addTask { (collection.id, await status(for: collection, summary: nil)) }
            }
            var result: [UUID: KnowledgeIndexStatus] = [:]
            for await (id, status) in group { result[id] = status }
            return result
        }
    }

    private static func status(for collection: KnowledgeCollection, summary: KnowledgeIndexSummary?) async -> KnowledgeIndexStatus {
        guard collection.folderExists else {
            return KnowledgeIndexStatus(isAvailable: false, message: "Source folder is unavailable")
        }
        let counts: KnowledgeDatabaseCounts?
        do {
            try KnowledgeDatabase.shared.openOrRecoverDerivedIndex()
            counts = try KnowledgeDatabase.shared.counts(collectionId: collection.id.uuidString)
        } catch {
            counts = nil
        }
        let message: String?
        if let summary, summary.failed > 0 {
            message = "Indexed with \(summary.failed) error\(summary.failed == 1 ? "" : "s")"
        } else {
            message = nil
        }
        return KnowledgeIndexStatus(counts: counts, isAvailable: true, message: message)
    }
}

public enum KnowledgeManagerError: LocalizedError { case emptyName, duplicateName
    public var errorDescription: String? { self == .emptyName ? "A knowledge collection needs a name." : "A knowledge collection already uses that name." }
}
