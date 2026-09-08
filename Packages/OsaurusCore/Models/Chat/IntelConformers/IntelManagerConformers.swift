//
//  IntelManagerConformers.swift
//  OsaurusCore
//
//  M10.5 Phase A: Intel-lite manager conformers — concretized.
//  All types use concrete types, no protocol existentials.
//  Protocol conformances dropped — ChatView accesses these directly by type name.
//

#if OSAURUS_INTEL

import Foundation

// MARK: - AgentManager

final class AgentManager: ObservableObject, @unchecked Sendable {
    static let shared = AgentManager()

    private var defaultModel = "deepseek-v4-pro"

    struct AgentInfo: Identifiable, Sendable {
        let id: UUID
        let name: String
        let isBuiltIn: Bool = true
        let autoSpeak: Bool? = false
        var ttsVoice: String? { nil }
    }

    @Published var activeAgentId: UUID = Agent.defaultId
    // Real agent list: the built-in Default first, then any custom
    // agents persisted as JSON under `OsaurusPaths.agents()`. M11 Phase
    // 11.A.4 click-through (Renée 2026-06-02) found that creating an
    // agent didn't surface a card because `add` was a no-op and this
    // array was a single throwaway. Now backed by real on-disk
    // persistence (same pattern as SlashCommandStore / SkillStore).
    @Published var agents: [Agent] = [Agent.default]

