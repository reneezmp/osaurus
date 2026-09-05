//
//  IntelMemoryDiagnostics.swift
//  OsaurusCore (Intel fork)
//
//  Phase 1 diagnostics service (see docs/MEMORY_PLAN.md §5 for the contract).
//  Read-only: this file writes nothing to `MemoryDatabase` and calls no
//  write-path method on `MemoryService`. It exists to answer one question
//  the Intel memory pipeline could not otherwise answer for itself: is any
//  of this actually running, and if not, at which stage did it stop?
//
//  Every counter below is sourced from a method that already existed on
//  `MemoryDatabase` before this file, or from `MemoryService.bufferTelemetry()`
//  (already public on the actor). Two data gaps were found and closed with
//  small additive queries on `MemoryDatabase` (see that file's diff):
//    * `PendingSignalsSummary.processedSignals` / `.deadLetteredSignals` were
//      declared but never populated by `pendingSignalsSummary()`.
//    * `ProcessingStats.skippedCount` / `.emptyCount` / `.deadLetterCount`
//      were declared but never populated by `processingStats()`.
//    * Three new group-by-agent count queries
//      (`agentIdsWithEpisodes`, `agentIdsWithPendingSignals`, alongside the
//      pre-existing `agentIdsWithPinnedFacts`) back the per-agent breakdown.
//  No schema change, no migration, no write path touched.
//
//  Core-model resolution is NOT reimplemented here. `resolveCoreModel()`
//  asks `MemoryService.resolveDistillModel()` directly (made public for this
//  purpose), so the panel can never report a different model than the one
//  the pipeline would actually use. It was briefly duplicated during
//  construction; two copies of a resolution chain that must agree is exactly
//  how they drift. Only the remediation text is owned here.
//
//  Per-agent "memory on/off": `AgentManager.effectiveMemoryDisabled(for:)`
//  (IntelManagerConformers.swift) currently mirrors the single global
//  `MemoryConfiguration.enabled` toggle for every agent — per-agent opt-in
//  is Phase 3, not yet implemented. Calling through that method (rather
//  than re-reading the global config directly) means this snapshot picks
//  up real per-agent state automatically the day Phase 3 lands, but today
//  every row in `perAgent` will show the same `memoryEnabled` value.
//

#if OSAURUS_INTEL

import Foundation

@MainActor
public final class MemoryDiagnostics: ObservableObject {
    public static let shared = MemoryDiagnostics()

    @Published public private(set) var snapshot: MemoryDiagnosticsSnapshot?

    private init() {}

    /// Recompute `snapshot` from current database + in-process telemetry
    /// state. Cheap (a handful of indexed COUNT/GROUP BY queries) — safe to
    /// call whenever the diagnostics UI appears or the user hits refresh.
    public func refresh() async {
        let config = MemoryConfigurationStore.load()
        let db = MemoryDatabase.shared
        let databaseOpen = db.isOpen

        let signals = (try? db.pendingSignalsSummary()) ?? PendingSignalsSummary()
        let stats = (try? db.processingStats()) ?? ProcessingStats()
        let episodeCount = (try? db.episodeCount()) ?? 0
        let pinnedFactCount = (try? db.pinnedFactCount()) ?? 0
        let databaseBytes = db.databaseSizeBytes()
        let recentLog = ((try? db.recentProcessingLog(limit: 20)) ?? [])
            .map(MemoryProcessingLogEntry.init)

        let telemetry = await MemoryService.shared.bufferTelemetry()
        let (coreModel, coreModelDetail) = await Self.resolveCoreModel()
        let perAgent = Self.buildPerAgentBreakdown(db: db)

        snapshot = MemoryDiagnosticsSnapshot(
            memoryEnabled: config.enabled,
            databaseOpen: databaseOpen,
            extractionMode: config.extractionMode.rawValue,
            coreModel: coreModel,
            coreModelDetail: coreModelDetail,
            pendingSignals: signals.totalSignals,
            processedSignals: signals.processedSignals,
            deadSignals: signals.deadLetteredSignals,
            allTimeSignals: signals.allTimeSignals,
            distillOK: stats.successCount,
            distillSkipped: stats.skippedCount,
            distillErrors: stats.errorCount,
            distillEmpty: stats.emptyCount,
            distillDead: stats.deadLetterCount,
            episodeCount: episodeCount,
            pinnedFactCount: pinnedFactCount,
            bufferAttempts: telemetry.attempts,
            databaseBytes: databaseBytes,
            recentLog: recentLog,
            perAgent: perAgent
        )
    }

    // MARK: - Core Model Resolution

