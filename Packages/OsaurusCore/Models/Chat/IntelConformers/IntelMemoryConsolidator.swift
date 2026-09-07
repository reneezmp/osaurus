//
//  IntelMemoryConsolidator.swift
//  OsaurusCore (Intel fork)
//
//  Intel equivalent of the excluded `Services/Memory/MemoryConsolidator.swift`
//  (see that file's `exclude:` entry in Package.swift — it sits on disk,
//  reads clean, and is never compiled). That file's only caller lived behind
//  `#if !OSAURUS_INTEL`, so on this fork consolidation has never run: pinned
//  facts and episodes never decay, near-duplicate episodes never merge,
//  nothing gets promoted or evicted, and the transcript grows forever.
//
//  This actor reimplements the same five steps against the tables and
//  methods `MemoryDatabase` already ships (decay/evict/prune are storage-
//  layer concerns and were never the missing piece — the orchestration was):
//
//    1. Salience decay      — `MemoryDatabase.decayPinnedSalience` /
//                             `decayEpisodeSalience`, half-life from
//                             `MemoryConfiguration.salienceHalfLifeDays`.
//    2. Episode merge       — near-duplicate episodes from the same agent,
//                             compared by real cosine similarity over the
//                             embeddings already stored on each episode row
//                             (`MemoryDatabase.loadEmbeddedEpisodes`), using
//                             the same `MemorySearchService.cosine` the recall
//                             path uses. No new embedding calls are made —
//                             episodes without a stored vector (embeddings
//                             disabled, or distilled before an embedder was
//                             configured) simply sit out this step.
//    3. Pinned promotion    — facts whose content overlaps (word-shingle
//                             Jaccard) at least `pinnedPromotionThreshold`
//                             recent episodes get a small salience boost.
//    4. Eviction            — pinned facts below `salienceFloor`, idle 30+
//                             days, are deleted via `evictPinnedFacts`.
//    5. Transcript pruning  — episodes and transcript rows older than
//                             `episodeRetentionDays` are removed. A retention
//                             of 0 means "keep forever" (`MemoryConfiguration`'s
//                             own documented semantics, and `pruneEpisodes` /
//                             `pruneTranscript` already treat `days <= 0` as
//                             a no-op at the storage layer) — never treated
//                             as "delete everything."
//
//  Deliberately NOT carried over from the excluded reference:
//    * Vector-store cleanup after prune (`pruneTranscriptReturningKeys` +
//      per-key `MemorySearchService.removeDocument`). That existed because
//      upstream indexes transcript turns in a separate VecturaKit store that
//      SQL deletes don't touch. On Intel there is no separate vector store —
//      `MemorySearchService` (`IntelMemoryConformers.swift`) keeps embeddings
//      as BLOB columns on the same SQLite rows, so `pruneTranscript` alone
//      already removes them. `MemorySearchService.clearIndex()` on this fork
//      is a documented no-op for the same reason.
//    * `MemoryContextAssembler.shared.invalidateCache()` at the end of a
//      pass. `MemoryContextAssembler.swift` is excluded on Intel and
//      `IntelMemoryService.swift` already notes recall has no cache to
//      invalidate here (a known, separately-tracked gap — see
//      docs/MEMORY_PLAN.md).
//    * Episode-merge similarity swapped from upstream's Jaccard/shingle
//      overlap (a stated stopgap in the excluded file: "cosine when
//      embeddings are available is left for a later pass") to real cosine
//      over stored embeddings, per this phase's brief. Pinned-promotion
//      overlap stays Jaccard/shingle, matching the excluded reference —
//      that heuristic doesn't claim to be a cosine threshold and has no
//      stored per-fact vector guarantee to lean on.
//

#if OSAURUS_INTEL

import Foundation