    private static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let isoDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        reload()
    }

    /// Re-read custom agents from disk and rebuild `agents` (Default
    /// always pinned first). Triggers the `@Published` so the grid +
    /// pickers refresh.
    func reload() {
        let dir = OsaurusPaths.agents()
        OsaurusPaths.ensureExistsSilent(dir)
        var custom: [Agent] = []
        if let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) {
            for url in files where url.pathExtension == "json" {
                if let data = try? Data(contentsOf: url),
                    let agent = try? Self.isoDecoder.decode(Agent.self, from: data)
                {
                    custom.append(agent)
                }
            }
        }
        custom.sort { $0.createdAt < $1.createdAt }
        agents = [Agent.default] + custom
    }

    private func persist(_ agent: Agent) {
        guard agent.id != Agent.defaultId else { return }  // Default is built-in, never written
        let dir = OsaurusPaths.agents()
        OsaurusPaths.ensureExistsSilent(dir)
        let url = dir.appendingPathComponent("\(agent.id.uuidString).json")
        if let data = try? Self.iso.encode(agent) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    func agent(for id: UUID) -> Agent? {
        agents.first { $0.id == id }
    }

    func agent(byAddress address: String) -> Agent? {
        agents.first { $0.agentAddress == address }
    }

    func resolveAgentId(_ identifier: String) -> UUID? {
        if let uuid = UUID(uuidString: identifier) { return uuid }
        return agents.first { $0.name == identifier }?.id
    }

    func agentsList() -> [Agent] { agents }

    func refresh() { reload() }

    func setActiveAgent(_ id: UUID) { activeAgentId = id }

    func add(_ agent: Agent) {
        persist(agent)
        reload()
    }

    func update(_ agent: Agent) {
        if agent.id == Agent.defaultId {
            // The Default agent is built-in and not persisted; reflect
            // the edit in-memory so the editor's bindings stay live for
            // the session.
            if let idx = agents.firstIndex(where: { $0.id == Agent.defaultId }) {
                agents[idx] = agent
            }
            return
        }
        persist(agent)
        reload()
    }

    func delete(id: UUID) async -> AgentDeleteResult {
        // The Default agent is mandatory and cannot be deleted (matches
        // upstream). Return `deleted: false` so the UI keeps the card.
        guard id != Agent.defaultId else {
            return AgentDeleteResult(deleted: false)
        }
        let url = OsaurusPaths.agents().appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        if activeAgentId == id { activeAgentId = Agent.defaultId }
        reload()
        return AgentDeleteResult(deleted: true)
    }

    // Per-agent custom avatar. Avatars are amputated on Intel (no
    // sandbox-side image processing pipeline), so these are no-ops; the
    // view's `customAvatarURL` reads stay nil. Surface kept so the
    // AgentDetailView avatar section (un-body-swapped in M11 Phase
    // 11.A.4) type-checks.
    func setCustomAvatar(_ data: Data, ext: String, for agentId: UUID) {}
    func clearCustomAvatar(for agentId: UUID) {}

    // MARK: - Cryptographic agent addresses (M11 Phase 11.A.5 — Identity)
    //
    // These are REAL implementations mirrored byte-for-byte from the
    // upstream `AgentManager` (Managers/AgentManager.swift, excluded on
    // Intel only because it pulled MLX deps elsewhere in the class).
    // Every crypto dependency — `MasterKey`, `AgentKey.deriveAddress`,
    // `OsaurusIdentityContext`, `APIKeyManager` — is available on Intel
    // (only `OsaurusIdentity.swift` itself was excluded, now un-excluded
    // in 11.A.5). So per-agent address derivation genuinely works on
    // Intel: this is the M4 ↔ Rosy identity-sync backbone, functional,
    // not stubbed.

    /// Derive + persist a fresh cryptographic address for an agent from
    /// the master key. No-op for built-in agents, agents that already
    /// have an address, or when no master key exists.
    func assignAddress(to agent: Agent) throws {
        guard !agent.isBuiltIn, agent.agentAddress == nil else { return }
        guard MasterKey.exists() else { return }

        let context = OsaurusIdentityContext.biometric()
        var masterKeyData = try MasterKey.getPrivateKey(context: context)
        defer { masterKeyData.zeroOut() }

        let nextIndex = nextUnusedAgentIndex()
        let address = try AgentKey.deriveAddress(masterKey: masterKeyData, index: nextIndex)

        var updated = agent
        updated.agentIndex = nextIndex
        updated.agentAddress = address
        update(updated)
    }

    /// Rotate an agent's address: fresh unused index, re-derive, persist,
    /// and revoke every active access key bound to the previous address.
    func rotateAddress(of agent: Agent) throws {
        guard !agent.isBuiltIn else { return }
        guard MasterKey.exists() else { throw OsaurusIdentityError.keychainReadFailed }

        let context = OsaurusIdentityContext.biometric()
        var masterKeyData = try MasterKey.getPrivateKey(context: context)
        defer { masterKeyData.zeroOut() }

        let nextIndex = nextUnusedAgentIndex()
        let newAddress = try AgentKey.deriveAddress(masterKey: masterKeyData, index: nextIndex)
        let previousAddress = agent.agentAddress

        var updated = agent
        updated.agentIndex = nextIndex
        updated.agentAddress = newAddress
        update(updated)

        if let previousAddress {
            revokeActiveKeys(forAudience: previousAddress)
        }
    }

    /// Clear an agent's cryptographic identity + revoke keys bound to it.
    /// The agent (prompt/settings) survives; it just loses signing
    /// authority until `assignAddress(to:)` runs again.
    func revokeAddress(of agent: Agent) {
        guard !agent.isBuiltIn else { return }
        guard agent.agentAddress != nil || agent.agentIndex != nil else { return }

        let previousAddress = agent.agentAddress

        var updated = agent
        updated.agentIndex = nil
        updated.agentAddress = nil
        update(updated)

        if let previousAddress {
            revokeActiveKeys(forAudience: previousAddress)
        }
    }

    private func nextUnusedAgentIndex() -> UInt32 {
        let used = Set(agents.compactMap(\.agentIndex))
        var index: UInt32 = 0
        while used.contains(index) { index += 1 }
        return index
    }

    private func revokeActiveKeys(forAudience audience: OsaurusID) {
        for key in APIKeyManager.shared.listKeys(forAudience: audience) where !key.revoked {
            APIKeyManager.shared.revoke(id: key.id)
        }
    }

    func updateDefaultModel(for agentId: UUID, model: String?) {
        if agentId == activeAgentId, let model { defaultModel = model }
    }

    // M12 Gap 1 follow-up (Renée 2026-06-03 click-through): the agent pill
    // switched `agentId` correctly, but selecting an agent didn't change the
    // conversation because every `effective*` method below was a hollow stub
    // (system prompt `""`, temperature `nil`, model ignored the agent). They
    // now mirror the real `AgentManager` (Managers/AgentManager.swift,
    // excluded on Intel): custom agents use their own fields; the Default
    // agent — and any unknown id — defers to the global `ChatConfiguration`
    // the Settings → Configuration tab persists via `ChatConfigurationStore`.
    private func resolvedAgent(_ agentId: UUID) -> Agent? {
        guard let agent = agents.first(where: { $0.id == agentId }),
            agent.id != Agent.defaultId
        else { return nil }
        return agent
    }

    func effectiveModel(for agentId: UUID) -> String? {
        if let agent = resolvedAgent(agentId), let model = agent.defaultModel, !model.isEmpty {
            return model
        }
        return ChatConfigurationStore.load().defaultModel ?? defaultModel
    }

    func effectiveTemperature(for agentId: UUID) -> Double? {
        if let agent = resolvedAgent(agentId) {
            return agent.temperature.map { Double($0) }
        }
        return ChatConfigurationStore.load().temperature.map { Double($0) }
    }

    func effectiveMaxTokens(for agentId: UUID) -> Int? {
        if let agent = resolvedAgent(agentId) {
            return agent.maxTokens
        }
        return ChatConfigurationStore.load().maxTokens
    }

    func effectiveSystemPrompt(for agentId: UUID) -> String {
        if let agent = resolvedAgent(agentId) {
            return agent.systemPrompt
        }
        return ChatConfigurationStore.load().systemPrompt
    }
    func effectiveToolsDisabled(for agentId: UUID) -> Bool { false }
    func effectiveDBEnabled(for agentId: UUID) -> Bool { false }
    /// Intel memory is governed by the global Memory tab toggle
    /// (`MemoryConfiguration.enabled`); per-agent overrides are a Phase-2 thing.
    /// This used to hard-return `true` (a leftover from when memory was
    /// amputated), which silently gated OUT the ChatView transcript-write path —
    /// so nothing was ever stored to recall.
    func effectiveMemoryDisabled(for agentId: UUID) -> Bool {
        !MemoryConfigurationStore.load().enabled
    }

    /// Phase 3 (2026-09-05 owner decision, docs/MEMORY_PLAN.md §2/§2b — a
    /// deliberate divergence from upstream, not to be "corrected" toward it):
    /// cloud **distillation** — the `MemoryService.performDistillSession`
    /// call that sends buffered turns to a remote provider for summarising —
    /// is opt-in per agent, default OFF.
    ///
    /// Deliberately a SEPARATE accessor from `effectiveMemoryDisabled` above,
    /// which keeps its current meaning and default and continues to gate
    /// only the local, on-device recall/write path in `ChatView`
    /// (transcript insert + indexing) — that path must not be disabled by
    /// this change. This method governs distillation only.
    ///
    /// The whole-memory kill switch still wins: if memory itself is off for
    /// this agent (or globally, via `effectiveMemoryDisabled`), distillation
    /// can't run either, since it reads/writes through the same store. On
    /// top of that, distillation additionally requires an explicit per-agent
    /// opt-in recorded in `MemoryConfiguration.distillationEnabledAgents`
    /// (Models/Memory/MemoryConfiguration.swift) — absence of an entry means
    /// "not opted in", which is the default for every agent, including the
    /// Default agent and every agent that existed before this setting did.
    ///
    /// This is the single source of truth `MemoryService` consults —
    /// `bufferTurn` and `performDistillSession` both call this rather than
    /// re-deriving the same logic, so there is exactly one place that can
    /// get this wrong.
    func effectiveDistillationDisabled(for agentId: UUID) -> Bool {
        if effectiveMemoryDisabled(for: agentId) { return true }
        return !MemoryConfigurationStore.load().isDistillationEnabled(for: agentId)
    }

    // M12 follow-up (Renée 2026-06-03): real per-agent capability management,
    // backing the un-body-swapped AgentCapabilityManagerView. Mirrors the real
    // AgentManager (Managers/AgentManager.swift): custom agents persist to their
    // own `manualToolNames`/`manualSkillNames`/`toolSelectionMode`; the Default
    // (built-in) agent routes through the global ChatConfiguration. The chat
    // send path (composeChatContext) honors these so Manual mode actually
    // restricts the agent to its enabled tools.
    func effectiveToolSelectionMode(for agentId: UUID) -> ToolSelectionMode {
        guard let agent = agent(for: agentId) else { return .auto }
        if agent.id == Agent.defaultId {
            return (ChatConfigurationStore.load().defaultToolSelectionMode as? ToolSelectionMode) ?? .auto
        }
        return agent.toolSelectionMode ?? .auto
    }

    func effectiveEnabledToolNames(for agentId: UUID) -> [String]? {
        guard let agent = agent(for: agentId) else { return nil }
        if agent.id == Agent.defaultId {
            return ChatConfigurationStore.load().defaultManualToolNames
        }
        return agent.manualToolNames
    }

    func effectiveEnabledSkillNames(for agentId: UUID) -> [String]? {
        guard let agent = agent(for: agentId) else { return nil }
        if agent.id == Agent.defaultId {
            return ChatConfigurationStore.load().defaultManualSkillNames
        }
        return agent.manualSkillNames
    }

    /// Seed an agent's enabled set from the live registries the first time the
    /// capability picker opens (idempotent — only writes when nil).
    func seedEnabledCapabilitiesIfNeeded(
        for agentId: UUID,
        defaultToolNames: [String],
        defaultSkillNames: [String]
    ) {
        guard let agent = agent(for: agentId) else { return }
        if agent.id == Agent.defaultId {
            let config = ChatConfigurationStore.load()
            var changed = false
            if config.defaultManualToolNames == nil {
                config.defaultManualToolNames = defaultToolNames
                changed = true
            }
            if config.defaultManualSkillNames == nil {
                config.defaultManualSkillNames = defaultSkillNames
                changed = true
            }
            if changed {
                ChatConfigurationStore.save(config)
                NotificationCenter.default.post(name: .agentUpdated, object: Agent.defaultId)
            }
            return
        }
        var updated = agent
        var changed = false
        if updated.manualToolNames == nil {
            updated.manualToolNames = defaultToolNames
            changed = true
        }
        if updated.manualSkillNames == nil {
            updated.manualSkillNames = defaultSkillNames
            changed = true
        }
        if changed { update(updated) }
    }

    func updateEnabledToolNames(_ names: [String], for agentId: UUID) {
        if agentId == Agent.defaultId {
            let config = ChatConfigurationStore.load()
            config.defaultManualToolNames = names
            ChatConfigurationStore.save(config)
            NotificationCenter.default.post(name: .agentUpdated, object: agentId)
            return
        }
        guard var agent = agent(for: agentId), !agent.isBuiltIn else { return }
        agent.manualToolNames = names
        update(agent)
    }

    func updateEnabledSkillNames(_ names: [String], for agentId: UUID) {
        if agentId == Agent.defaultId {
            let config = ChatConfigurationStore.load()
            config.defaultManualSkillNames = names
            ChatConfigurationStore.save(config)
            NotificationCenter.default.post(name: .agentUpdated, object: agentId)
            return
        }
        guard var agent = agent(for: agentId), !agent.isBuiltIn else { return }
        agent.manualSkillNames = names
        update(agent)
    }

    func updateToolSelectionMode(_ mode: ToolSelectionMode, for agentId: UUID) {
        if agentId == Agent.defaultId {
            let config = ChatConfigurationStore.load()
            config.defaultToolSelectionMode = mode
            ChatConfigurationStore.save(config)
            NotificationCenter.default.post(name: .agentUpdated, object: agentId)
            return
        }
        guard var agent = agent(for: agentId), !agent.isBuiltIn else { return }
        agent.toolSelectionMode = mode
        update(agent)
    }

    /// Writer for the Phase 3 distillation opt-in (see
    /// `effectiveDistillationDisabled` above). No call site yet — this is
    /// the API a future Memory-tab toggle binds to (the per-agent card in
    /// `Views/Memory/MemoryView.swift` / `MemoryDiagnosticsViews.swift`,
    /// currently owned by a parallel lane) so it can say "distillation is
    /// off for this agent" and let the user turn it on. Uniform for the
    /// Default agent and every custom agent, since the opt-in lives in
    /// `MemoryConfiguration.distillationEnabledAgents` (keyed by agent UUID)
    /// rather than on the `Agent` record itself — unlike
    /// `updateToolSelectionMode` above, there's no Default-vs-custom branch
    /// needed here.
    func updateDistillationEnabled(_ enabled: Bool, for agentId: UUID) {
        var config = MemoryConfigurationStore.load()
        config.setDistillationEnabled(enabled, for: agentId)
        MemoryConfigurationStore.save(config)
        NotificationCenter.default.post(name: .agentUpdated, object: agentId)
    }

    // AgentDetailView's sandbox section reads/writes
    // `AutonomousExecConfig` (the real type from Models/Agent/Agent.swift,
    // NOT excluded on Intel) — not the lightweight protocol
    // `AgentAutoExecInfo`. The protocol overloads below are kept for the
    // chat-side callers that use them; the view-facing overloads use
    // `AutonomousExecConfig`. Sandbox is amputated on Intel so both are
    // effectively inert (return `.default`, write no-ops).
    /// AgentDetailView's sandbox section reads/writes the real
    /// `AutonomousExecConfig` (Models/Agent/Agent.swift, NOT excluded),
    /// so `effectiveAutonomousExec` returns that type here. Sandbox is
    /// amputated on Intel → always `.default` (disabled), write no-ops.
    func effectiveAutonomousExec(for agentId: UUID) -> AutonomousExecConfig? { .default }
    func updateAutonomousExec(_ config: AutonomousExecConfig, for agentId: UUID) async throws {}
    func ttsVoice(for agentId: UUID) -> Any? { nil }
    func themeId(for agentId: UUID) -> UUID? { nil }
}

