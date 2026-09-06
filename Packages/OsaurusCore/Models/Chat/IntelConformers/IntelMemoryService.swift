//
//  IntelMemoryService.swift
//  OsaurusCore (Intel fork)
//
//  Phase 2 distillation orchestrator. Mirrors the upstream
//  `Services/Memory/MemoryService.swift` write pipeline (buffer → debounce →
//  one LLM call per session → episode + pinned facts + identity delta) but
//  swaps the MLX/Foundation `CoreModelService.generate` for the Intel
//  `ChatEngine` (CloudChatEngine), so distillation runs on the very same remote
//  model the user already chats with (DeepSeek / Osaurus Router / any
//  OpenAI-compatible provider).
//
//  Intel deltas from upstream:
//    * `DistillationCoordinator` (single-flight + chat-idle yield) and
//      `MemoryContextAssembler.invalidateCache` are excluded on Intel — those
//      couplings exist to protect a resident MLX model from concurrent prefills.
//      Cloud inference has no such residency cost, so we run distills directly;
//      the actor itself serializes them.
//    * No `hasCoreModel()` / `canDistillCheaply()` MLX residency gates. The
//      core model is resolved from config with a graceful fallback to the
//      first discovered provider model so memory works out of the box.
//

#if OSAURUS_INTEL

import Foundation

