//
//  MemoryConfiguration.swift
//  osaurus
//
//  User-configurable settings for the v2 memory system.
//
//  v2 collapses 18 tunable settings down to 8: the big losses are the
//  per-section budget knobs, MMR/recall tuning, profile regeneration
//  thresholds, and the verification thresholds. The new model has a single
//  overall token budget and a single salience floor; everything else is
//  internal.
//

import Foundation
import os

/// How aggressively the memory system distills new content from chat.
public enum MemoryExtractionMode: String, Codable, Sendable {
    /// Buffer turns and run a single distillation pass at session end
    /// (debounced or on nav-away). Default. Most turns produce zero LLM calls.
    case sessionEnd
    /// No automatic distillation — only `flushSession` and `syncNow` triggers
    /// produce episodes. Useful for benchmark ingestion or for users who
    /// want full control.
    case manual
}

/// Strategy for the per-turn relevance gate that decides whether memory
/// should be injected at all.
public enum MemoryRelevanceGateMode: String, Codable, Sendable {
    /// Always inject (legacy behavior; not recommended).
    case off
    /// Cheap rule-based check: pronouns referencing prior context, entity
    /// hits in the graph, temporal markers, and identity-curious phrases.
    case heuristic
    /// Heuristic first, with a single LLM classifier call when the
    /// heuristic is ambiguous.
    case llm
}

public struct MemoryConfiguration: Codable, Equatable, Sendable {
    /// Master toggle for the memory system.
    public var enabled: Bool

    /// Embedding backend ("mlx" or "none"). When "none", search falls back
    /// to SQLite text matching. (Legacy upstream field; on the Intel fork the
    /// active selection is `embeddingProvider` below — MLX is amputated.)
    public var embeddingBackend: String
    /// Embedding model name (used by VecturaKit when `embeddingBackend == "mlx"`).
    public var embeddingModel: String

    /// (Intel) Which embedder produces vectors for memory:
    /// - `"staticLocal"`: the bundled pure-Swift model2vec embedder (offline, fast)
    /// - `"cloud"`: an OpenAI-compatible `/v1/embeddings` provider
    /// - `"none"`: no embeddings; recall falls back to SQLite FTS5 text search
    public var embeddingProvider: String
    /// For `embeddingProvider == "cloud"`: the `/v1/embeddings` base endpoint
    /// (matched against a configured RemoteProvider for auth), e.g.
    /// `https://api.openai.com/v1`.
    public var cloudEmbeddingEndpoint: String?
    /// For `embeddingProvider == "cloud"`: the embedding model id, e.g.
    /// `text-embedding-3-small`.
    public var cloudEmbeddingModel: String?
    /// Vector dimension written by the active embedder. Stored alongside vectors
    /// so a backend switch can detect a mismatch and trigger a re-embed.
    public var embeddingDimensionality: Int

    /// When the write pipeline runs distillation. Default `sessionEnd`.
    public var extractionMode: MemoryExtractionMode

    /// How the read pipeline decides whether to inject memory.
    public var relevanceGateMode: MemoryRelevanceGateMode

    /// Single overall budget for memory context injected per turn (tokens).
    /// The planner picks one section and stays within this cap. Identity
    /// overrides are exempt (they're tiny and always included).
    public var memoryBudgetTokens: Int

    /// Inactivity (seconds) before the writer flushes a session and runs
    /// distillation.
    public var summaryDebounceSeconds: Int

    /// How often the consolidator runs, in hours (decay, dedup, evict, promote).
    public var consolidationIntervalHours: Int

    /// Salience floor for `pinned_facts`. Pinned facts whose decayed
    /// salience falls below this threshold are evicted by the consolidator
    /// (subject to the use-count and last-used grace period).
    public var salienceFloor: Double

    /// Episodes (and their parent transcripts) older than this are pruned
    /// by the consolidator. Set to 0 to keep forever.
    public var episodeRetentionDays: Int

    /// Similarity above which consolidation merges two stored entries as
    /// near-duplicates. Higher = only merge when near-identical (fewer
    /// merges); lower = merge more eagerly.
    ///
    /// Applies to all three stores, merged in one phase before the other
    /// consolidation steps (owner decision 2026-09-07):
    ///   - **Episodes** and **pinned facts** — compared by cosine over their
    ///     stored embeddings (pinned facts fall back to word-overlap when a
    ///     vector is missing). The survivor keeps its higher-salience copy.
    ///   - **Identity overrides** — compared by word-overlap (they have no
    ///     vectors); the longer wording survives, and polarity-conflicting
    ///     pairs are never merged.
    ///
    /// The property name (and persisted JSON key) retains "Episode" from when
    /// it was an episodes-only constant; renaming would silently reset a saved
    /// value on disk, so the historical name is kept. The Memory → Settings
    /// slider ("Merge threshold") is the single control for all three.
    ///
    /// Default intentionally unchanged (0.9) so existing behavior is preserved
    /// until an owner lowers it.
    public var episodeMergeCosineThreshold: Double