// MARK: - ModelPickerItemCache

// `ConfigurationView`'s CoreModel picker (un-body-swapped in M11
// Phase 11.A.3.1, gated visually to AppleSiliconOnlyOverlay)
// observes `$items`, which requires `ObservableObject` + `@Published`
// surface. Mirrored here. The cache stays Intel-functional for
// `FloatingInputCard`'s model selector — that's where the provider
// models surface, and the Configuration picker is gated.
final class ModelPickerItemCache: ObservableObject, @unchecked Sendable {
    static let shared = ModelPickerItemCache()

    var isLoaded: Bool = false
    @Published private(set) var items: [ModelPickerItem] = []

    func buildModelPickerItems() async -> [ModelPickerItem] {
        // Purely provider-driven: every model comes from a user-configured,
        // enabled provider — its live `discoveredModels` (cached `/models`
        // probe) unioned with any `manualModelIds` the user typed. There are
        // NO hardcoded models. DeepSeek is just another provider now (it ships
        // as a preset), which is what makes this build distributable to other
        // Intel users who may run only a local llama.cpp server (Bonsai),
        // Ollama, or some other OpenAI-compatible endpoint. `CloudChatEngine`
        // routes each request to whichever provider owns the selected model.
        let built: [ModelPickerItem] = await MainActor.run {
            var out: [ModelPickerItem] = []
            var seen = Set<String>()
            if ClaudeCodeConfiguration.isAvailable() {
                let sourceId = UUID(uuidString: "C1A0DE00-C0DE-4000-8000-000000000001")!
                for model in ClaudeCodeModel.allCases {
                    out.append(
                        ModelPickerItem(
                            id: model.pickerId,
                            displayName: model.displayName,
                            source: .remote(providerName: "Claude Code", providerId: sourceId),
                            description: "Uses your signed-in Claude Code CLI subscription"
                        )
                    )
                    seen.insert(model.pickerId)
                }
            }
            let manager = RemoteProviderManager.shared
            let providers = manager.configuration.providers.filter { $0.enabled }
            for provider in providers {
                // Only the managed Osaurus Router provider gets the venice-priced
                // catalog metadata. A *direct* provider (e.g. DeepSeek) can share
                // model ids with the router's proxied catalog, so keying the
                // lookup on id alone would wrongly stamp the direct provider's
                // rows with the router's pricing/vision. Gate on the provider type.
                let isRouter = provider.providerType == .osaurusRouter
                let discovered = manager.providerStates[provider.id]?.discoveredModels ?? []
                var ids: [String] = []
                for id in discovered + provider.manualModelIds where !ids.contains(id) { ids.append(id) }
                for modelId in ids where !seen.contains(modelId) {
                    seen.insert(modelId)
                    // Osaurus Router models carry rich catalog metadata (provider,
                    // pricing, context, vision) — render the enriched row. Other
                    // providers fall back to the bare id + provider name.
                    if isRouter, let metadata = manager.routerModelMetadata[modelId] {
                        out.append(
                            ModelPickerItem.fromOsaurusRouterModel(
                                id: modelId,
                                providerName: provider.name,
                                providerId: provider.id,
                                metadata: metadata
                            )
                        )
                    } else {
                        out.append(
                            ModelPickerItem(
                                id: modelId,
                                displayName: modelId,
                                source: .remote(providerName: provider.name, providerId: provider.id),
                                isVLM: false,
                                description: provider.name,
                                contextLength: manager.customProviderContextLength(
                                    providerId: provider.id, modelId: modelId
                                )
                            )
                        )
                    }
                }
            }
            return out
        }

        items = built
        isLoaded = true
        return built
    }

