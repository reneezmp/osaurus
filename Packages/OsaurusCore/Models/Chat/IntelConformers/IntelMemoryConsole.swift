//
//  IntelMemoryConsole.swift
//  OsaurusCore (Intel fork)
//
//  Phase 4 — Memories console: data contracts + service
//  (docs/MEMORY_PLAN.md Phase 4). Ports upstream's
//  `MemoryManagementConsoleModels.swift` + `MemoryManagementConsoleService.swift`.
//  The view half lives in `Views/Memory/MemoryConsoleView.swift`.
//
//  Upstream's service queries `pinned_facts` / `episodes` / `transcript`
//  directly with raw SQL via `MemoryDatabase.prepareAndExecute`, bypassing
//  the higher-level query methods on purpose (so it can see rows the
//  runtime recall path excludes). That approach isn't mirrored here: this
//  file does not touch `MemoryDatabase` internals or SQL at all — it only
//  calls the typed methods that already exist on it (`loadPinnedFacts`,
//  `searchPinnedFactsText`, `loadEpisodes`, `searchEpisodesText`,
//  `loadTranscript`, `searchTranscriptText`, `deletePinnedFact`,
//  `deleteEpisode`), per the owning lane's instruction not to add new
//  `MemoryDatabase` methods from this pass.
//
//  Deliberate deviations from upstream, and why (each is a real capability
//  gap in this fork's `MemoryDatabase`, not a shortcut):
//
//   1. No "disable" mutation, no disabled-row visibility.
//      Upstream sets `status = 'disabled'` on `pinned_facts` / `episodes`
//      and its console can browse those rows via `includeDisabled`. This
//      fork's `MemoryDatabase` never writes any status besides "active" —
//      grep it: no `UPDATE pinned_facts SET status` / `UPDATE episodes SET
//      status` exists anywhere, and `evictPinnedFacts` hard-deletes rather
//      than soft-disabling. `loadPinnedFacts` / `searchPinnedFactsText` /
//      `loadEpisodes` / `searchEpisodesText` all hardcode
//      `WHERE status = 'active'`, so there is nothing a "show disabled"
//      toggle could ever reveal. Adding a soft-disable column/path is a
//      `MemoryDatabase` schema change — out of scope for this file (owned
//      by another lane right now). So `MemoryConsoleMutation` has only
//      `.forget`, and `MemoryConsoleQuery` has no `includeDisabled` field.
//      REPORTED GAP: real "disable without deleting" needs a
//      `MemoryDatabase` change in a future pass.
//
//   2. Transcript turns cannot be individually forgotten.
//      Upstream deletes a single transcript row by id. This fork's
//      `MemoryDatabase` exposes only `deleteTranscriptForConversation(_:)`
//      (the whole conversation) and `pruneTranscript(olderThanDays:)` — no
//      per-row delete. Silently deleting the entire conversation when the
//      user asked to forget one turn would be a correctness/safety
//      regression, not a fix, so `MemoryConsoleItem.canForget` is `false`
//      for `.transcriptTurn`, and `forget(itemId:)` returns
//      `changed: false` with an explanatory message if called anyway (belt
//      and suspenders under a UI that already disables the button).
//      REPORTED GAP: per-row transcript delete needs a `MemoryDatabase`
//      change in a future pass.
//
//   3. `MemoryStorageHealth` (schema version / FTS+vector diagnostics) is
//      not reproduced as its own struct. This fork has no public
//      schema-version accessor (`MemoryDatabase`'s schema version is a
//      private `static let`) and no separate vector index to report on —
//      `Services/Memory/MemorySearchService.swift` (upstream's Vectura
//      wrapper) is excluded on Intel; recall instead does per-turn cosine
//      ranking over inline embedding columns. Inventing those fields would
//      mean either a new `MemoryDatabase` method or fabricated values with
//      no live source — both against the brief. `MemoryConsoleSnapshot`
//      instead reuses the Phase 1 diagnostics service's own snapshot type,
//      `MemoryDiagnosticsSnapshot` (`IntelMemoryDiagnostics.swift`), which
//      already sources every number here from real `MemoryDatabase` /
//      `MemoryService` state.
//
//   4. `MemoryContextPreview` has no `query` field.
//      The only assembler available on Intel,
//      `MemoryContextAssembler.assembleContext(agentId:config:)`
//      (`Models/Chat/IntelConformers/IntelDataConformers.swift`), takes no
//      query string by construction — see its own doc comment: it produces
//      a budget-based estimate (identity + salience/recency-ordered pinned
//      facts + episodes), not a query-scoped recall, because the real
//      per-turn recall path it stands in for needs a query string this
//      call site (`refreshMemoryTokens`) never has. Keeping a "preview
//      query" text field that silently did nothing to the result would be
//      exactly the "control not wired to a real action" bug this project
//      is trying to stop shipping, so it is dropped from the model and the
//      view.
//