public actor MemoryService {
    public static let shared = MemoryService()

    private let db = MemoryDatabase.shared

    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        ISO8601DateFormatter()
    }()

    private static func iso8601Now() -> String {
        iso8601Formatter.string(from: Date())
    }

    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var activeConversation: [String: String] = [:]
    private var conversationSessionDates: [String: String] = [:]

    /// Reset on every process launch — see `BufferTurnTelemetry`.
    private var telemetry = BufferTurnTelemetry()

    public func bufferTelemetry() -> BufferTurnTelemetry { telemetry }

    private init() {}

    // MARK: - Buffer Turn (no LLM)

    /// Buffer a conversation turn for later distillation. Hot path for every
    /// chat turn — no LLM call. The debounce timer is (re)armed; if no new turn
    /// arrives within `summaryDebounceSeconds`, the session is distilled.
    /// Switching to a different conversation flushes the previous one.
    public func bufferTurn(
        userMessage: String,
        assistantMessage: String?,
        agentId: String,
        conversationId: String,
        sessionDate: String? = nil
    ) async {
        telemetry.attempts += 1
        telemetry.lastAttemptAt = Date()

        guard !userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            telemetry.earlyReturnsEmptyMessage += 1
            return
        }

        let config = MemoryConfigurationStore.load()
        guard config.enabled else {
            telemetry.earlyReturnsDisabled += 1
            return
        }

        // Phase 3 gate (2026-09-05 owner decision — docs/MEMORY_PLAN.md §2):
        // distillation is opt-in per agent, default OFF. This is the entry
        // point of the whole pipeline — refusing here means a disabled
        // agent's turns never even reach `pending_signals`, so there is
        // nothing left for `flushSession`/`syncNow`/`recoverOrphanedSignals`
        // to distill later. Uses `AgentManager.shared.effectiveDistillationDisabled`
        // (Models/Chat/IntelConformers/IntelManagerConformers.swift) as the
        // single source of truth rather than re-deriving the check here.
        // This is deliberately independent of the `config.enabled` guard
        // just above: `enabled` gates the local, on-device recall/write path
        // (unchanged by this task); this gate governs only whether the
        // buffered content may later be sent to a cloud provider.
        let agentUUID = UUID(uuidString: agentId) ?? Agent.defaultId
        guard !AgentManager.shared.effectiveDistillationDisabled(for: agentUUID) else {
            telemetry.earlyReturnsDisabled += 1
            return
        }

        do {
            try db.insertPendingSignal(
                PendingSignal(
                    agentId: agentId,
                    conversationId: conversationId,
                    userMessage: userMessage,
                    assistantMessage: assistantMessage
                )
            )
            telemetry.insertSuccesses += 1
            telemetry.lastSuccessAt = Date()
            telemetry.lastError = nil
        } catch {
            telemetry.insertFailures += 1
            telemetry.lastError = error.localizedDescription
            MemoryLogger.service.error("Failed to buffer turn: \(error)")
            return
        }

        if let sessionDate, !sessionDate.isEmpty {
            conversationSessionDates[conversationId] = sessionDate
        }

        // Session change → flush the previous conversation.
        let previous = activeConversation[agentId]
        activeConversation[agentId] = conversationId
        if let prev = previous, prev != conversationId {
            debounceTasks[prev]?.cancel()
            debounceTasks[prev] = nil
            let prevDate = conversationSessionDates[prev]
            Task { await self.distillSession(agentId: agentId, conversationId: prev, sessionDate: prevDate) }
        }

        guard config.extractionMode == .sessionEnd else { return }

        // Re-arm debounce for this session.
        debounceTasks[conversationId]?.cancel()
        let debounceSeconds = config.summaryDebounceSeconds
        let capturedDate = conversationSessionDates[conversationId]
        debounceTasks[conversationId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(debounceSeconds))
            guard !Task.isCancelled else { return }
            await self?.distillSession(
                agentId: agentId,
                conversationId: conversationId,
                sessionDate: capturedDate
            )
        }
    }

    /// Force immediate distillation for a session. Called from the chat UI when
    /// the user navigates away.
    public func flushSession(agentId: String, conversationId: String) {
        debounceTasks[conversationId]?.cancel()
        debounceTasks[conversationId] = Task { [weak self] in
            await self?.distillSession(agentId: agentId, conversationId: conversationId)
        }
    }

    /// Distill every pending conversation. `force` is kept for call-site parity
    /// with upstream (the "Distill pending" / "Sync" buttons) — on Intel there's
    /// no residency gate to bypass, so both paths behave the same.
    public func syncNow(force: Bool = false) async {
        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return }

        let conversations: [(agentId: String, conversationId: String)]
        do { conversations = try db.pendingConversations() } catch {
            MemoryLogger.service.error("syncNow: failed to load pending conversations: \(error)")
            return
        }

        for conv in conversations {
            await performDistillSession(
                agentId: conv.agentId,
                conversationId: conv.conversationId
            )
        }
    }

    /// Startup hook: drain anything that didn't get distilled before the
    /// previous launch was killed.
    public func recoverOrphanedSignals() async {
        await syncNow()
    }

    // MARK: - Distillation (one LLM call per session)

    private func distillSession(
        agentId: String,
        conversationId: String,
        sessionDate: String? = nil
    ) async {
        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return }
        await performDistillSession(
            agentId: agentId,
            conversationId: conversationId,
            sessionDate: sessionDate
        )
    }

    /// The actual distillation body. Re-loads signals fresh so we don't miss
    /// turns buffered while the call was queued behind another distill.
    private func performDistillSession(
        agentId: String,
        conversationId: String,
        sessionDate: String? = nil
    ) async {
        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return }

        // Defense-in-depth for the same Phase 3 gate `bufferTurn` enforces
        // at the front door. `bufferTurn` refusing to queue a disabled
        // agent's turns closes the debounce/`distillSession` path, but this
        // is the one place every distillation attempt funnels through —
        // `distillSession`, `syncNow`, and therefore `flushSession` and
        // `recoverOrphanedSignals` (which call `syncNow`) all end up here.
        // Without this second check, a conversation buffered while
        // distillation was enabled, then left pending across an opt-out,
        // could still be distilled later by a `syncNow`/flush call that
        // never passes through `bufferTurn` at all. Signals stay pending
        // (not marked processed) so opting back in picks them up, same as
        // the "no model available" skip below.
        let agentUUID = UUID(uuidString: agentId) ?? Agent.defaultId
        guard !AgentManager.shared.effectiveDistillationDisabled(for: agentUUID) else {
            MemoryLogger.service.info(
                "distill: skipping \(conversationId) — distillation not opted in for agent \(agentId)"
            )
            logProcessing(
                agentId: agentId, taskType: "distill", model: "none",
                status: "skipped", details: "distillation_opted_out")
            return
        }

        guard let model = await resolveDistillModel() else {
            MemoryLogger.service.warning(
                "distill: no model available (configure a Core Model in Settings, or add a provider); signals stay pending"
            )
            logProcessing(
                agentId: agentId, taskType: "distill", model: "none",
                status: "skipped", details: "no_model")
            return
        }

        let startTime = Date()

        let signals: [PendingSignal]
        do { signals = try db.loadPendingSignals(conversationId: conversationId) } catch {
            MemoryLogger.service.error("distill: failed to load signals for \(conversationId): \(error)")
            return
        }
        guard !signals.isEmpty else { return }

        // Cheap pre-LLM gate: combined char count must clear novelty floor.
        let combinedChars = signals.reduce(0) {
            $0 + $1.userMessage.count + ($1.assistantMessage?.count ?? 0)
        }
        guard combinedChars >= MemoryConfiguration.distillNoveltyMinChars else {
            try? db.markSignalsProcessed(conversationId: conversationId)
            MemoryLogger.service.warning(
                "distill: skipping low-novelty session \(conversationId) (\(combinedChars) chars)"
            )
            logProcessing(
                agentId: agentId, taskType: "distill", model: model,
                status: "skipped", details: "low_novelty:\(combinedChars)chars")
            debounceTasks[conversationId] = nil
            return
        }

        let identity = (try? db.loadIdentity()) ?? Identity()
        let recentEpisodes =
            (try? db.loadEpisodes(agentId: agentId, days: 90, limit: MemoryConfiguration.distillContextEpisodeCount))
            ?? []

        let resolvedDate: String = {
            if let sessionDate, !sessionDate.isEmpty { return sessionDate }
            return Self.iso8601Now()
        }()

        let prompt = buildDistillPrompt(
            signals: signals,
            identity: identity,
            recentEpisodes: recentEpisodes,
            sessionDate: resolvedDate
        )

        do {
            let response = try await generate(prompt: prompt, model: model)
            let parsed = parseDistillResponse(response)
            guard let episode = parsed.episode else {
                MemoryLogger.service.warning("distill: no episode produced for \(conversationId)")
                logProcessing(
                    agentId: agentId, taskType: "distill", model: model, status: "empty",
                    durationMs: Int(Date().timeIntervalSince(startTime) * 1000))
                return
            }

            let summaryText = stripPreamble(episode.summary)
            guard !summaryText.isEmpty else {
                MemoryLogger.service.warning("distill: empty summary for \(conversationId)")
                logProcessing(
                    agentId: agentId, taskType: "distill", model: model, status: "empty",
                    durationMs: Int(Date().timeIntervalSince(startTime) * 1000),
                    details: "empty_summary")
                return
            }

            let tokenCount = max(1, summaryText.count / MemoryConfiguration.charsPerToken)
            let entitiesCSV = parsed.entities.joined(separator: ", ")
            let topicsCSV = episode.topics.joined(separator: ", ")
            let decisions = episode.decisions.joined(separator: "\n")
            let actionItems = episode.actionItems.joined(separator: "\n")
            let salience = max(0, min(1, episode.salience ?? 0.5))

            let ep = Episode(
                agentId: agentId,
                conversationId: conversationId,
                summary: summaryText,
                topicsCSV: topicsCSV,
                entitiesCSV: entitiesCSV,
                decisions: decisions,
                actionItems: actionItems,
                salience: salience,
                tokenCount: tokenCount,
                model: model,
                conversationAt: resolvedDate
            )

            let episodeId: Int
            do {
                episodeId = try db.insertEpisodeAndMarkProcessed(ep)
            } catch {
                MemoryLogger.service.error("distill: failed to insert episode for \(conversationId): \(error)")
                return
            }

            // Index the episode for semantic recall.
            var stored = ep
            stored.id = episodeId
            await MemorySearchService.shared.indexEpisode(stored)

            // Promote pinned candidates that are explicit, novel, and not already represented.
            let storedPinned = await persistPinnedCandidates(
                parsed.pinnedCandidates, agentId: agentId, episodeId: episodeId)

            // Apply identity delta: append new identity-grade facts to overrides.
            if !parsed.identityFacts.isEmpty {
                applyIdentityDelta(
                    facts: parsed.identityFacts, currentIdentity: identity, model: model)
            }

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            logProcessing(
                agentId: agentId, taskType: "distill", model: model, status: "success",
                inputTokens: prompt.count / MemoryConfiguration.charsPerToken,
                outputTokens: response.count / MemoryConfiguration.charsPerToken,
                durationMs: durationMs)
            MemoryLogger.service.info(
                "distill: \(conversationId) → episode #\(episodeId), \(storedPinned) pinned, \(parsed.identityFacts.count) identity facts (\(durationMs)ms)"
            )
        } catch {
            MemoryLogger.service.error("distill: failed for \(conversationId): \(error)")
            logProcessing(
                agentId: agentId, taskType: "distill", model: model, status: "error",
                details: error.localizedDescription)
        }

        debounceTasks[conversationId] = nil
    }

    // MARK: - Core Model Call (Intel: CloudChatEngine)

    /// Resolve the model used for distillation. Prefers an explicitly-configured
    /// Core Model, then the default chat model, and finally the first model any
    /// configured provider discovered — so memory consolidation works against
    /// whatever the user actually chats with, with zero extra setup.
    /// Resolves the model distillation will actually use. Also read by
    /// `MemoryDiagnostics` so the panel reports the SAME model this actor
    /// would pick — this was briefly duplicated there, and two copies of a
    /// resolution chain that must agree is how they drift apart.
    public func resolveDistillModel() async -> String? {
        let cfg = ChatConfigurationStore.load()
        if let core = cfg.coreModelIdentifier, !core.isEmpty { return core }
        if let def = cfg.defaultModel, !def.isEmpty { return def }
        // `RemoteProviderManager` is @MainActor-isolated — hop over to read it.
        return await MainActor.run {
            RemoteProviderManager.shared.providerStates.values
                .flatMap { $0.discoveredModels }
                .first
        }
    }

    /// One-shot completion via the Intel cloud engine, mirroring the
    /// `intelComplete` plugin path. Returns the assistant message text.
    private func generate(prompt: String, model: String) async throws -> String {
        let engine = ChatEngine(model: model)
        let request = ChatCompletionRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: distillSystemPrompt),
                ChatMessage(role: "user", content: prompt),
            ],
            temperature: 0.2,
            max_tokens: 1024
        )
        let response = try await engine.completeChat(request: request)
        return response.choices.first?.message?.content ?? ""
    }

    // MARK: - Pinned Candidates

    /// Persist pinned candidates that pass the dedup check (Jaccard against
    /// existing pinned facts) and index each for recall.
    private func persistPinnedCandidates(
        _ candidates: [DistillResult.PinnedCandidate],
        agentId: String,
        episodeId: Int
    ) async -> Int {
        guard !candidates.isEmpty else { return 0 }

        let existing = (try? db.loadPinnedFacts(agentId: agentId, limit: 200)) ?? []
        let existingTokens = existing.map { TextSimilarity.tokenize($0.content) }

        var stored = 0
        for candidate in candidates {
            let trimmed = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 5 else { continue }

            let candTokens = TextSimilarity.tokenize(trimmed)
            let isDuplicate = existing.indices.contains { i in
                TextSimilarity.jaccardTokenized(existingTokens[i], candTokens) > 0.6
            }
            if isDuplicate {
                MemoryLogger.service.debug("pinned: skip dup '\(trimmed.prefix(60))'")
                continue
            }

            let salience = max(0, min(1, candidate.salience ?? 0.6))
            let fact = PinnedFact(
                agentId: agentId,
                content: trimmed,
                salience: salience,
                sourceCount: 1,
                sourceEpisodeId: episodeId,
                tagsCSV: candidate.tags.isEmpty ? nil : candidate.tags.joined(separator: ", ")
            )
            do {
                try db.insertPinnedFact(fact)
                await MemorySearchService.shared.indexPinnedFact(fact)
                stored += 1
            } catch {
                MemoryLogger.service.error("pinned: insert failed: \(error)")
            }
        }
        return stored
    }

    // MARK: - Identity Delta

    private func applyIdentityDelta(
        facts: [String],
        currentIdentity: Identity,
        model: String
    ) {
        let existing = Set(currentIdentity.overrides.map { $0.lowercased() })
        var updated = currentIdentity
        var added = 0
        for raw in facts {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !existing.contains(trimmed.lowercased()) else { continue }
            updated.overrides.append(trimmed)
            added += 1
        }
        guard added > 0 else { return }
        updated.model = model
        updated.generatedAt = Self.iso8601Now()
        do { try db.saveIdentity(updated) } catch {
            MemoryLogger.service.error("identity: save failed: \(error)")
        }
        MemoryLogger.service.info("identity: appended \(added) new fact(s)")
    }

    // MARK: - Prompt Building (lifted from upstream MemoryService)

    private let distillSystemPrompt = """
        You distill a chat session into a structured digest. \
        Respond ONLY with a valid JSON object (no preamble, no code fences, no commentary). \
        The JSON must have these top-level keys: \
        "episode" (object with "summary" string, "topics" string array, "decisions" string array, \
        "action_items" string array, "salience" number 0-1), \
        "entities" (string array of person/project/place/tool names mentioned), \
        "pinned_candidates" (array of {"content": string, "salience": number 0-1, "tags": string array} for \
        facts worth remembering long-term: explicit user identity facts, strong preferences, decisions the \
        user clearly committed to. Be conservative — most sessions yield 0-2 candidates.), \
        "identity_facts" (string array of facts that should appear in the user's identity profile, e.g. \
        "User's name is X" or "User works at Y". Empty when nothing identity-relevant came up.). \
        Salience scoring: 0.9+ = critical identity/decision, 0.6-0.8 = clear preference, \
        0.3-0.5 = casual mention, <0.3 = transient chitchat. \
        Do NOT invent facts. Use only what the conversation actually contains.
        """

    private func buildDistillPrompt(
        signals: [PendingSignal],
        identity: Identity,
        recentEpisodes: [Episode],
        sessionDate: String
    ) -> String {
        var prompt = "Conversation date: \(sessionDate)\n\n"

        if !identity.content.isEmpty {
            prompt += "What we already know about the user:\n\(identity.content)\n\n"
        }

        if !recentEpisodes.isEmpty {
            prompt += "Recent past sessions (for cross-session continuity):\n"
            for ep in recentEpisodes {
                prompt += "- [\(ep.conversationAt.prefix(10))] \(ep.summary.prefix(160))\n"
            }
            prompt += "\n"
        }

        prompt += "Conversation turns:\n"
        for signal in signals {
            prompt += "\nUser: \(signal.userMessage)"
            if let asst = signal.assistantMessage {
                prompt += "\nAssistant: \(asst)"
            }
        }

        prompt += "\n\nDistill this session into the JSON digest."
        return prompt
    }

    // MARK: - Response Parsing (lifted from upstream MemoryService)

    struct DistillResult {
        struct EpisodeData {
            var summary: String
            var topics: [String]
            var decisions: [String]
            var actionItems: [String]
            var salience: Double?
        }
        struct PinnedCandidate {
            var content: String
            var salience: Double?
            var tags: [String]
        }

        var episode: EpisodeData?
        var entities: [String] = []
        var pinnedCandidates: [PinnedCandidate] = []
        var identityFacts: [String] = []
    }

    nonisolated func extractJSON(from response: String) -> Data? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = trimmed.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        {
            return data
        }

        let fencePattern = #"```(?:json)?\s*\n?([\s\S]*?)```"#
        if let regex = try? NSRegularExpression(pattern: fencePattern),
            let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
            let contentRange = Range(match.range(at: 1), in: trimmed)
        {
            let jsonStr = String(trimmed[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = jsonStr.data(using: .utf8),
                (try? JSONSerialization.jsonObject(with: data)) != nil
            {
                return data
            }
        }

        if let openIdx = trimmed.firstIndex(of: "{"),
            let closeIdx = trimmed.lastIndex(of: "}"), closeIdx > openIdx
        {
            let jsonStr = String(trimmed[openIdx ... closeIdx])
            if let data = jsonStr.data(using: .utf8),
                (try? JSONSerialization.jsonObject(with: data)) != nil
            {
                return data
            }
        }

        return nil
    }

    nonisolated func parseDistillResponse(_ response: String) -> DistillResult {
        guard let data = extractJSON(from: response),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            MemoryLogger.service.error(
                "distill parse: no JSON in response: \(response.prefix(200))")
            return DistillResult()
        }

        var result = DistillResult()

        if let epDict = dict["episode"] as? [String: Any] {
            let summary = (epDict["summary"] as? String) ?? ""
            let topics = (epDict["topics"] as? [String]) ?? []
            let decisions = (epDict["decisions"] as? [String]) ?? []
            let actions = (epDict["action_items"] as? [String]) ?? []
            let salience: Double? =
                (epDict["salience"] as? Double)
                ?? (epDict["salience"] as? String).flatMap(Double.init)
            if !summary.isEmpty {
                result.episode = DistillResult.EpisodeData(
                    summary: summary,
                    topics: topics,
                    decisions: decisions,
                    actionItems: actions,
                    salience: salience
                )
            }
        }

        if let entities = dict["entities"] as? [String] {
            result.entities = entities.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        if let pinned = dict["pinned_candidates"] as? [[String: Any]] {
            result.pinnedCandidates = pinned.compactMap { obj in
                guard let content = obj["content"] as? String, !content.isEmpty else { return nil }
                let salience: Double? =
                    (obj["salience"] as? Double)
                    ?? (obj["salience"] as? String).flatMap(Double.init)
                let tags: [String]
                if let arr = obj["tags"] as? [String] {
                    tags = arr
                } else if let single = obj["tags"] as? String {
                    tags = [single]
                } else {
                    tags = []
                }
                return DistillResult.PinnedCandidate(content: content, salience: salience, tags: tags)
            }
        }

        if let facts = dict["identity_facts"] as? [String] {
            result.identityFacts = facts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        return result
    }

    nonisolated func stripPreamble(_ response: String) -> String {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)

        let preamblePatterns = [
            #"^(?:certainly|sure|of course|here(?:'s| is| are))[!.,:]?\s*"#,
            #"^here is (?:a |the )?(?:profile|description|summary)[^:]*:\s*"#,
        ]
        for pattern in preamblePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(text.startIndex..., in: text)
                if let match = regex.firstMatch(in: text, range: range) {
                    let matchEnd = Range(match.range, in: text)!.upperBound
                    text = String(text[matchEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        return text
    }

    // MARK: - Processing Log Helper

    private func logProcessing(
        agentId: String,
        taskType: String,
        model: String,
        status: String,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        durationMs: Int = 0,
        details: String? = nil
    ) {
        do {
            try db.insertProcessingLog(
                agentId: agentId,
                taskType: taskType,
                model: model,
                status: status,
                details: details,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                durationMs: durationMs
            )
        } catch {
            MemoryLogger.service.warning("Failed to write processing log: \(error)")
        }
    }
}

#endif