    func prewarm() { Task { await buildModelPickerItems() } }
    func prewarmModelCache() async { _ = await buildModelPickerItems() }
    func invalidateCache() { isLoaded = false }
}

// MARK: - ChatSessionData

// M13 Schedules restore: made `public` so the un-excluded ExecutionContext's
// `public init(reattaching: ChatSessionData)` compiles — the real upstream
// model is public too. Members stay internal (same-module access only).
public struct ChatSessionData: Identifiable, Codable, @unchecked Sendable {
    public let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    let agentId: UUID
    var source: SessionSource
    var sourcePluginId: String?
    var externalSessionKey: String?
    var dispatchTaskId: UUID?
    var archived: Bool
    /// User-set pin flag. Pinned sessions float to the top of the sidebar
    /// list (within their current filter) so frequently-used chats stay
    /// reachable without searching.
    var pinned: Bool = false
    var selectedModel: String?
    var turns: [ChatTurnData]
    var capabilities: Set<SessionCapability> = []
    /// Project this chat belongs to, if any. Grouping only — orthogonal to
    /// `agentId`. Optional so old on-disk sessions (no key present) decode
    /// to `nil` via synthesized Codable's `decodeIfPresent`.
    var projectId: UUID? = nil

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        selectedModel: String? = nil,
        turns: [ChatTurnData] = [],
        agentId: UUID? = nil,
        source: SessionSource = .chat,
        sourcePluginId: String? = nil,
        externalSessionKey: String? = nil,
        dispatchTaskId: UUID? = nil,
        archived: Bool = false,
        pinned: Bool = false,
        capabilities: Set<SessionCapability> = [],
        projectId: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.agentId = agentId ?? UUID()
        self.archived = archived
        self.selectedModel = selectedModel
        self.turns = turns
        self.source = source
        self.sourcePluginId = sourcePluginId
        self.externalSessionKey = externalSessionKey
        self.dispatchTaskId = dispatchTaskId
        self.pinned = pinned
        self.capabilities = capabilities
        self.projectId = projectId
    }

    // MARK: - Tolerant decoding
    //
    // ⚠️ Synthesized `Decodable` does NOT fall back to a property's default
    // value: a missing key throws `keyNotFound`, and `loadFromDisk()` skips any
    // session it cannot decode. So adding a NON-OPTIONAL field here — even one
    // with `= false` — makes every previously-written session silently vanish
    // from the sidebar. That is exactly what shipping `pinned` did.
    //
    // This hand-written initializer makes every additive field tolerant, so old
    // files keep loading. When adding a field, give it a case here too; do not
    // rely on the property default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "New Chat"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        agentId = try c.decodeIfPresent(UUID.self, forKey: .agentId) ?? UUID()
        source = try c.decodeIfPresent(SessionSource.self, forKey: .source) ?? .chat
        sourcePluginId = try c.decodeIfPresent(String.self, forKey: .sourcePluginId)
        externalSessionKey = try c.decodeIfPresent(String.self, forKey: .externalSessionKey)
        dispatchTaskId = try c.decodeIfPresent(UUID.self, forKey: .dispatchTaskId)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        selectedModel = try c.decodeIfPresent(String.self, forKey: .selectedModel)
        turns = try c.decodeIfPresent([ChatTurnData].self, forKey: .turns) ?? []
        capabilities =
            try c.decodeIfPresent(Set<SessionCapability>.self, forKey: .capabilities) ?? []
        projectId = try c.decodeIfPresent(UUID.self, forKey: .projectId)
    }

    /// Derive a chat title from the first user message — mirrors the upstream
    /// `ChatSessionData.generateTitle` (excluded on Intel). The old stub always
    /// returned "Chat", which is why every Intel conversation was named "Chat".
    static func generateTitle(from turnData: [ChatTurnData]) -> String {
        guard let firstUserTurn = turnData.first(where: { $0.role == .user }) else {
            return "New Chat"
        }
        let content = firstUserTurn.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty { return "New Chat" }
        let firstLine = content.components(separatedBy: .newlines).first ?? content
        if firstLine.count <= 50 { return firstLine }
        return String(firstLine.prefix(47)) + "..."
    }
}