public actor MemoryConsolidator {
    public static let shared = MemoryConsolidator()

    /// `processing_log.task_type` for every pass this actor runs. Doubles as
    /// the audit trail (house rule: log what eviction/pruning removed) and
    /// the scheduling gate (`isDue` looks for the most recent successful row
    /// of this type — see the comment on `lastSuccessfulRun` for why the log
    /// table was chosen over the config file).
    private static let taskType = "consolidate"

    /// `processing_log.agent_id` for those rows. Consolidation spans every
    /// agent in one pass, but the column is `NOT NULL TEXT` with no "no
    /// agent" sentinel of its own, so this fork-local, non-personal marker
    /// stands in for "the whole database," not any real agent.
    private static let logAgentId = "_consolidator_"

    /// How often the background loop re-checks whether a pass is due. Cheap
    /// (one indexed SQLite read) and short enough that a live edit to
    /// `consolidationIntervalHours`, or an app restart partway through an
    /// overdue interval, is picked up within the hour rather than only after
    /// another full interval of continuous uptime.
    private static let pollIntervalSeconds: UInt64 = 3600

    /// `loadEmbeddedEpisodes` always applies a recency filter; pass a window
    /// wide enough to reach effectively the whole history so merge dedup
    /// isn't silently limited to the last year, mirroring the excluded
    /// reference's unscoped `loadEpisodes(limit: 1000)` call.
    private static let unboundedHistoryDays = 36_500

    /// Idle grace period before an under-floor pinned fact is evicted.
    /// Matches the excluded reference; not currently a `MemoryConfiguration`
    /// knob, so it stays a named constant here rather than a magic number.
    private static let evictionIdleDays = 30

    /// How far back a candidate must appear across episodes to count toward
    /// promotion, and the minimum episodes count that appearance must clear.
    /// Matches the excluded reference.
    private static let promotionLookbackDays = 60
    private static let promotionShingleThreshold = 0.4
    private static let promotionSalienceBoost = 0.05

    private static let sqliteDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private var schedulerTask: Task<Void, Never>?
    private var isRunning = false

    private init() {}

    // MARK: - Scheduling

    /// Start the periodic loop. Idempotent — safe to call more than once
    /// (e.g. re-entering the launch path); a second call is a no-op.
    public func start() {
        guard schedulerTask == nil else { return }
        schedulerTask = Task.detached(priority: .background) { [weak self] in
            await self?.scheduleLoop()
        }
        MemoryLogger.service.info("MemoryConsolidator scheduler started")
    }

    public func stop() {
        schedulerTask?.cancel()
        schedulerTask = nil
    }

    private func scheduleLoop() async {
        while !Task.isCancelled {
            await runIfDue()
            try? await Task.sleep(for: .seconds(Self.pollIntervalSeconds))
        }
    }

    /// Run a pass only if `consolidationIntervalHours` has actually elapsed
    /// since the last *successful* pass. Called by the background loop; also
    /// safe to call directly (e.g. a future settings-changed hook) since it
    /// re-derives everything from persisted state rather than in-memory
    /// scheduler state.
    public func runIfDue() async {
        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return }
        guard MemoryDatabase.shared.isOpen else { return }
        guard isDue(intervalHours: config.consolidationIntervalHours) else {
            MemoryLogger.service.debug("MemoryConsolidator: not due yet")
            return
        }
        await runNow()
    }

    private func isDue(intervalHours: Int) -> Bool {
        guard let last = lastSuccessfulRun() else { return true }
        let elapsedHours = Date().timeIntervalSince(last) / 3600
        return elapsedHours >= Double(max(1, intervalHours))
    }

    /// Where the last-run timestamp lives, and why.
    ///
    /// Chose `processing_log` over adding a field to `MemoryConfiguration`:
    ///   - It already exists, is already compiled, and needs no schema
    ///     change or `decodeIfPresent` line — this file only touches the
    ///     two files it owns.
    ///   - It lives inside the same encrypted memory DB the consolidator
    ///     mutates, so "when did we last touch these rows" travels with the
    ///     rows themselves. `MemoryConfiguration` is a separate JSON file on
    ///     disk; if it and the DB ever drift out of sync (a restored DB
    ///     backup, a config reset) a config-file timestamp could silently
    ///     lie about the data it's supposed to describe.
    ///   - The diagnostics work in this same phase already surfaces
    ///     `processing_log` rows, so a consolidation pass becomes visible
    ///     there for free instead of needing its own display path.
    /// A pass writes exactly one summary row, at the end, on success. If the
    /// app quits mid-pass no row is written, so the next scheduler tick (or
    /// launch) sees the previous success as still stale and simply reruns
    /// the whole pass — safe, since every step below is its own committed
    /// SQL statement rather than one big transaction. The one known rough
    /// edge from that design (see report) is a pass that completes some
    /// steps, then crashes before logging: a full rerun re-decays salience
    /// using the already-decayed values, since decay is computed from
    /// `now - last_used`/`now - conversation_at`, not from a delta since the
    /// last run. That is an existing property of `batchedDecaySalience` in
    /// `MemoryDatabase` (unowned by this file), not something introduced
    /// here, and it requires an actual mid-pass crash to matter.
    private func lastSuccessfulRun() -> Date? {
        // `recentProcessingLog` has no task_type filter, so read generously
        // far back (a once-per-poll, indexed-by-rowid read; cheap even at
        // this size) rather than risk an active install's `"distill"` rows
        // burying the one `"consolidate"` row we need.
        guard let rows = try? MemoryDatabase.shared.recentProcessingLog(limit: 2000) else { return nil }
        guard
            let row = rows.first(where: { $0.taskType == Self.taskType && $0.status == "success" })
        else { return nil }
        return Self.sqliteDateFormatter.date(from: row.createdAt)
    }

    // MARK: - Run

    /// Run a consolidation pass right now, bypassing the due-check. Called
    /// internally when the scheduler decides a pass is due; also the entry
    /// point a future manual "Run Now" control should call directly. No such
    /// UI call site exists yet — that lands in the Views/Memory lane (the
    /// diagnostics/danger-zone cards this phase is also building out).
    /// Serializes internally so a manual trigger and the scheduler can't
    /// double-run.
    public func runNow() async {
        guard !isRunning else {
            MemoryLogger.service.debug("MemoryConsolidator: already running; skipping concurrent trigger")
            return
        }
        isRunning = true
        defer { isRunning = false }

        let config = MemoryConfigurationStore.load()
        guard config.enabled, MemoryDatabase.shared.isOpen else { return }

        let started = Date()
        MemoryLogger.service.info("MemoryConsolidator: starting pass")

        let identityDuplicates: Int
        do {
            identityDuplicates = try MemoryDatabase.shared.deduplicateIdentityOverrides()
        } catch {
            MemoryLogger.service.warning("MemoryConsolidator: identity cleanup failed: \(error)")
            identityDuplicates = 0
        }

        do {
            try MemoryDatabase.shared.decayPinnedSalience(halfLifeDays: MemoryConfiguration.salienceHalfLifeDays)
            try MemoryDatabase.shared.decayEpisodeSalience(halfLifeDays: MemoryConfiguration.salienceHalfLifeDays)
        } catch {
            MemoryLogger.service.warning("MemoryConsolidator: decay step failed: \(error)")
        }

        let mergedCount = mergeNearDuplicateEpisodes(threshold: config.episodeMergeCosineThreshold)
        let promotedCount = promotePinnedCandidates()

        var evictedCount = 0
        do {
            evictedCount = try MemoryDatabase.shared.evictPinnedFacts(
                belowSalience: config.salienceFloor,
                idleDays: Self.evictionIdleDays
            )
        } catch {
            MemoryLogger.service.warning("MemoryConsolidator: eviction failed: \(error)")
        }

        var prunedEpisodes = 0
        var prunedTurns = 0
        // `episodeRetentionDays == 0` means "keep forever" (documented on
        // `MemoryConfiguration.episodeRetentionDays`); `pruneEpisodes` and
        // `pruneTranscript` already no-op for `days <= 0`, but the guard
        // here keeps that intent explicit at the call site rather than
        // relying silently on the storage layer.
        if config.episodeRetentionDays > 0 {
            do {
                prunedEpisodes = try MemoryDatabase.shared.pruneEpisodes(olderThanDays: config.episodeRetentionDays)
                // No separate vector store to keep in sync here (see the
                // file header) — deleting the row deletes its embedding
                // BLOB column with it.
                prunedTurns = try MemoryDatabase.shared.pruneTranscript(olderThanDays: config.episodeRetentionDays)
            } catch {
                MemoryLogger.service.warning("MemoryConsolidator: prune failed: \(error)")
            }
        }

        do {
            try MemoryDatabase.shared.purgeOldEventData()
        } catch {
            MemoryLogger.service.warning("MemoryConsolidator: purge failed: \(error)")
        }

        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        let details =
            "merged=\(mergedCount) promoted=\(promotedCount) evicted=\(evictedCount) "
            + "prunedEpisodes=\(prunedEpisodes) prunedTranscript=\(prunedTurns) "
            + "identityDuplicates=\(identityDuplicates) "
            + "[merge: \(lastMergeDiagnostics)]"
        do {
            try MemoryDatabase.shared.insertProcessingLog(
                agentId: Self.logAgentId,
                taskType: Self.taskType,
                model: nil,
                status: "success",
                details: details,
                durationMs: durationMs
            )
        } catch {
            MemoryLogger.service.warning("MemoryConsolidator: failed to write processing log: \(error)")
        }

        MemoryLogger.service.info("MemoryConsolidator: pass done (\(details), \(durationMs)ms)")
    }

    // MARK: - Episode merge

    /// Merge near-duplicate episodes from the same agent using cosine
    /// similarity over each episode's already-stored embedding (written at
    /// distillation time by `MemorySearchService.indexEpisode`). Reuses
    /// `MemorySearchService.cosine` (`IntelMemoryConformers.swift`) — the
    /// same routine the recall path scores with — rather than computing a
    /// new one. Makes no embedding calls: episodes without a stored vector
    /// (embeddings disabled, or distilled before an embedder was configured)
    /// don't participate and are left untouched.
    /// Set by each run so the summary log can distinguish the three very
    /// different reasons a merge count of zero happens: no episodes carry
    /// embeddings at all, episodes exist but none were similar enough, or
    /// there was simply nothing to compare. "merged=0" on its own is not
    /// diagnosable, and that ambiguity cost a round of guesswork.
    private var lastMergeDiagnostics: String = "considered=0 embedded=0"

    private func mergeNearDuplicateEpisodes(threshold: Double) -> Int {
        let embedded =
            (try? MemoryDatabase.shared.loadEmbeddedEpisodes(
                days: Self.unboundedHistoryDays, limit: 2000
            )) ?? []
        let embeddedCount = embedded.filter { !$0.1.isEmpty }.count
        var bestSimilarity = 0.0
        lastMergeDiagnostics = "considered=\(embedded.count) embedded=\(embeddedCount)"
        guard embedded.count > 1 else { return 0 }

        let byAgent = Dictionary(grouping: embedded, by: { $0.episode.agentId })
        var merged = 0

        for (_, group) in byAgent {
            guard group.count > 1 else { continue }
            var consumed = Set<Int>()
            for i in 0..<group.count {
                let (epI, vecI) = group[i]
                if consumed.contains(epI.id) { continue }
                for j in (i + 1)..<group.count {
                    let (epJ, vecJ) = group[j]
                    if consumed.contains(epJ.id) { continue }
                    guard vecI.count == vecJ.count, !vecI.isEmpty else { continue }
                    let sim = Double(MemorySearchService.cosine(vecI, vecJ))
                    if sim > bestSimilarity { bestSimilarity = sim }
                    guard sim >= threshold else { continue }

                    // Keep the older episode; delete the newer near-dup.
                    let keep = epI.conversationAt <= epJ.conversationAt ? epI : epJ
                    let drop = keep.id == epI.id ? epJ : epI
                    do {
                        try MemoryDatabase.shared.deleteEpisode(id: drop.id)
                        consumed.insert(drop.id)
                        merged += 1
                    } catch {
                        MemoryLogger.service.warning("MemoryConsolidator: merge delete failed: \(error)")
                    }
                }
            }
        }

        lastMergeDiagnostics =
            "considered=\(embedded.count) embedded=\(embeddedCount) "
            + String(format: "bestSim=%.2f threshold=%.2f", bestSimilarity, threshold)
        return merged
    }

    // MARK: - Pinned candidate promotion

    /// Boost salience on pinned facts whose content overlaps (word-shingle
    /// Jaccard) with at least `pinnedPromotionThreshold` recent episodes.
    /// Cheap heuristic reused verbatim from the excluded reference — the
    /// distillation prompt does most of the actual promoting itself; this
    /// just rewards facts that keep resurfacing across sessions.
    private func promotePinnedCandidates() -> Int {
        let recentEpisodes =
            (try? MemoryDatabase.shared.loadEpisodes(days: Self.promotionLookbackDays, limit: 200)) ?? []
        guard !recentEpisodes.isEmpty else { return 0 }
        let pinned = (try? MemoryDatabase.shared.loadPinnedFacts(limit: 500)) ?? []
        guard !pinned.isEmpty else { return 0 }

        let episodeShingles = recentEpisodes.map {
            TextSimilarity.shingleSet($0.summary + " " + $0.topicsCSV + " " + $0.entitiesCSV)
        }

        var promoted = 0
        for fact in pinned {
            let factShingles = TextSimilarity.shingleSet(fact.content)
            let hits = episodeShingles.reduce(0) { count, sh in
                count + (TextSimilarity.jaccardTokenized(factShingles, sh) >= Self.promotionShingleThreshold ? 1 : 0)
            }
            guard hits >= MemoryConfiguration.pinnedPromotionThreshold else { continue }
            let boosted = min(1.0, fact.salience + Self.promotionSalienceBoost)
            guard boosted > fact.salience + 0.001 else { continue }
            do {
                try MemoryDatabase.shared.updatePinnedFactSalience(id: fact.id, salience: boosted)
                promoted += 1
            } catch {
                MemoryLogger.service.warning("MemoryConsolidator: promotion update failed: \(error)")
            }
        }
        return promoted
    }
}

#endif