    /// Per-agent opt-in for **distillation** — the cloud call in
    /// `MemoryService.performDistillSession` that sends buffered conversation
    /// turns to a remote provider for summarising. Keyed by agent UUID
    /// string; absence of a key (or a `false` value) means "not opted in".
    ///
    /// This is deliberately separate from `enabled` above. `enabled` (and
    /// the local recall/write path it gates in `ChatView`) stays on-device —
    /// the embedder is `potion-base-8M`, a static local model, and nothing
    /// leaves the machine — and keeps its current default. Distillation is
    /// the one piece that talks to a cloud provider, and per the 2026-09-05
    /// owner decision (docs/MEMORY_PLAN.md §2, §2b) it becomes opt-in per
    /// agent, default OFF — a deliberate divergence from upstream (which
    /// defaults distillation on) that must not be "corrected" back.
    ///
    /// Shape mirrors `RelayConfiguration.enabledAgents`
    /// (Models/Configuration/RelayConfiguration.swift) — the existing
    /// precedent in this codebase for a per-agent opt-in to a cloud/network
    /// action — rather than a new field on `Agent` itself: this type doesn't
    /// own `Models/Agent/Agent.swift`, and this map works identically for
    /// the Default agent and every custom agent without needing a second
    /// storage location.
    public var distillationEnabledAgents: [String: Bool]

    // MARK: - Internal Constants (not user-configurable)

    /// Approximate characters per token for budget calculations. Coarse
    /// but fine for conservative budgeting.
    public static let charsPerToken = 4
    /// Maximum allowed content length for any single stored value.
    public static let maxContentLength = 50_000
    /// How many recent episodes to feed back into distillation as
    /// cross-session context.
    public static let distillContextEpisodeCount = 3
    /// Minimum combined (user+assistant) char count before distillation
    /// considers a turn worth processing.
    public static let distillNoveltyMinChars = 80
    /// Salience half-life in days, used by the consolidator's decay step.
    public static let salienceHalfLifeDays: Double = 30
    /// Number of episodes a candidate must appear in before the
    /// consolidator promotes it to a `pinned_fact`.
    public static let pinnedPromotionThreshold = 3
    /// Default LIMIT for the SQLite text-search fallback path.
    public static let fallbackSearchLimit = 20

    public init(
        enabled: Bool = true,
        embeddingBackend: String = "mlx",
        embeddingModel: String = "nomic-embed-text-v1.5",
        embeddingProvider: String = "staticLocal",
        cloudEmbeddingEndpoint: String? = nil,
        cloudEmbeddingModel: String? = nil,
        embeddingDimensionality: Int = 256,
        extractionMode: MemoryExtractionMode = .sessionEnd,
        relevanceGateMode: MemoryRelevanceGateMode = .heuristic,
        memoryBudgetTokens: Int = 800,
        summaryDebounceSeconds: Int = 60,
        consolidationIntervalHours: Int = 24,
        salienceFloor: Double = 0.2,
        episodeRetentionDays: Int = 365,
        episodeMergeCosineThreshold: Double = 0.9,
        distillationEnabledAgents: [String: Bool] = [:]
    ) {
        self.enabled = enabled
        self.embeddingBackend = embeddingBackend
        self.embeddingModel = embeddingModel
        self.embeddingProvider = embeddingProvider
        self.cloudEmbeddingEndpoint = cloudEmbeddingEndpoint
        self.cloudEmbeddingModel = cloudEmbeddingModel
        self.embeddingDimensionality = embeddingDimensionality
        self.extractionMode = extractionMode
        self.relevanceGateMode = relevanceGateMode
        self.memoryBudgetTokens = memoryBudgetTokens
        self.summaryDebounceSeconds = summaryDebounceSeconds
        self.consolidationIntervalHours = consolidationIntervalHours
        self.salienceFloor = salienceFloor
        self.episodeRetentionDays = episodeRetentionDays
        self.episodeMergeCosineThreshold = episodeMergeCosineThreshold
        self.distillationEnabledAgents = distillationEnabledAgents
    }

    /// Whether the given agent has opted in to cloud distillation. Default
    /// OFF: an agent with no entry (including the Default agent, and every
    /// agent created before this setting existed) has not opted in.
    public func isDistillationEnabled(for agentId: UUID) -> Bool {
        distillationEnabledAgents[agentId.uuidString] == true
    }

    /// Set (or clear) one agent's distillation opt-in. Storing `false`
    /// removes the key entirely rather than persisting an explicit "off" —
    /// mirrors `RelayConfiguration.setEnabled(_:for:)` so an agent that was
    /// never touched and one explicitly opted out are indistinguishable
    /// (both read back as "not opted in", which is what we want either way).
    public mutating func setDistillationEnabled(_ enabled: Bool, for agentId: UUID) {
        distillationEnabledAgents[agentId.uuidString] = enabled ? true : nil
    }