// MARK: - ChatSessionsManager

final class ChatSessionsManager: ObservableObject, @unchecked Sendable {
    static let shared = ChatSessionsManager()
    /// `@Published` so `ChatWindowState.observeSessionsManager()` can subscribe
    /// via `$sessions` and refresh the sidebar when a turn lands during an
    /// active stream — without this, the sidebar only updates on explicit
    /// user actions (e.g., clicking "New Chat"). Renamed-from-private to
    /// `internal` so observers can read it.
    @Published var sessions: [UUID: ChatSessionData] = [:]

    // M13 follow-up (Renée 2026-06-04): persist chat sessions across launches.
    // Upstream persists via the excluded ChatHistoryDatabase/ChatSessionStore
    // (SQLite); Intel had only this in-memory dict, so every relaunch lost all
    // conversations. We now mirror the legacy per-session JSON layout under
    // `OsaurusPaths.sessions()` (~/.osaurus-intel/sessions/<uuid>.json) —
    // small payloads, one file per chat, loaded on init and rewritten on each
    // mutation. (`ChatSessionData`/`ChatTurnData` are Codable on Intel now.)
    private init() {
        loadFromDisk()
    }

    func save(_ data: ChatSessionData) {
        sessions[data.id] = data
        persist(data)
    }
    func delete(id: UUID) {
        sessions.removeValue(forKey: id)
        removeFromDisk(id: id)
    }
    func rename(id: UUID, title: String) {
        if var s = sessions[id] {
            s.title = title
            sessions[id] = s
            // Metadata-only mutation: the in-memory upsert above already
            // keeps the sidebar correct, so the disk write (encode + write
            // of the WHOLE session, turns included) can move off the
            // calling thread — a full synchronous persist on every rename
            // was a measured main-thread stall on large conversations.
            persistAsync(s)
        }
    }
    func setArchived(id: UUID, archived: Bool) {
        if var s = sessions[id] {
            s.archived = archived
            sessions[id] = s
            // See `rename` — metadata-only, safe to persist off-thread.
            persistAsync(s)
        }
    }
    /// Toggle a session's pin flag. Like `setArchived`, this does not touch
    /// `updatedAt`: pinning is a display-ordering concern handled by the
    /// sidebar and must not bubble the row up the recency list.
    func setPinned(id: UUID, pinned: Bool) {
        guard var s = sessions[id], s.pinned != pinned else { return }
        s.pinned = pinned
        sessions[id] = s
        persistAsync(s)
    }
    /// Move a session into a project (or out, with nil). Metadata-only,
    /// same off-thread persist as `rename`/`setArchived`.
    func setProject(id: UUID, projectId: UUID?) {
        guard var s = sessions[id], s.projectId != projectId else { return }
        s.projectId = projectId
        sessions[id] = s
        persistAsync(s)
        NotificationCenter.default.post(
            name: .chatSessionProjectDidChange,
            object: nil,
            userInfo: ["sessionId": id, "projectId": projectId as Any]
        )
    }
    /// Detach every session from a deleted project, then drop the project
    /// record itself. Call this instead of `ProjectManager.delete` directly.
    func deleteProject(id: UUID) {
        for (sid, var s) in sessions where s.projectId == id {
            s.projectId = nil
            sessions[sid] = s
            persistAsync(s)
        }
        // `ProjectManager` is `@MainActor`; this manager isn't statically
        // isolated, so hop explicitly rather than assume the caller's thread.
        Task { @MainActor in
            ProjectManager.shared.delete(id: id)
        }
        NotificationCenter.default.post(
            name: .chatSessionProjectDidChange,
            object: nil,
            userInfo: ["clearedProjectId": id]
        )
    }
    /// Sessions belonging to a given project, newest first.
    func sessions(forProject projectId: UUID) -> [ChatSessionData] {
        Array(sessions.values)
            .filter { $0.projectId == projectId }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    func refresh() { loadFromDisk() }

    // MARK: - Disk persistence

    private func loadFromDisk() {
        let dir = OsaurusPaths.sessions()
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
        else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [UUID: ChatSessionData] = [:]
        for file in files where file.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: file),
                let session = try? decoder.decode(ChatSessionData.self, from: data)
            else { continue }
            loaded[session.id] = session
        }
        sessions = loaded
        print("[Osaurus Intel] Loaded \(loaded.count) chat session(s) from disk")
    }

    private func persist(_ data: ChatSessionData) {
        let dir = OsaurusPaths.sessions()
        OsaurusPaths.ensureExistsSilent(dir)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(data) else { return }
        try? encoded.write(to: OsaurusPaths.sessionFile(for: data.id), options: .atomic)
    }

    /// Same encode-and-write as `persist`, off the calling thread. For
    /// metadata-only mutations (`rename`, `setArchived`) where the in-memory
    /// `sessions` dict is already updated synchronously, so nothing depends
    /// on the disk write completing before the caller returns.
    private static let persistQueue = DispatchQueue(
        label: "ai.osaurus.chatSessionsManager.persist", qos: .utility)
    private func persistAsync(_ data: ChatSessionData) {
        Self.persistQueue.async { [self] in
            persist(data)
        }
    }

    private func removeFromDisk(id: UUID) {
        try? FileManager.default.removeItem(at: OsaurusPaths.sessionFile(for: id))
    }

    func createNew(selectedModel: String? = nil, agentId: UUID? = nil) -> UUID {
        let id = UUID()
        sessions[id] = ChatSessionData(id: id, agentId: agentId ?? UUID())
        return id
    }

    /// Sessions filtered by agent, newest first. Mirrors the real
    /// `ChatSessionsManager` (Managers/ChatSessionsManager.swift, excluded
    /// on Intel): the Default agent (or `nil`) is the see-all lens and
    /// returns every session; a custom agent returns only its own chats.
    /// M12 Gap 1 follow-up (Renée 2026-06-03): the prior stub ignored
    /// `agentId`, so the sidebar showed every agent's history even when a
    /// custom agent like "Uga Buga" was active in the toolbar pill.
    func sessions(for agentId: UUID?) -> [ChatSessionData] {
        let all = Array(sessions.values).sorted { $0.updatedAt > $1.updatedAt }
        if agentId == nil || agentId == Agent.defaultId {
            return all
        }
        return all.filter { $0.agentId == agentId }
    }
    func session(for id: UUID) -> ChatSessionData? { sessions[id] }
}