#if OSAURUS_INTEL

import Foundation

// MARK: - Scope / Kind

public enum MemoryConsoleScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case pinned
    case episodes
    case transcript

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "All"
        case .pinned: return "Pinned"
        case .episodes: return "Episodes"
        case .transcript: return "Transcript"
        }
    }
}

public enum MemoryConsoleItemKind: String, Sendable {
    case pinnedFact
    case episode
    case transcriptTurn

    public var displayName: String {
        switch self {
        case .pinnedFact: return "Pinned fact"
        case .episode: return "Episode"
        case .transcriptTurn: return "Transcript turn"
        }
    }
}

// MARK: - Query

public struct MemoryConsoleQuery: Equatable, Sendable {
    public var text: String
    public var scope: MemoryConsoleScope
    public var agentId: String?
    public var limit: Int

    public init(
        text: String = "",
        scope: MemoryConsoleScope = .all,
        agentId: String? = nil,
        limit: Int = 60
    ) {
        self.text = text
        self.scope = scope
        self.agentId = agentId
        self.limit = max(1, min(limit, 250))
    }

    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Redaction

public struct MemoryRedactionResult: Equatable, Sendable {
    public var text: String
    public var redactionCounts: [String: Int]
    public var originalCharacterCount: Int
    public var displayedCharacterCount: Int
    public var wasTruncated: Bool

    public init(
        text: String,
        redactionCounts: [String: Int] = [:],
        originalCharacterCount: Int,
        displayedCharacterCount: Int,
        wasTruncated: Bool
    ) {
        self.text = text
        self.redactionCounts = redactionCounts
        self.originalCharacterCount = originalCharacterCount
        self.displayedCharacterCount = displayedCharacterCount
        self.wasTruncated = wasTruncated
    }

    public var redactionCount: Int {
        redactionCounts.values.reduce(0, +)
    }
}

/// Privacy-safe redaction for anything the console displays. Pure Foundation
/// (`NSRegularExpression`), no `MemoryDatabase` dependency — ported verbatim
/// from upstream's service file.
public enum MemoryPrivacyRedactor {
    private struct Pattern {
        let name: String
        let replacement: String
        let regex: NSRegularExpression
    }

    private static func compile(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Invalid memory redaction regex: \(pattern)")
        }
    }