    /// Returns a copy with all values clamped to valid ranges.
    public func validated() -> MemoryConfiguration {
        var c = self
        c.memoryBudgetTokens = max(100, min(c.memoryBudgetTokens, 4000))
        c.summaryDebounceSeconds = max(10, min(c.summaryDebounceSeconds, 3600))
        c.consolidationIntervalHours = max(1, min(c.consolidationIntervalHours, 168))
        c.salienceFloor = max(0.0, min(c.salienceFloor, 1.0))
        c.episodeRetentionDays = max(0, min(c.episodeRetentionDays, 3650))
        c.episodeMergeCosineThreshold = max(0.0, min(c.episodeMergeCosineThreshold, 1.0))
        c.embeddingDimensionality = max(1, min(c.embeddingDimensionality, 8192))
        return c
    }

    public init(from decoder: Decoder) throws {
        let defaults = MemoryConfiguration()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        embeddingBackend = try c.decodeIfPresent(String.self, forKey: .embeddingBackend) ?? defaults.embeddingBackend
        embeddingModel = try c.decodeIfPresent(String.self, forKey: .embeddingModel) ?? defaults.embeddingModel
        embeddingProvider =
            try c.decodeIfPresent(String.self, forKey: .embeddingProvider) ?? defaults.embeddingProvider
        cloudEmbeddingEndpoint = try c.decodeIfPresent(String.self, forKey: .cloudEmbeddingEndpoint)
        cloudEmbeddingModel = try c.decodeIfPresent(String.self, forKey: .cloudEmbeddingModel)
        embeddingDimensionality =
            try c.decodeIfPresent(Int.self, forKey: .embeddingDimensionality) ?? defaults.embeddingDimensionality
        extractionMode =
            try c.decodeIfPresent(MemoryExtractionMode.self, forKey: .extractionMode) ?? defaults.extractionMode
        relevanceGateMode =
            try c.decodeIfPresent(MemoryRelevanceGateMode.self, forKey: .relevanceGateMode)
            ?? defaults.relevanceGateMode
        memoryBudgetTokens =
            try c.decodeIfPresent(Int.self, forKey: .memoryBudgetTokens) ?? defaults.memoryBudgetTokens
        summaryDebounceSeconds =
            try c.decodeIfPresent(Int.self, forKey: .summaryDebounceSeconds) ?? defaults.summaryDebounceSeconds
        consolidationIntervalHours =
            try c.decodeIfPresent(Int.self, forKey: .consolidationIntervalHours)
            ?? defaults.consolidationIntervalHours
        salienceFloor = try c.decodeIfPresent(Double.self, forKey: .salienceFloor) ?? defaults.salienceFloor
        episodeRetentionDays =
            try c.decodeIfPresent(Int.self, forKey: .episodeRetentionDays) ?? defaults.episodeRetentionDays
        episodeMergeCosineThreshold =
            try c.decodeIfPresent(Double.self, forKey: .episodeMergeCosineThreshold)
            ?? defaults.episodeMergeCosineThreshold
        distillationEnabledAgents =
            try c.decodeIfPresent([String: Bool].self, forKey: .distillationEnabledAgents)
            ?? defaults.distillationEnabledAgents
    }

    public static var `default`: MemoryConfiguration { MemoryConfiguration() }
}

// MARK: - Store

public enum MemoryConfigurationStore: Sendable {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let lock = OSAllocatedUnfairLock<MemoryConfiguration?>(initialState: nil)

    public static func load() -> MemoryConfiguration {
        if let cached = lock.withLock({ $0 }) { return cached }

        let url = OsaurusPaths.memoryConfigFile()
        // CRITICAL: see RemoteProviderConfigurationStore.load — never
        // auto-save an empty default on missing-file. The 2026-04
        // storage-migration recovery race showed this pattern can
        // permanently destroy user data.
        guard FileManager.default.fileExists(atPath: url.path) else {
            return MemoryConfiguration()
        }
        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(MemoryConfiguration.self, from: data)
            let validated = config.validated()
            lock.withLock { $0 = validated }
            return validated
        } catch {
            MemoryLogger.config.error("Failed to load config: \(error)")
            return .default
        }
    }

    public static func save(_ config: MemoryConfiguration) {
        let validated = config.validated()
        let url = OsaurusPaths.memoryConfigFile()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let data = try encoder.encode(validated)
            try data.write(to: url, options: .atomic)
            lock.withLock { $0 = validated }
        } catch {
            MemoryLogger.config.error("Failed to save config: \(error)")
        }
    }

    public static func invalidateCache() {
        lock.withLock { $0 = nil }
    }
}