// MARK: - Hotkey (Intel stub)
//
// Upstream `Hotkey` is defined inside the excluded
// `Models/Chat/ChatConfiguration.swift`. Mirror the public surface
// byte-for-byte so `ConfigurationView`'s chat-hotkey picker row
// (un-body-swapped in M11 Phase 11.A.3.1) type-checks. The Intel
// build doesn't currently register a global hotkey through
// `HotKeyManager` (excluded), but the field is still wired through
// the config so persistence survives the round-trip.
public struct Hotkey: Codable, Equatable, Sendable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32
    public let displayString: String

    public init(keyCode: UInt32, carbonModifiers: UInt32, displayString: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.displayString = displayString
    }
}

// MARK: - PreflightSearchMode (Intel stub)
//
// Upstream `PreflightSearchMode` lives in the excluded
// `Services/Context/PreflightCapabilitySearch.swift`. The view binds
// the `.balanced` case and presents the four-way picker; persistence
// goes through the conformer's `preflightSearchMode` field. Search
// is amputated on Intel so the field's value never drives real
// behavior — it just keeps the picker's binding alive.
public enum PreflightSearchMode: String, Codable, CaseIterable, Sendable {
    case off, narrow, balanced, wide

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .narrow: return "Narrow"
        case .balanced: return "Balanced"
        case .wide: return "Wide"
        }
    }

    /// Help text shown beneath the segmented picker in
    /// `ConfigurationView`. Mirrors upstream verbatim — even though
    /// preflight search is amputated on Intel, the picker still
    /// renders + binds, and the explainer keeps the UI honest about
    /// what each mode would do.
    public var helpText: String {
        switch self {
        case .off: return "Disable pre-flight search. Only explicit tool calls are used."
        case .narrow: return "Minimal tool injection. Up to 2 tools loaded."
        case .balanced: return "Default. Up to 5 relevant tools loaded."
        case .wide: return "Aggressive search. Up to 15 tools loaded, may increase prompt size."
        }
    }
}

// MARK: - ChatConfiguration
//
// Extended in M11 Phase 11.A.3.0 to mirror more of the upstream
// public surface so `ConfigurationView` (un-body-swapped in 11.A.3.1)
// can bind to its rows. Fields whose backing subsystem is amputated
// on Intel (CoreModel picker, workMax* runtime, preflightSearchMode)
// still persist via the shared singleton so the view's two-way
// bindings work — they just don't drive real behavior. Persistence
// is in-memory per process; `ChatConfigurationStore.save` is a no-op
// (config doesn't survive Intel app restarts yet).

final class ChatConfiguration: @unchecked Sendable {
    // Load persisted settings from ~/.osaurus/config/chat.json the first time
    // the singleton is touched, so Settings survive app restart (M11 follow-up
    // that previously left the Intel config in-memory only).
    static let shared: ChatConfiguration = {
        let c = ChatConfiguration()
        c.loadFromDiskIfPresent()
        return c
    }()

    // Tool / generation behaviour
    var disableTools: Bool = false
    var maxToolAttempts: Int? = nil
    // Kept as `Double?` to match the consumer at `ChatView.swift:2148`
    // (which forwards it to a `Double?` API). Upstream uses `Float?`
    // here; the Intel divergence is intentional and bridged at the
    // call-site Bool / numeric conversion if needed.
    var topPOverride: Double? = nil

    // Chat-side defaults
    var hotkey: Hotkey? = nil
    var systemPrompt: String = ""
    var temperature: Float? = nil
    var maxTokens: Int? = nil
    var contextLength: Int? = 128000
    var defaultModel: String? = nil
    var generativeGreetingsEnabled: Bool = false
    var greetingPersona: String = ""
    var enableClipboardMonitoring: Bool = true
    // Upstream 5bb946f7: background Core-Model title generation after
    // the first exchange. On Intel this is served by CloudChatEngine
    // (see `ChatView.generateLLMTitle`), which predates this port and
    // already ran unconditionally; this flag makes it an opt-out,
    // default-on to preserve existing behavior on upgrade.
    var autoGenerateChatTitles: Bool = true
    var defaultToolSelectionMode: Any? = nil
    var defaultManualToolNames: [String]? = nil
    var defaultManualSkillNames: [String]? = nil