    /// Asks the distillation actor itself which model it would use, so the
    /// panel can never disagree with the pipeline it is reporting on. The
    /// remediation text is ours; the resolution is not.
    private static func resolveCoreModel() async -> (model: String?, detail: String?) {
        if let model = await MemoryService.shared.resolveDistillModel(), !model.isEmpty {
            return (model, nil)
        }
        return (
            nil,
            "No core model is configured and no connected provider has discovered any models yet. "
                + "Distillation cannot run until one resolves — signals will stay pending. "
                + "Add a provider and let it discover models, or set an explicit Core Model, in Settings."
        )
    }

    // MARK: - Per-Agent Breakdown

    private static func buildPerAgentBreakdown(db: MemoryDatabase) -> [MemoryAgentDiagnostic] {
        let pinnedByAgent = Dictionary(
            uniqueKeysWithValues: ((try? db.agentIdsWithPinnedFacts()) ?? []).map { ($0.agentId, $0.count) })
        let episodesByAgent = Dictionary(
            uniqueKeysWithValues: ((try? db.agentIdsWithEpisodes()) ?? []).map { ($0.agentId, $0.count) })
        let pendingByAgent = Dictionary(
            uniqueKeysWithValues: ((try? db.agentIdsWithPendingSignals()) ?? []).map { ($0.agentId, $0.count) })

        let manager = AgentManager.shared
        var seen = Set<String>()
        var result: [MemoryAgentDiagnostic] = []

        for agent in manager.agents {
            let key = agent.id.uuidString
            seen.insert(key)
            result.append(
                MemoryAgentDiagnostic(
                    agentId: key,
                    agentName: agent.name,
                    memoryEnabled: !manager.effectiveMemoryDisabled(for: agent.id),
                    episodeCount: episodesByAgent[key] ?? 0,
                    pinnedFactCount: pinnedByAgent[key] ?? 0,
                    pendingSignalCount: pendingByAgent[key] ?? 0
                )
            )
        }

        // Agent ids with memory data but no matching entry in the live
        // roster (e.g. a deleted custom agent) — surface them anyway so
        // counts are never silently dropped from the total.
        let orphanIds = Set(pinnedByAgent.keys)
            .union(episodesByAgent.keys)
            .union(pendingByAgent.keys)
            .subtracting(seen)
        let globalEnabled = MemoryConfigurationStore.load().enabled
        for key in orphanIds.sorted() {
            result.append(
                MemoryAgentDiagnostic(
                    agentId: key,
                    agentName: key,
                    memoryEnabled: globalEnabled,
                    episodeCount: episodesByAgent[key] ?? 0,
                    pinnedFactCount: pinnedByAgent[key] ?? 0,
                    pendingSignalCount: pendingByAgent[key] ?? 0
                )
            )
        }

        return result
    }
}

// MARK: - Snapshot

public struct MemoryDiagnosticsSnapshot: Sendable {
    public let memoryEnabled: Bool
    public let databaseOpen: Bool
    public let extractionMode: String
    /// nil => unavailable; see `coreModelDetail` for remediation text.
    public let coreModel: String?
    public let coreModelDetail: String?
    public let pendingSignals: Int
    public let processedSignals: Int
    public let deadSignals: Int
    public let allTimeSignals: Int
    public let distillOK: Int
    public let distillSkipped: Int
    public let distillErrors: Int
    public let distillEmpty: Int
    public let distillDead: Int
    public let episodeCount: Int
    public let pinnedFactCount: Int
    /// 0 => `bufferTurn` was never invoked this process — the single most
    /// diagnostic number here. Reset on every relaunch (see
    /// `BufferTurnTelemetry`'s doc comment in `MemoryModels.swift`).
    public let bufferAttempts: Int
    public let databaseBytes: Int64
    public let recentLog: [MemoryProcessingLogEntry]
    public let perAgent: [MemoryAgentDiagnostic]
}

/// Diagnostics-panel view of a `processing_log` row. Thin `Sendable` copy of
/// `ProcessingLogRow` (`Models/Memory/MemoryModels.swift`) — kept as a
/// distinct type per the §5 contract rather than reusing that struct
/// directly, so the UI lane binds to a name that's stable regardless of how
/// the storage-layer row type evolves.
public struct MemoryProcessingLogEntry: Sendable, Identifiable {
    public let id: Int
    public let agentId: String
    public let taskType: String
    public let model: String?
    public let status: String
    public let details: String?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let durationMs: Int?
    public let createdAt: String

    init(_ row: ProcessingLogRow) {
        id = row.id
        agentId = row.agentId
        taskType = row.taskType
        model = row.model
        status = row.status
        details = row.details
        inputTokens = row.inputTokens
        outputTokens = row.outputTokens
        durationMs = row.durationMs
        createdAt = row.createdAt
    }
}

/// Per-agent row for the diagnostics panel's breakdown table.
public struct MemoryAgentDiagnostic: Sendable, Identifiable {
    public var id: String { agentId }
    public let agentId: String
    public let agentName: String
    public let memoryEnabled: Bool
    public let episodeCount: Int
    public let pinnedFactCount: Int
    public let pendingSignalCount: Int
}

#endif