    private static let patterns: [Pattern] = [
        Pattern(
            name: "email",
            replacement: "[redacted email]",
            regex: compile(
                #"\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b"#,
                options: [.caseInsensitive]
            )
        ),
        Pattern(
            name: "url",
            replacement: "[redacted url]",
            regex: compile(
                #"\bhttps?://[^\s<>()]+"#,
                options: [.caseInsensitive]
            )
        ),
        Pattern(
            name: "secret",
            replacement: "[redacted secret]",
            regex: compile(
                #"\b(?:sk|pk|rk|ghp|gho|ghu|ghs|github_pat|hf|xoxb|xoxp)[A-Za-z0-9_\-]{16,}\b|\b[A-Fa-f0-9]{32,}\b"#,
                options: []
            )
        ),
        Pattern(
            name: "ssn",
            replacement: "[redacted ssn]",
            regex: compile(#"\b\d{3}-\d{2}-\d{4}\b"#)
        ),
        Pattern(
            name: "account",
            replacement: "[redacted account]",
            regex: compile(#"\b(?:\d[ -]?){13,19}\b"#)
        ),
        Pattern(
            name: "phone",
            replacement: "[redacted phone]",
            regex: compile(#"\b(?:\+?1[\s.\-]?)?(?:\(?\d{3}\)?[\s.\-]?)\d{3}[\s.\-]?\d{4}\b"#)
        ),
    ]

    public static func redact(_ text: String, maxCharacters: Int = 600) -> MemoryRedactionResult {
        let originalCount = text.count
        var redacted = text
        var counts: [String: Int] = [:]

        for pattern in patterns {
            let nsRange = NSRange(redacted.startIndex..., in: redacted)
            let matches = pattern.regex.matches(in: redacted, range: nsRange)
            guard !matches.isEmpty else { continue }
            counts[pattern.name, default: 0] += matches.count
            redacted = pattern.regex.stringByReplacingMatches(
                in: redacted,
                range: nsRange,
                withTemplate: pattern.replacement
            )
        }

        let boundedLimit = max(0, maxCharacters)
        let wasTruncated = redacted.count > boundedLimit
        if wasTruncated {
            let suffix = "..."
            if boundedLimit <= suffix.count {
                redacted = String(suffix.prefix(boundedLimit))
            } else {
                redacted = String(redacted.prefix(boundedLimit - suffix.count)) + suffix
            }
        }

        return MemoryRedactionResult(
            text: redacted,
            redactionCounts: counts,
            originalCharacterCount: originalCount,
            displayedCharacterCount: redacted.count,
            wasTruncated: wasTruncated
        )
    }
}

// MARK: - Item

public struct MemoryConsoleMetadata: Equatable, Sendable {
    public var salience: Double?
    public var sourceCount: Int?
    public var sourceEpisodeId: Int?
    public var lastUsed: String?
    public var useCount: Int?
    public var status: String?
    public var createdAt: String?
    public var tokenCount: Int?
    public var conversationAt: String?
    public var conversationId: String?
    public var conversationTitle: String?
    public var chunkIndex: Int?
    public var role: String?
    public var model: String?
    public var tags: [String]
    public var topics: [String]
    public var entities: [String]

    public init(
        salience: Double? = nil,
        sourceCount: Int? = nil,
        sourceEpisodeId: Int? = nil,
        lastUsed: String? = nil,
        useCount: Int? = nil,
        status: String? = nil,
        createdAt: String? = nil,
        tokenCount: Int? = nil,
        conversationAt: String? = nil,
        conversationId: String? = nil,
        conversationTitle: String? = nil,
        chunkIndex: Int? = nil,
        role: String? = nil,
        model: String? = nil,
        tags: [String] = [],
        topics: [String] = [],
        entities: [String] = []
    ) {
        self.salience = salience
        self.sourceCount = sourceCount
        self.sourceEpisodeId = sourceEpisodeId
        self.lastUsed = lastUsed
        self.useCount = useCount
        self.status = status
        self.createdAt = createdAt
        self.tokenCount = tokenCount
        self.conversationAt = conversationAt
        self.conversationId = conversationId
        self.conversationTitle = conversationTitle
        self.chunkIndex = chunkIndex
        self.role = role
        self.model = model
        self.tags = tags
        self.topics = topics
        self.entities = entities
    }
}

public struct MemoryConsoleItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: MemoryConsoleItemKind
    public var storageId: String
    public var agentId: String
    /// Not currently rendered by `MemoryConsoleResultRow` / the inspect
    /// sheet — upstream's own console never displays this field either
    /// (it shows `kind.displayName` in both places instead). Kept anyway
    /// for structural parity and because `episodeTitle(date:topics:)`'s
    /// nicer "day - topic" formatting is still useful if a future pass
    /// wires it in.
    public var title: String
    public var preview: MemoryRedactionResult
    public var detail: MemoryRedactionResult
    public var relevanceExplanation: String
    public var metadata: MemoryConsoleMetadata
    /// `false` only for `.transcriptTurn` — see deviation #2 above.
    public var canForget: Bool

    public init(
        id: String,
        kind: MemoryConsoleItemKind,
        storageId: String,
        agentId: String,
        title: String,
        preview: MemoryRedactionResult,
        detail: MemoryRedactionResult,
        relevanceExplanation: String,
        metadata: MemoryConsoleMetadata,
        canForget: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.storageId = storageId
        self.agentId = agentId
        self.title = title
        self.preview = preview
        self.detail = detail
        self.relevanceExplanation = relevanceExplanation
        self.metadata = metadata
        self.canForget = canForget
    }
}

public struct MemoryConsoleSnapshot: Sendable {
    public var query: MemoryConsoleQuery
    public var items: [MemoryConsoleItem]
    /// Reuses the Phase 1 diagnostics snapshot rather than a bespoke
    /// `MemoryStorageHealth` — see deviation #3 above. `nil` only if
    /// `MemoryDiagnostics.refresh()` hasn't completed yet.
    public var health: MemoryDiagnosticsSnapshot?
    public var generatedAt: Date

    public init(
        query: MemoryConsoleQuery,
        items: [MemoryConsoleItem],
        health: MemoryDiagnosticsSnapshot?,
        generatedAt: Date = Date()
    ) {
        self.query = query
        self.items = items
        self.health = health
        self.generatedAt = generatedAt
    }
}

/// Only `.forget` — see deviation #1 above.
public enum MemoryConsoleMutation: String, Sendable {
    case forget
}

public struct MemoryConsoleMutationResult: Equatable, Sendable {
    public var itemId: String
    public var mutation: MemoryConsoleMutation
    public var changed: Bool
    public var message: String

    public init(
        itemId: String,
        mutation: MemoryConsoleMutation,
        changed: Bool,
        message: String
    ) {
        self.itemId = itemId
        self.mutation = mutation
        self.changed = changed
        self.message = message
    }
}

/// No `query` field — see deviation #4 above.
public struct MemoryContextPreview: Equatable, Sendable {
    public var agentId: String
    public var maxTokens: Int
    public var estimatedTokens: Int
    public var redactedContext: MemoryRedactionResult
    public var wasEmpty: Bool

    public init(
        agentId: String,
        maxTokens: Int,
        estimatedTokens: Int,
        redactedContext: MemoryRedactionResult,
        wasEmpty: Bool
    ) {
        self.agentId = agentId
        self.maxTokens = maxTokens
        self.estimatedTokens = estimatedTokens
        self.redactedContext = redactedContext
        self.wasEmpty = wasEmpty
    }
}

// MARK: - Service

public struct MemoryManagementConsoleService: Sendable {
    /// Transcript scope has no "unbounded" query option on this fork's
    /// `MemoryDatabase` (`loadTranscript`/`searchTranscriptText` both take
    /// a `days` window, defaulting to 30/365) — 10 years stands in for
    /// "effectively all of it" for console browsing purposes.
    private static let transcriptDaysWindow = 3650

    public init() {}

    public func snapshot(
        query: MemoryConsoleQuery,
        db: MemoryDatabase = .shared
    ) async throws -> MemoryConsoleSnapshot {
        // Mirrors upstream: the Memory tab can race ahead of the shared
        // database's own lazy open, and `open()` is idempotent/serialized,
        // so opening here just avoids a spurious "not open" error on
        // startup-ordering races.
        if !db.isOpen {
            try? db.open()
        }
        let items = try search(query: query, db: db)
        await MemoryDiagnostics.shared.refresh()
        let health = await MemoryDiagnostics.shared.snapshot
        return MemoryConsoleSnapshot(query: query, items: items, health: health)
    }

    public func search(
        query: MemoryConsoleQuery,
        db: MemoryDatabase = .shared
    ) throws -> [MemoryConsoleItem] {
        let terms = Self.searchTerms(query.trimmedText)
        var items: [MemoryConsoleItem] = []

        if query.scope == .all || query.scope == .pinned {
            items.append(contentsOf: try loadPinnedItems(query: query, terms: terms, db: db))
        }
        if query.scope == .all || query.scope == .episodes {
            items.append(contentsOf: try loadEpisodeItems(query: query, terms: terms, db: db))
        }
        if query.scope == .all || query.scope == .transcript {
            items.append(contentsOf: try loadTranscriptItems(query: query, terms: terms, db: db))
        }

        return Array(items.sorted(by: Self.sortConsoleItems).prefix(query.limit))
    }

    public func forget(
        itemId: String,
        db: MemoryDatabase = .shared
    ) async throws -> MemoryConsoleMutationResult {
        let parsed = try Self.parseItemId(itemId)
        switch parsed.kind {
        case .pinnedFact:
            try db.deletePinnedFact(id: parsed.storageId)
            return MemoryConsoleMutationResult(
                itemId: itemId,
                mutation: .forget,
                changed: true,
                message: L("Pinned fact forgotten.")
            )

        case .episode:
            guard let episodeId = Int(parsed.storageId) else {
                throw MemoryDatabaseError.failedToExecute("Invalid episode id: \(parsed.storageId)")
            }
            try db.deleteEpisode(id: episodeId)
            return MemoryConsoleMutationResult(
                itemId: itemId,
                mutation: .forget,
                changed: true,
                message: L("Episode forgotten.")
            )

        case .transcriptTurn:
            // See deviation #2: no per-row transcript delete exists yet.
            return MemoryConsoleMutationResult(
                itemId: itemId,
                mutation: .forget,
                changed: false,
                message: L(
                    "Transcript turns can't be forgotten individually yet — only whole conversations can be cleared. Use Clear Memory in Settings to remove all stored conversation history."
                )
            )
        }
    }

    public func contextPreview(
        agentId: String,
        maxTokens: Int,
        config: MemoryConfiguration = MemoryConfigurationStore.load()
    ) async -> MemoryContextPreview {
        var previewConfig = config.validated()
        previewConfig.memoryBudgetTokens = max(100, min(maxTokens, 4000))
        let assembled = await MemoryContextAssembler.assembleContext(agentId: agentId, config: previewConfig)
        let trimmed = ((assembled as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let maxChars = max(1, maxTokens) * MemoryConfiguration.charsPerToken
        let redacted = MemoryPrivacyRedactor.redact(
            trimmed.isEmpty ? "(No memory context assembled.)" : trimmed,
            maxCharacters: maxChars
        )
        return MemoryContextPreview(
            agentId: agentId,
            maxTokens: maxTokens,
            estimatedTokens: max(1, redacted.text.count / MemoryConfiguration.charsPerToken),
            redactedContext: redacted,
            wasEmpty: trimmed.isEmpty
        )
    }

    // MARK: - Loading

    private func loadPinnedItems(
        query: MemoryConsoleQuery,
        terms: [String],
        db: MemoryDatabase
    ) throws -> [MemoryConsoleItem] {
        let facts: [PinnedFact]
        if !query.trimmedText.isEmpty {
            facts = try db.searchPinnedFactsText(
                query: query.trimmedText,
                agentId: query.agentId,
                limit: query.limit
            )
        } else {
            facts = try db.loadPinnedFacts(agentId: query.agentId, limit: query.limit)
        }
        return facts.map { Self.pinnedItem($0, terms: terms) }
    }

    private func loadEpisodeItems(
        query: MemoryConsoleQuery,
        terms: [String],
        db: MemoryDatabase
    ) throws -> [MemoryConsoleItem] {
        let episodes: [Episode]
        if !query.trimmedText.isEmpty {
            episodes = try db.searchEpisodesText(
                query: query.trimmedText,
                agentId: query.agentId,
                limit: query.limit
            )
        } else {
            episodes = try db.loadEpisodes(agentId: query.agentId, days: 0, limit: query.limit)
        }
        return episodes.map { Self.episodeItem($0, terms: terms) }
    }

    private func loadTranscriptItems(
        query: MemoryConsoleQuery,
        terms: [String],
        db: MemoryDatabase
    ) throws -> [MemoryConsoleItem] {
        let turns: [TranscriptTurn]
        if !query.trimmedText.isEmpty {
            turns = try db.searchTranscriptText(
                query: query.trimmedText,
                agentId: query.agentId,
                days: Self.transcriptDaysWindow,
                limit: query.limit
            )
        } else {
            turns = try db.loadTranscript(
                agentId: query.agentId,
                days: Self.transcriptDaysWindow,
                limit: query.limit
            )
        }
        return turns.map { Self.transcriptItem($0, terms: terms) }
    }

    // MARK: - Row Mapping

    private static func pinnedItem(_ fact: PinnedFact, terms: [String]) -> MemoryConsoleItem {
        let tags = fact.tags
        let detail = MemoryPrivacyRedactor.redact(fact.content, maxCharacters: 2_000)
        let preview = MemoryPrivacyRedactor.redact(fact.content, maxCharacters: 260)
        let matched = matchedTerms(terms, in: [fact.content] + tags)
        return MemoryConsoleItem(
            id: "pinned:\(fact.id)",
            kind: .pinnedFact,
            storageId: fact.id,
            agentId: fact.agentId,
            title: "Pinned fact",
            preview: preview,
            detail: detail,
            relevanceExplanation: explanation(
                kind: "pinned fact",
                matchedTerms: matched,
                fallback: "Sorted by salience \(Int(fact.salience * 100))% and last use."
            ),
            metadata: MemoryConsoleMetadata(
                salience: fact.salience,
                sourceCount: fact.sourceCount,
                sourceEpisodeId: fact.sourceEpisodeId,
                lastUsed: fact.lastUsed.isEmpty ? nil : fact.lastUsed,
                useCount: fact.useCount,
                status: fact.status,
                createdAt: fact.createdAt.isEmpty ? nil : fact.createdAt,
                tags: tags
            ),
            canForget: true
        )
    }

    private static func episodeItem(_ episode: Episode, terms: [String]) -> MemoryConsoleItem {
        let topics = episode.topics
        let entities = episode.entities
        let searchable = [episode.summary, episode.decisions, episode.actionItems] + topics + entities
        let matched = matchedTerms(terms, in: searchable)
        let fullText = [episode.summary, episode.decisions, episode.actionItems]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let detail = MemoryPrivacyRedactor.redact(fullText, maxCharacters: 2_000)
        let preview = MemoryPrivacyRedactor.redact(episode.summary, maxCharacters: 300)
        return MemoryConsoleItem(
            id: "episode:\(episode.id)",
            kind: .episode,
            storageId: "\(episode.id)",
            agentId: episode.agentId,
            title: episodeTitle(date: episode.conversationAt, topics: topics),
            preview: preview,
            detail: detail,
            relevanceExplanation: explanation(
                kind: "episode",
                matchedTerms: matched,
                fallback: "Sorted by conversation date and salience."
            ),
            metadata: MemoryConsoleMetadata(
                salience: episode.salience,
                status: episode.status,
                createdAt: episode.createdAt.isEmpty ? nil : episode.createdAt,
                tokenCount: episode.tokenCount,
                conversationAt: episode.conversationAt.isEmpty ? nil : episode.conversationAt,
                conversationId: episode.conversationId,
                model: episode.model,
                topics: topics,
                entities: entities
            ),
            canForget: true
        )
    }

    private static func transcriptItem(_ turn: TranscriptTurn, terms: [String]) -> MemoryConsoleItem {
        let title = turn.conversationTitle ?? ""
        let matched = matchedTerms(terms, in: [turn.content, title])
        let detail = MemoryPrivacyRedactor.redact(turn.content, maxCharacters: 2_000)
        let preview = MemoryPrivacyRedactor.redact(turn.content, maxCharacters: 300)
        return MemoryConsoleItem(
            id: "transcript:\(turn.id)",
            kind: .transcriptTurn,
            storageId: "\(turn.id)",
            agentId: turn.agentId,
            title: title.isEmpty ? "\(turn.role.capitalized) turn" : title,
            preview: preview,
            detail: detail,
            relevanceExplanation: explanation(
                kind: "transcript turn",
                matchedTerms: matched,
                fallback: "Sorted by latest transcript activity."
            ),
            metadata: MemoryConsoleMetadata(
                createdAt: turn.createdAt.isEmpty ? nil : turn.createdAt,
                tokenCount: turn.tokenCount,
                conversationId: turn.conversationId,
                conversationTitle: title.isEmpty ? nil : title,
                chunkIndex: turn.chunkIndex,
                role: turn.role
            ),
            // See deviation #2: no per-row transcript delete exists yet.
            canForget: false
        )
    }

    // MARK: - Query Helpers (pure text processing, no DB access)

    private static func searchTerms(_ query: String) -> [String] {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let normalized = String(
            query.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }
        )
        let terms =
            normalized
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { $0.count >= 2 && !stopWords.contains($0) }
        return Array(NSOrderedSet(array: terms).compactMap { $0 as? String })
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from",
        "i", "in", "is", "it", "me", "my", "of", "on", "or", "the", "to",
        "we", "you", "your",
    ]

    private static func matchedTerms(_ terms: [String], in fields: [String]) -> [String] {
        guard !terms.isEmpty else { return [] }
        let searchable = fields.joined(separator: " ").lowercased()
        return terms.filter { searchable.contains($0) }
    }

    private static func explanation(
        kind: String,
        matchedTerms: [String],
        fallback: String
    ) -> String {
        if matchedTerms.isEmpty {
            return "Shown as a recent \(kind). \(fallback)"
        }
        let terms = matchedTerms.prefix(5).joined(separator: ", ")
        return "Matched \(kind) text for: \(terms)."
    }

    private static func sortConsoleItems(_ lhs: MemoryConsoleItem, _ rhs: MemoryConsoleItem) -> Bool {
        let lhsDate = lhs.metadata.conversationAt ?? lhs.metadata.createdAt ?? lhs.metadata.lastUsed ?? ""
        let rhsDate = rhs.metadata.conversationAt ?? rhs.metadata.createdAt ?? rhs.metadata.lastUsed ?? ""
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        let lhsSalience = lhs.metadata.salience ?? 0
        let rhsSalience = rhs.metadata.salience ?? 0
        if lhsSalience != rhsSalience {
            return lhsSalience > rhsSalience
        }
        return lhs.id < rhs.id
    }

    private static func episodeTitle(date: String, topics: [String]) -> String {
        let day = date.isEmpty ? "Episode" : String(date.prefix(10))
        guard let topic = topics.first, !topic.isEmpty else { return day }
        return "\(day) - \(topic)"
    }

    private static func parseItemId(_ itemId: String) throws -> (kind: MemoryConsoleItemKind, storageId: String) {
        let parts = itemId.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else {
            throw MemoryDatabaseError.failedToExecute("Invalid memory console item id: \(itemId)")
        }
        switch parts[0] {
        case "pinned": return (.pinnedFact, parts[1])
        case "episode": return (.episode, parts[1])
        case "transcript": return (.transcriptTurn, parts[1])
        default:
            throw MemoryDatabaseError.failedToExecute("Unknown memory console item kind: \(parts[0])")
        }
    }
}

#endif