    // Core (local) model picker — amputated on Intel.
    var coreModelProvider: String? = nil
    var coreModelName: String? = nil
    var coreModelIdentifier: String? {
        guard let provider = coreModelProvider, let name = coreModelName else { return nil }
        return "\(provider)/\(name)"
    }

    // Work-agent runtime — used by upstream's local agent loop.
    var workTemperature: Float? = nil
    var workMaxTokens: Int? = nil
    var workTopPOverride: Float? = nil
    var workMaxIterations: Int? = nil

    // Preflight search mode — picker binds even though search is
    // amputated. Stored for round-trip integrity.
    var preflightSearchMode: PreflightSearchMode? = nil

    init() {}

    /// Designated init mirroring upstream's struct init. Upstream is a
    /// value type; on Intel `ChatConfiguration` is a class with a
    /// shared singleton, so this convenience init creates a NEW
    /// instance carrying the parameters. `ChatConfigurationStore.save(_:)`
    /// copies the fields from the passed instance into the shared
    /// singleton, keeping the call sites that do
    /// `let cfg = ChatConfiguration(...); save(cfg)` working
    /// byte-for-byte without view-side changes.
    convenience init(
        hotkey: Hotkey?,
        systemPrompt: String,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        contextLength: Int? = nil,
        // Accepts `Float?` to match the view's `parsedTopP: Float?`
        // call site; stored internally as `Double?` (the type
        // `ChatView.swift:2148` consumes). Bridged in the body.
        topPOverride: Float? = nil,
        maxToolAttempts: Int? = nil,
        defaultModel: String? = nil,
        coreModelProvider: String? = nil,
        coreModelName: String? = nil,
        workTemperature: Float? = nil,
        workMaxTokens: Int? = nil,
        workTopPOverride: Float? = nil,
        workMaxIterations: Int? = nil,
        preflightSearchMode: PreflightSearchMode? = nil,
        disableTools: Bool = false,
        defaultToolSelectionMode: Any? = nil,
        defaultManualToolNames: [String]? = nil,
        defaultManualSkillNames: [String]? = nil,
        enableClipboardMonitoring: Bool = true,
        autoGenerateChatTitles: Bool = true,
        generativeGreetingsEnabled: Bool = false,
        greetingPersona: String = ""
    ) {
        self.init()
        self.hotkey = hotkey
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.contextLength = contextLength
        self.topPOverride = topPOverride.map(Double.init)
        self.maxToolAttempts = maxToolAttempts
        self.defaultModel = defaultModel
        self.coreModelProvider = coreModelProvider
        self.coreModelName = coreModelName
        self.workTemperature = workTemperature
        self.workMaxTokens = workMaxTokens
        self.workTopPOverride = workTopPOverride
        self.workMaxIterations = workMaxIterations
        self.preflightSearchMode = preflightSearchMode
        self.disableTools = disableTools
        self.defaultToolSelectionMode = defaultToolSelectionMode
        self.defaultManualToolNames = defaultManualToolNames
        self.defaultManualSkillNames = defaultManualSkillNames
        self.enableClipboardMonitoring = enableClipboardMonitoring
        self.autoGenerateChatTitles = autoGenerateChatTitles
        self.generativeGreetingsEnabled = generativeGreetingsEnabled
        self.greetingPersona = greetingPersona
    }

    /// Copy every editable field from another instance into self.
    /// Used by `ChatConfigurationStore.save(_:)` to fold a freshly-
    /// constructed `ChatConfiguration` into the shared singleton.
    func adopt(_ other: ChatConfiguration) {
        self.hotkey = other.hotkey
        self.systemPrompt = other.systemPrompt
        self.temperature = other.temperature
        self.maxTokens = other.maxTokens
        self.contextLength = other.contextLength
        self.topPOverride = other.topPOverride
        self.maxToolAttempts = other.maxToolAttempts
        self.defaultModel = other.defaultModel
        self.coreModelProvider = other.coreModelProvider
        self.coreModelName = other.coreModelName
        self.workTemperature = other.workTemperature
        self.workMaxTokens = other.workMaxTokens
        self.workTopPOverride = other.workTopPOverride
        self.workMaxIterations = other.workMaxIterations
        self.preflightSearchMode = other.preflightSearchMode
        self.disableTools = other.disableTools
        self.defaultToolSelectionMode = other.defaultToolSelectionMode
        self.defaultManualToolNames = other.defaultManualToolNames
        self.defaultManualSkillNames = other.defaultManualSkillNames
        self.enableClipboardMonitoring = other.enableClipboardMonitoring
        self.autoGenerateChatTitles = other.autoGenerateChatTitles
        self.generativeGreetingsEnabled = other.generativeGreetingsEnabled
        self.greetingPersona = other.greetingPersona
    }

    static func load() -> ChatConfiguration { shared }

    /// Mirrors `ChatConfiguration.default` from upstream. Upstream
    /// is a value-type static factory; the Intel class equivalent
    /// returns the shared singleton so call-site identity checks
    /// (`config == .default`) hold for the duration of a process.
    static var `default`: ChatConfiguration { shared }

    // MARK: - Disk persistence (Intel restore)
    //
    // Codable snapshot of the JSON-friendly fields. Keys match upstream's
    // `config/chat.json` so a file written by the Apple-Silicon app (or a
    // migrated one) round-trips. `defaultToolSelectionMode` (`Any?`) is the
    // only field intentionally excluded — it is not Codable and is re-derived
    // from `defaultManualToolNames` at the call site.
    private struct DiskSnapshot: Codable {
        var disableTools: Bool? = nil
        var maxToolAttempts: Int? = nil
        var topPOverride: Double? = nil
        var hotkey: Hotkey? = nil
        var systemPrompt: String? = nil
        var temperature: Float? = nil
        var maxTokens: Int? = nil
        var contextLength: Int? = nil
        var defaultModel: String? = nil
        var generativeGreetingsEnabled: Bool? = nil
        var greetingPersona: String? = nil
        var enableClipboardMonitoring: Bool? = nil
        var autoGenerateChatTitles: Bool? = nil
        var defaultManualToolNames: [String]? = nil
        var defaultManualSkillNames: [String]? = nil
        var coreModelProvider: String? = nil
        var coreModelName: String? = nil
        var workTemperature: Float? = nil
        var workMaxTokens: Int? = nil
        var workTopPOverride: Float? = nil
        var workMaxIterations: Int? = nil
        var preflightSearchMode: PreflightSearchMode? = nil
    }

