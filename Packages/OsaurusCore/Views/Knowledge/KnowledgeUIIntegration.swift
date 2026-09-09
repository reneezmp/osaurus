//
//  KnowledgeUIIntegration.swift
//  osaurus
//
//  Presentation adapter for the Intel Knowledge manager.
//

import Combine
import Foundation

/// The small, presentation-shaped snapshot the Knowledge management surface
/// needs. The worker can map its native collection model to this value without
/// making SwiftUI depend on the storage schema.
public struct KnowledgeUICollection: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var summary: String
    public var folderPath: String
    public var isEnabled: Bool
    public var documentCount: Int?
    public var chunkCount: Int?
    public var isAvailable: Bool
    public var statusMessage: String?
    public var isIndexing: Bool
    public var gitRemoteURL: String?

    public init(
        id: UUID,
        name: String,
        summary: String = "",
        folderPath: String,
        isEnabled: Bool = true,
        documentCount: Int? = nil,
        chunkCount: Int? = nil,
        isAvailable: Bool = true,
        statusMessage: String? = nil,
        isIndexing: Bool = false,
        gitRemoteURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.folderPath = folderPath
        self.isEnabled = isEnabled
        self.documentCount = documentCount
        self.chunkCount = chunkCount
        self.isAvailable = isAvailable
        self.statusMessage = statusMessage
        self.isIndexing = isIndexing
        self.gitRemoteURL = gitRemoteURL
    }
}

/// Presentation-sized operations exposed to the management surface.
@MainActor
public protocol KnowledgeUIProviding: AnyObject {
    var knowledgeUISnapshot: [KnowledgeUICollection] { get }

    func refresh() async throws
    func createCollection(name: String, summary: String, folderPath: String) async throws -> UUID
    func setCollection(_ id: UUID, enabled: Bool)
    func reindexCollection(_ id: UUID)
    func deleteCollection(_ id: UUID)
}

public enum KnowledgeUIIntegrationError: LocalizedError, Sendable {
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Knowledge services are not connected in this build yet."
        }
    }
}

/// Main-actor bridge between SwiftUI and the local Knowledge manager.
@MainActor
public final class KnowledgeUIIntegration: ObservableObject {
    public static let shared = KnowledgeUIIntegration()

    @Published public private(set) var collections: [KnowledgeUICollection] = []
    @Published public private(set) var isConnected = false
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastError: String?

    // Retain the installed adapter for the lifetime of the management shell.
    // The worker may install a lightweight value-owning facade rather than
    // keeping a second global reference to it.
    private var provider: (any KnowledgeUIProviding)?
    private var managerObservation: AnyCancellable?

    private init() {
        let manager = KnowledgeManager.shared
        provider = manager
        isConnected = true
        adopt(manager.knowledgeUISnapshot)
        managerObservation = manager.objectWillChange.sink { [weak self, weak manager] _ in
            Task { @MainActor in
                await Task.yield()
                guard let self, let manager else { return }
                self.adopt(manager.knowledgeUISnapshot)
            }
        }
    }

    /// Called by the worker's adapter once its KnowledgeManager is ready.
    public func install(_ provider: any KnowledgeUIProviding) {
        self.provider = provider
        isConnected = true
        adopt(provider.knowledgeUISnapshot)
    }

    public func reload() {
        guard provider != nil else { return }
        isRefreshing = true
        lastError = nil
        Task { @MainActor [weak self] in
            guard let self, let provider = self.provider else { return }
            do {
                try await provider.refresh()
                adopt(provider.knowledgeUISnapshot)
            } catch {
                lastError = error.localizedDescription
            }
            isRefreshing = false
        }
    }

    public func createCollection(
        name: String,
        summary: String,
        folderPath: String
    ) async throws -> UUID {
        guard let provider else { throw KnowledgeUIIntegrationError.unavailable }
        let id = try await provider.createCollection(
            name: name, summary: summary, folderPath: folderPath)
        adopt(provider.knowledgeUISnapshot)
        return id
    }

    public func setCollection(_ id: UUID, enabled: Bool) {
        guard let provider else { return }
        provider.setCollection(id, enabled: enabled)
        adopt(provider.knowledgeUISnapshot)
    }

    public func reindexCollection(_ id: UUID) {
        provider?.reindexCollection(id)
        if let provider { adopt(provider.knowledgeUISnapshot) }
    }

    public func deleteCollection(_ id: UUID) {
        provider?.deleteCollection(id)
        if let provider { adopt(provider.knowledgeUISnapshot) }
    }

    public func collection(for id: UUID) -> KnowledgeUICollection? {
        collections.first { $0.id == id }
    }

    private func adopt(_ snapshot: [KnowledgeUICollection]) {
        collections = snapshot.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

// The Intel Knowledge core is now compiled in-tree. Keep the presentation
// adapter small, but connect it eagerly so the UI never exposes a dead shell.
extension KnowledgeManager: KnowledgeUIProviding {
    public var knowledgeUISnapshot: [KnowledgeUICollection] {
        collections.map { collection in
            KnowledgeUICollection(
                id: collection.id,
                name: collection.name,
                summary: collection.summary,
                folderPath: collection.folderPath,
                isEnabled: collection.isEnabled,
                documentCount: indexStatuses[collection.id]?.counts?.documentCount,
                chunkCount: indexStatuses[collection.id]?.counts?.chunkCount,
                isAvailable: indexStatuses[collection.id]?.isAvailable ?? true,
                statusMessage: indexStatuses[collection.id]?.message,
                isIndexing: indexingCollectionIds.contains(collection.id),
                gitRemoteURL: nil
            )
        }
    }

    public func refresh() async throws {
        await reload()
    }

    public func createCollection(name: String, summary: String, folderPath: String) async throws -> UUID {
        let collection = try await create(
            name: name, summary: summary, folderPath: folderPath)
        return collection.id
    }

    public func setCollection(_ id: UUID, enabled: Bool) {
        guard var collection = collection(for: id) else { return }
        collection.isEnabled = enabled
        do {
            try update(collection)
        } catch {
            KnowledgeLogger.index.error(
                "Could not update Knowledge collection \(collection.name, privacy: .public): \(error)"
            )
        }
    }

    public func reindexCollection(_ id: UUID) {
        guard let collection = collection(for: id) else { return }
        scheduleIndex(of: collection, force: true)
    }

    public func deleteCollection(_ id: UUID) {
        delete(id: id)
    }
}