    /// Apply any persisted values from `config/chat.json`. Only non-nil keys
    /// overwrite defaults, so a partial file (or an upstream file with extra
    /// keys we ignore) is safe.
    func loadFromDiskIfPresent() {
        guard let data = try? Data(contentsOf: OsaurusPaths.chatConfigFile()),
            let s = try? JSONDecoder().decode(DiskSnapshot.self, from: data)
        else {
            print("[ChatConfiguration] loadFromDisk: no file at \(OsaurusPaths.chatConfigFile().path)")
            return
        }
        print("[ChatConfiguration] loadFromDisk: coreModel=\(s.coreModelProvider ?? "nil")/\(s.coreModelName ?? "nil") maxToolAttempts=\(String(describing: s.maxToolAttempts))")
        if let v = s.disableTools { disableTools = v }
        if let v = s.maxToolAttempts { maxToolAttempts = v }
        if let v = s.topPOverride { topPOverride = v }
        if let v = s.hotkey { hotkey = v }
        if let v = s.systemPrompt { systemPrompt = v }
        if let v = s.temperature { temperature = v }
        if let v = s.maxTokens { maxTokens = v }
        if let v = s.contextLength { contextLength = v }
        if let v = s.defaultModel { defaultModel = v }
        if let v = s.generativeGreetingsEnabled { generativeGreetingsEnabled = v }
        if let v = s.greetingPersona { greetingPersona = v }
        if let v = s.enableClipboardMonitoring { enableClipboardMonitoring = v }
        if let v = s.autoGenerateChatTitles { autoGenerateChatTitles = v }
        if let v = s.defaultManualToolNames { defaultManualToolNames = v }
        if let v = s.defaultManualSkillNames { defaultManualSkillNames = v }
        if let v = s.coreModelProvider { coreModelProvider = v }
        if let v = s.coreModelName { coreModelName = v }
        if let v = s.workTemperature { workTemperature = v }
        if let v = s.workMaxTokens { workMaxTokens = v }
        if let v = s.workTopPOverride { workTopPOverride = v }
        if let v = s.workMaxIterations { workMaxIterations = v }
        if let v = s.preflightSearchMode { preflightSearchMode = v }
    }

    /// Write the current settings to `config/chat.json` atomically.
    func persistToDisk() {
        var s = DiskSnapshot()
        s.disableTools = disableTools
        s.maxToolAttempts = maxToolAttempts
        s.topPOverride = topPOverride
        s.hotkey = hotkey
        s.systemPrompt = systemPrompt
        s.temperature = temperature
        s.maxTokens = maxTokens
        s.contextLength = contextLength
        s.defaultModel = defaultModel
        s.generativeGreetingsEnabled = generativeGreetingsEnabled
        s.greetingPersona = greetingPersona
        s.enableClipboardMonitoring = enableClipboardMonitoring
        s.autoGenerateChatTitles = autoGenerateChatTitles
        s.defaultManualToolNames = defaultManualToolNames
        s.defaultManualSkillNames = defaultManualSkillNames
        s.coreModelProvider = coreModelProvider
        s.coreModelName = coreModelName
        s.workTemperature = workTemperature
        s.workMaxTokens = workMaxTokens
        s.workTopPOverride = workTopPOverride
        s.workMaxIterations = workMaxIterations
        s.preflightSearchMode = preflightSearchMode

        let url = OsaurusPaths.chatConfigFile()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(s) {
            try? data.write(to: url, options: [.atomic])
            print("[ChatConfiguration] persistToDisk: wrote coreModel=\(s.coreModelProvider ?? "nil")/\(s.coreModelName ?? "nil") → \(url.path)")
        } else {
            print("[ChatConfiguration] persistToDisk: ENCODE FAILED")
        }
    }
}

// MARK: - ManagementBadgeStore (Intel stub — M11)
//
// Upstream coalesces every sidebar-badge data source (ModelManager,
// RemoteProviderManager, AgentManager, PluginRepositoryService,
// SandboxPluginLibrary, SpeechModelManager) into a single throttled
// snapshot so the Management view's body doesn't re-render on every
// model-download progress chunk. On Intel none of those sources have
// badge content to publish (local-model installs amputated, sandbox
// amputated, speech amputated), so the snapshot stays empty and the
// store is a no-op ObservableObject.

struct ManagementBadgeSnapshot: Sendable {
    var counts: [ManagementTab: Int] = [:]
    var highlights: Set<ManagementTab> = []
}

@MainActor
final class ManagementBadgeStore: ObservableObject {
    static let shared = ManagementBadgeStore()
    @Published var snapshot = ManagementBadgeSnapshot()
}

// MARK: - IncomingPairCoordinator (Intel stub — M11)
//
// Upstream surfaces `osaurus://...?pair=...` deeplinks here. The
// pairing services + Bonjour discovery are excluded on Intel, so no
// invite ever lands; ManagementView's `.sheet(...)` binding reads
// `pendingInvite` and stays nil.

@MainActor
final class IncomingPairCoordinator: ObservableObject {
    static let shared = IncomingPairCoordinator()
    @Published var pendingInvite: AgentInvite? = nil
}

// MARK: - AgentInvite (Intel stub — M11)
//
// Upstream `AgentInvite` lives in the excluded
// `Models/Agent/AgentInvite.swift`. We only need an empty Identifiable
// struct here so the `.sheet(item:)` binding type-checks; the sheet
// itself is body-swapped to `AppleSiliconOnlyTab` upstream.

struct AgentInvite: Identifiable, Sendable, Equatable {
    let id = UUID()
}

#endif
