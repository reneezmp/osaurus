//
//  ChatView.swift
//  osaurus
//
//  Created by Terence on 10/26/25.
//

import AppKit
import Combine
import LocalAuthentication
@preconcurrency import MLXLMCommon
import SwiftUI

/// Holds the derived, streaming-mutated `[ContentBlock]` list for the chat
/// thread. Kept as a separate `ObservableObject` so that per-token visibleBlocks
/// updates don't fire `ChatSession.objectWillChange` — that would force
/// `ChatView`'s entire body (and every sibling, notably `FloatingInputCard`
/// with its expensive glass/gradient chrome) to re-evaluate several times per
/// second during streaming. Only the message-thread subtree observes this
/// store, so streaming re-renders stay localized to the table.
@MainActor
final class VisibleBlocksStore: ObservableObject {
    @Published var blocks: [ContentBlock] = []
    @Published var groupHeaderMap: [UUID: UUID] = [:]
}

/// Snapshot of a pending user message that was authored while the agent
/// was still streaming. Captured at enqueue time so attachments and the
/// active one-off skill travel with the right turn. The view shows a chip
/// for this; `ChatSession` consumes it either via auto-flush on natural
/// completion or via `sendNowInterrupting()` when the user explicitly
/// interrupts.
struct QueuedSend: Equatable {
    var text: String
    var attachments: [Attachment]
    var oneOffSkillId: UUID?
}

/// Lifecycle of the generative greeting for a single chat session. Drives
/// the empty-state UI: `.idle` and `.failed` render the static greeting +
/// the agent's configured quick actions, `.loading` renders an animated
/// skeleton, and `.ready` renders the freshly produced AI payload with a
/// shimmer fade-in. A separate `.failed` (vs `.idle`) lets the UI know the
/// loader actually completed without a result so it doesn't re-trigger
/// from a stale state.
enum GenerativeGreetingState: Equatable {
    case idle
    case loading
    case ready(GenerativeGreeting)
    case failed
}

/// Lifts the empty-state's "kick off a generative greeting" wiring out of
/// `ChatView.body` so the closure stays small enough for the type checker.
/// Re-runs `loadGenerativeGreetingIfNeeded` whenever the selected model or
/// active agent changes; the session-level cache key absorbs idempotent
/// re-fires (re-appearing the empty state, scrolling, etc.).
private struct GenerativeGreetingTrigger: ViewModifier {
    @ObservedObject var session: ChatSession
    @ObservedObject var windowState: ChatWindowState

    func body(content: Content) -> some View {
        content
            .onAppear { trigger() }
            .onChange(of: session.selectedModel) { _ in trigger() }
            .onChange(of: windowState.agentId) { _ in trigger() }
    }

    private func trigger() {
        // AI greetings are an opt-in master switch on Settings → Chat;
        // per-agent values can still flip the resolved state on/off
        // independently. We read the global flag synchronously here so
        // the trigger stays cheap.
        let globallyEnabled =
            AppConfiguration.shared.chatConfig.generativeGreetingsEnabled
        session.loadGenerativeGreetingIfNeeded(
            agent: windowState.activeAgent,
            globallyEnabled: globallyEnabled
        )
    }
}

@MainActor
final class ChatSession: ObservableObject {
    @Published var turns: [ChatTurn] = []
    @Published var isStreaming: Bool = false {
        didSet {
            guard isStreaming != oldValue else { return }
            if isStreaming {
                ChatPerfTrace.shared.begin("stream-\(Int(Date().timeIntervalSince1970))")
            } else {
                ChatPerfTrace.shared.end()
            }
        }
    }
    @Published var lastStreamError: String?

    /// Single-slot FIFO queue for in-chat prompt overlays (secrets,
    /// clarify, …). Both prompt types share the same on-screen real
    /// estate (bottom-pinned card above the input bar), so they MUST be
    /// mutually exclusive — the queue ensures arrival order is honored
    /// without two cards stacking. See `PromptQueue.swift`.
    @Published var promptQueue: PromptQueue = PromptQueue()

    /// Set by the agent-loop `clarify` intercept when the chat is paused
    /// for a clarify question. Cleared by `send(...)` before the next
    /// user turn so the loop can resume cleanly. Observed by
    /// `BackgroundTaskManager.observeChatTask` to flip the task status to
    /// `.awaitingClarification`, emit the type-3 CLARIFICATION event with
    /// the parsed payload to the source plugin, and suppress the spurious
    /// COMPLETED that would otherwise fire when `isStreaming` goes false
    /// on the intercept.
    @Published var awaitingClarify: ClarifyPayload?

    /// Tracks expand/collapse state for tool calls, thinking blocks, etc.
    /// Lives on the session so state survives NSTableView cell reuse.
    let expandedBlocksStore = ExpandedBlocksStore()
    @Published var input: String = ""
    @Published var pendingAttachments: [Attachment] = []
    @Published var selectedModel: String? = nil
    @Published var pickerItems: [ModelPickerItem] = []
    @Published var activeModelOptions: [String: ModelOptionValue] = [:]
    @Published var hasAnyModel: Bool = false
    @Published var isDiscoveringModels: Bool = true
    /// When true, voice input auto-restarts after AI responds (continuous conversation mode)
    @Published var isContinuousVoiceMode: Bool = false
    /// Active state of the voice input overlay
    @Published var voiceInputState: VoiceInputState = .idle
    /// Whether the voice input overlay is currently visible
    @Published var showVoiceOverlay: Bool = false
    /// The agent this session belongs to
    @Published var agentId: UUID?
    /// The project this chat is grouped under, if any. Mirrors
    /// `ChatSessionData.projectId`; feeds project instructions into
    /// `composeChatContext` at send time.
    @Published var projectId: UUID?

    /// Skill ID to inject as one-off context for the next outgoing message.
    /// Set when the user selects a skill from the slash command popup; cleared after send.
    @Published var pendingOneOffSkillId: UUID?

    /// Single-slot queued send. Non-nil when the user has pressed Send while
    /// `isStreaming` is true. The chip in `FloatingInputCard` shows a preview
    /// and a × to cancel. Auto-flushed by `completeRunCleanup` when the run
    /// ends naturally; explicitly flushed by `sendNowInterrupting()` which
    /// stops the current run and dispatches the queued payload as a new
    /// user turn.
    @Published var queuedSend: QueuedSend?

    // MARK: - Persistence Properties
    @Published var sessionId: UUID?
    @Published var title: String = "New Chat"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// Origin of this session — populated by `ExecutionContext` for headless
    /// (plugin / HTTP / scheduler / watcher) runs, defaults to `.chat` for
    /// user-driven UI sessions.
    var source: SessionSource = .chat
    var sourcePluginId: String?
    var externalSessionKey: String?
    var dispatchTaskId: UUID?
    /// Mirrors `ChatSessionData.archived`. Required here so `toSessionData()`
    /// round-trips the flag instead of stamping `false` on every save.
    var archived: Bool = false
    /// Mirrors `ChatSessionData.pinned`, for the same round-trip reason as `archived`.
    var pinned: Bool = false

    /// Tracks if session has unsaved content changes
    private var isDirty: Bool = false

    // MARK: - Memoization Cache
    private let blockMemoizer = BlockMemoizer()
    private var cachedContext: ComposedContext?

    private var thinkingEnabledForCurrentModel: Bool {
        guard let selectedModel else {
            return activeModelOptions["disableThinking"]?.boolValue == false
        }
        return ModelProfileRegistry.thinkingEnabled(
            for: selectedModel,
            values: activeModelOptions
        ) ?? false
    }
    /// Estimated memory-section token cost for the next send. Populated by
    /// `refreshMemoryTokens` and surfaced through `estimatedContextBreakdown`
    /// so the Context Budget popover shows a "Memory" line even before the
    /// first send (when `cachedContext` is still nil).
    private var cachedMemoryTokens: Int = 0
    private let budgetTracker = ContextBudgetTracker()

    /// Per-session always-loaded + capabilities_load tool kit lives in the
    /// process-wide `SessionToolStateStore` so chat sessions and the
    /// HTTP/plugin path share one cache. Keyed by `sessionId.uuidString`.
    private var sessionStateKey: (UUID) -> String { { $0.uuidString } }

    // MARK: - Agent Loop State (Chat-as-Agent)

    /// The agent's current todo for this chat, mirrored from
    /// `AgentTodoStore` via `.agentTodoChanged`. Read-only from the UI's
    /// perspective — only the `todo` tool writes to it.
    @Published var currentTodo: AgentTodo?

    /// Last `complete(summary)` payload from the agent. Populated when
    /// the engine intercepts `complete` and breaks the loop. The chat
    /// view renders it as a "Completed" banner inline.
    @Published var lastCompletionSummary: String?

    /// Notification observer for AgentTodoStore updates. Removed in deinit.
    nonisolated(unsafe) private var agentTodoObserver: NSObjectProtocol?

    /// Bridges `PromptQueue.objectWillChange` (a nested `ObservableObject`)
    /// up to `ChatSession.objectWillChange`. SwiftUI's `@ObservedObject`
    /// only re-renders on the outer object's emissions, so without this
    /// forward the prompt overlay wouldn't appear/disappear when the
    /// inner queue mutates `current`.
    nonisolated(unsafe) private var promptQueueCancellable: AnyCancellable?

    /// Callback when session needs to be saved (called after streaming completes)
    var onSessionChanged: (() -> Void)?

    /// When true, every assistant turn that finishes streaming in this session
    /// is auto-spoken via TTS. Per-session only — resets for new chats.
    @Published var autoSpeakAssistant: Bool = false
    /// Whether we've already shown the first-tap auto-speak prompt in this session.
    @Published var hasAskedAutoSpeak: Bool = false
    /// Set to the assistant turn id when a streaming run finalizes successfully.
    /// `ChatView` observes this to drive auto-speak. Not set on stop/error.
    @Published var lastCompletedAssistantTurnId: UUID?

    /// Lifecycle of the generative greeting for the current empty state.
    /// Drives skeleton vs static vs AI-produced rendering — see
    /// `GenerativeGreetingState`. Populated by
    /// `loadGenerativeGreetingIfNeeded(...)`, reset on `reset()`.
    @Published var generativeGreetingState: GenerativeGreetingState = .idle

    /// In-flight generation, retained so we can cancel it on reset / send /
    /// teardown. The state machine on `generativeGreetingState` is what the
    /// UI observes; the task is kept here purely for cooperative cancel.
    private var generativeGreetingTask: Task<Void, Never>?

    /// Cache key for the most recently kicked-off generation. Encodes
    /// session id, agent id, and model so the call only re-runs when one
    /// of those actually changed (re-appearing the empty state for the
    /// same context is a no-op).
    private var generativeGreetingKey: String?

    /// Weak back-reference to the owning window state (set by ChatWindowState).
    weak var windowState: ChatWindowState?

    private var currentTask: Task<Void, Never>?
    private var activeRunId: UUID?
    private var activeRunContext: RunContext?
    /// Set to true at the start of `stop()` so `completeRunCleanup` knows the
    /// run was cancelled by the user (or by `sendNowInterrupting`) and must
    /// not auto-flush a queued send. Reset to false at the top of `send(...)`.
    private var stopRequested: Bool = false
    /// Guards one-shot LLM title generation (Intel). Set true once we attempt
    /// a model-generated title for a session so we don't regenerate each turn.
    private var llmTitleAttempted: Bool = false
    var chatEngineFactory: @MainActor () -> ChatEngineProtocol = {
        ChatEngine(source: .chatUI)
    }
    // nonisolated(unsafe) allows deinit to access these for cleanup
    nonisolated(unsafe) private var remoteModelsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var modelSelectionCancellable: AnyCancellable?
    nonisolated(unsafe) private var agentAutoSpeakCancellable: AnyCancellable?
    /// Flag to prevent auto-persist during initial load or programmatic resets
    private var isLoadingModel: Bool = false

    nonisolated(unsafe) private var localModelsObserver: NSObjectProtocol?
    /// Keeps this live session's `projectId` in sync when the chat is moved
    /// between projects (or its project is deleted) from another window —
    /// otherwise the next send would keep injecting a stale project's
    /// instructions. Removed in deinit.
    nonisolated(unsafe) private var projectMembershipObserver: NSObjectProtocol?

    init() {
        let cache = ModelPickerItemCache.shared
        if cache.isLoaded {
            pickerItems = cache.items
            hasAnyModel = !cache.items.isEmpty
            isDiscoveringModels = false
        } else {
            pickerItems = []
            hasAnyModel = false
        }

        // Forward nested PromptQueue changes up so SwiftUI re-renders
        // when the queue mounts or advances. See the property comment
        // for why the explicit bridge is needed.
        promptQueueCancellable = promptQueue.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        remoteModelsObserver = NotificationCenter.default.addObserver(
            forName: .remoteProviderModelsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshPickerItems() }
        }

        localModelsObserver = NotificationCenter.default.addObserver(
            forName: .localModelsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshPickerItems() }
        }

        // Mirror AgentTodoStore -> currentTodo so the inline UI block
        // updates whenever the agent calls `todo`. Filter by this window's
        // current sessionId so cross-window writes don't leak across.
        agentTodoObserver = NotificationCenter.default.addObserver(
            forName: .agentTodoChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let sid = note.userInfo?["sessionId"] as? String else { return }
            Task { @MainActor in
                guard let self, sid == self.expectedTodoSessionId else { return }
                self.currentTodo = await AgentTodoStore.shared.todo(for: sid)
            }
        }

        projectMembershipObserver = NotificationCenter.default.addObserver(
            forName: .chatSessionProjectDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if let sid = note.userInfo?["sessionId"] as? UUID, sid == self.sessionId {
                self.projectId = note.userInfo?["projectId"] as? UUID
            } else if let cleared = note.userInfo?["clearedProjectId"] as? UUID,
                cleared == self.projectId
            {
                self.projectId = nil
            }
        }

        // when the active agent opts into auto-speak, force the per-session
        // toggle on and suppress the first-tap prompt. agents that haven't
        // opted in leave the per-chat toggle alone.
        agentAutoSpeakCancellable =
            $agentId
            .sink { [weak self] newAgentId in
                guard let self else { return }
                let id = newAgentId ?? Agent.defaultId
                let agent = AgentManager.shared.agent(for: id)
                if agent?.autoSpeak == true {
                    self.autoSpeakAssistant = true
                    self.hasAskedAutoSpeak = true
                }
            }

        // Auto-persist model selection and unload unused models on switch
        modelSelectionCancellable =
            $selectedModel
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newModel in
                guard let self = self, !self.isLoadingModel, let model = newModel else { return }
                let pid = self.agentId ?? Agent.defaultId
                AgentManager.shared.updateDefaultModel(for: pid, model: model)

                self.loadActiveModelOptions(for: model)

                // Clear pending image attachments when switching to a non-VLM model
                let newModelSupportsImages: Bool = {
                    if model.lowercased() == "foundation" { return false }
                    guard let option = self.pickerItems.first(where: { $0.id == model }) else { return false }
                    if case .remote = option.source { return true }
                    return option.isVLM
                }()
                if !newModelSupportsImages {
                    self.pendingAttachments = []
                }

                Task { @MainActor in
                    let active = ChatWindowManager.shared.activeLocalModelNames()
                    await ModelRuntime.shared.unloadModelsNotIn(active)
                }
            }

        // Always reconcile on init: the cache may already be loaded with a
        // snapshot taken before remote providers finished connecting (or
        // before this window's notification observer was registered, in
        // which case we'd otherwise miss the .remoteProviderModelsChanged
        // notification entirely). `refreshPickerItems` short-circuits when
        // nothing changed, so this is cheap on the happy path.
        Task { [weak self] in
            await self?.refreshPickerItems()
        }

        if MockChatData.isEnabled {
            rebuildVisibleBlocks()
        }
    }

    deinit {
        print("[ChatSession] deinit")
        currentTask?.cancel()
        generativeGreetingTask?.cancel()
        if let observer = remoteModelsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = localModelsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = agentTodoObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = projectMembershipObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        modelSelectionCancellable = nil
        agentAutoSpeakCancellable = nil
        promptQueueCancellable = nil
    }

    private func loadActiveModelOptions(for model: String?) {
        guard let model else {
            activeModelOptions = [:]
            return
        }

        // Load persisted options through the active profile so stale
        // per-model toggles do not leak into families whose option surface
        // changed. This runs for both user-picked and programmatic model
        // selection paths.
        activeModelOptions = ModelProfileRegistry.normalizedOptions(
            for: model,
            persisted: ModelOptionsStore.shared.loadOptions(for: model)
        )
    }

    /// Stable session id used as the AgentTodoStore key. Falls back to a
    /// per-window sentinel when no session has been created yet so brand-new
    /// chats still have a place to write their todo.
    var expectedTodoSessionId: String {
        sessionId?.uuidString ?? "chatwindow-\(ObjectIdentifier(self).hashValue)"
    }

    /// Pull `summary` out of a `complete(...)` tool call's JSON body.
    /// Returns nil when the JSON is malformed; the caller falls back to
    /// the raw tool result string.
    static func parseCompleteSummary(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let summary = dict["summary"] as? String
        else { return nil }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parse a `clarify(...)` tool call into a structured payload
    /// (question + optional options + allowMultiple). Delegated to
    /// `ClarifyTool.parse` so the schema lives in one place.
    static func parseClarifyPayload(from json: String) -> ClarifyPayload? {
        ClarifyTool.parse(argumentsJSON: json)
    }

    /// Apply initial model selection after agentId is set (for cached picker items)
    func applyInitialModelSelection() {
        guard selectedModel == nil, !pickerItems.isEmpty else { return }
        applyEffectiveModel(for: agentId)
        Task { [weak self] in await self?.refreshContextEstimates() }
    }

    /// Pick the picker item that best matches the agent's preferred model
    /// (falling back to the first chat-capable item). Wrapped in
    /// `isLoadingModel = true` so the auto-persist sink in `init()` does
    /// not write the selection back to the agent's settings as if the
    /// user had manually changed it.
    private func applyEffectiveModel(for agentId: UUID?) {
        isLoadingModel = true
        let effectiveModel = AgentManager.shared.effectiveModel(for: agentId ?? Agent.defaultId)
        if let model = effectiveModel, pickerItems.contains(where: { $0.id == model }) {
            selectedModel = model
        } else {
            selectedModel = pickerItems.firstChatCapable?.id
        }
        loadActiveModelOptions(for: selectedModel)
        isLoadingModel = false
    }

    func refreshPickerItems() async {
        let newOptions = await ModelPickerItemCache.shared.buildModelPickerItems()
        let newOptionIds = newOptions.map { $0.id }
        let optionsChanged = pickerItems.map({ $0.id }) != newOptionIds

        isDiscoveringModels = false

        guard optionsChanged else { return }

        // Options changed (e.g., remote models loaded) - re-check agent's preferred model.
        // This corrects the initial fallback to "foundation" when remote models weren't yet available.
        let effectiveModel = AgentManager.shared.effectiveModel(for: agentId ?? Agent.defaultId)
        let newSelected: String?

        if let model = effectiveModel, newOptionIds.contains(model) {
            newSelected = model
        } else if let prev = selectedModel, newOptionIds.contains(prev) {
            newSelected = prev
        } else {
            newSelected = newOptions.firstChatCapable?.id
        }

        pickerItems = newOptions
        isLoadingModel = true
        selectedModel = newSelected
        loadActiveModelOptions(for: selectedModel)
        isLoadingModel = false
        hasAnyModel = !newOptions.isEmpty
    }

    /// Check if the currently selected model supports images (VLM)
    var selectedModelSupportsImages: Bool {
        guard let model = selectedModel else { return false }
        if model.lowercased() == "foundation" { return false }
        if ModelMediaCapabilities.from(modelId: model).supportsImage { return true }
        guard let option = pickerItems.first(where: { $0.id == model }) else { return false }
        if case .remote = option.source { return true }
        return option.isVLM
    }

    var selectedModelSupportsAudio: Bool {
        guard let model = selectedModel else { return false }
        return ModelMediaCapabilities.from(modelId: model).supportsAudio
    }

    var selectedModelSupportsVideo: Bool {
        guard let model = selectedModel else { return false }
        return ModelMediaCapabilities.from(modelId: model).supportsVideo
    }

    /// Get the currently selected ModelPickerItem
    var selectedPickerItem: ModelPickerItem? {
        guard let model = selectedModel else { return nil }
        return pickerItems.first { $0.id == model }
    }

    /// Backing store for the streaming-mutated `visibleBlocks` / group-header map.
    /// Deliberately NOT `@Published` — mutations go through the store's own
    /// `objectWillChange`, not the session's, so ChatView's body + every sibling
    /// view stay static during streaming. The message thread subtree observes
    /// this store directly.
    let visibleBlocksStore = VisibleBlocksStore()

    /// Flattened content blocks for NSTableView rendering.
    /// Read-through to `visibleBlocksStore.blocks` so existing call sites
    /// (helpers, checks that don't need to drive re-renders) keep working.
    var visibleBlocks: [ContentBlock] { visibleBlocksStore.blocks }

    /// Precomputed group header map. Read-through to the store.
    var visibleBlocksGroupHeaderMap: [UUID: UUID] { visibleBlocksStore.groupHeaderMap }

    /// Whether the message thread has content (includes USE_MOCK_CHAT_DATA stress data).
    var hasVisibleThreadMessages: Bool {
        if MockChatData.isEnabled {
            return !visibleBlocks.isEmpty
        }
        return !turns.isEmpty
    }

    /// Last assistant turn for hover/regen chrome; respects mock thread when enabled.
    var lastAssistantTurnIdForThread: UUID? {
        if MockChatData.isEnabled {
            return visibleBlocks.last { $0.role == .assistant }?.turnId
        }
        return turns.last { $0.role == .assistant }?.id
    }

    /// Rebuild `visibleBlocks` and `visibleBlocksGroupHeaderMap` from current turns.
    /// Cheap to call repeatedly — BlockMemoizer fast-paths when nothing changed.
    func rebuildVisibleBlocks() {
        ChatPerfTrace.shared.count("rebuildVisibleBlocks")
        ChatPerfTrace.shared.time("rebuildVisibleBlocks.total") {
            rebuildVisibleBlocksImpl()
        }
    }

    private func rebuildVisibleBlocksImpl() {
        let agent = AgentManager.shared.agent(for: agentId ?? Agent.defaultId)
        let displayName = agent?.isBuiltIn == true ? "Assistant" : (agent?.name ?? "Assistant")
        let streamingTurnId = isStreaming ? turns.last?.id : nil

        if MockChatData.isEnabled {
            let mockTurns = MockChatData.mockTurnsForPerformanceTest()
            let newBlocks = blockMemoizer.blocks(
                from: mockTurns,
                streamingTurnId: nil,
                agentName: displayName,
                thinkingEnabled: thinkingEnabledForCurrentModel
            )
            let newHeaderMap = blockMemoizer.groupHeaderMap
            withAnimation(.none) {
                visibleBlocksStore.blocks = Self.appendingAssistantActionFooters(
                    newBlocks,
                    turns: mockTurns,
                    streamingTurnId: nil
                )
                visibleBlocksStore.groupHeaderMap = newHeaderMap
            }
            return
        }

        let newBlocks = blockMemoizer.blocks(
            from: turns,
            streamingTurnId: streamingTurnId,
            agentName: displayName,
            thinkingEnabled: thinkingEnabledForCurrentModel
        )
        let newHeaderMap = blockMemoizer.groupHeaderMap

        // use withAnimation(.none) to suppress the warning about publishing during view updates
        // this wraps the changes in a proper SwiftUI transaction
        withAnimation(.none) {
            visibleBlocksStore.blocks = Self.appendingAssistantActionFooters(
                newBlocks,
                turns: turns,
                streamingTurnId: streamingTurnId
            )
            visibleBlocksStore.groupHeaderMap = newHeaderMap
        }
    }

    /// Compensates for `BlockMemoizer.blocks(from:...)` (the Intel-lite
    /// reimplementation in `IntelDataConformers.swift` — the upstream
    /// `Managers/BlockMemoizer.swift` / `Models/Chat/ContentBlock.swift`
    /// are excluded from this fork's build entirely, see `Package.swift`)
    /// never emitting `.assistantActions` footer rows. That stub only
    /// builds header/thinking/paragraph/tool-call blocks, so the
    /// copy/regenerate/speak/delete row under a completed assistant
    /// turn was silently never generated. Mirrors the footer-eligibility
    /// rule the excluded upstream code used to apply inline: last turn
    /// in its consecutive-assistant group, not currently streaming, and
    /// carrying visible text, renderable thinking, or a tool call.
    private static func appendingAssistantActionFooters(
        _ blocks: [ContentBlock],
        turns: [ChatTurn],
        streamingTurnId: UUID?
    ) -> [ContentBlock] {
        let filteredTurns = turns.filter { $0.role != .tool }
        var footerEligibleTurnIds = Set<UUID>()
        for (index, turn) in filteredTurns.enumerated() {
            guard turn.role == .assistant, turn.id != streamingTurnId else { continue }
            let nextRole: MessageRole? =
                index + 1 < filteredTurns.count ? filteredTurns[index + 1].role : nil
            guard nextRole != turn.role else { continue }  // isLastInGroup
            let hasVisibleContent =
                !turn.visibleContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasFooterableContent =
                hasVisibleContent || turn.hasRenderableThinking || !(turn.toolCalls ?? []).isEmpty
            guard hasFooterableContent else { continue }
            footerEligibleTurnIds.insert(turn.id)
        }
        guard !footerEligibleTurnIds.isEmpty else { return blocks }

        var result: [ContentBlock] = []
        result.reserveCapacity(blocks.count + footerEligibleTurnIds.count)
        for (index, block) in blocks.enumerated() {
            result.append(block)
            let isLastBlockForTurn =
                index + 1 == blocks.count || blocks[index + 1].turnId != block.turnId
            if isLastBlockForTurn, footerEligibleTurnIds.contains(block.turnId) {
                result.append(
                    ContentBlock(
                        id: "actions-\(block.turnId.uuidString)",
                        turnId: block.turnId,
                        kind: .assistantActions(turnId: block.turnId)
                    )
                )
            }
        }
        return result
    }

    /// Estimated token count for current session context (~4 chars per token).
    /// Throttled to at most once per 500ms during streaming.
    var estimatedContextTokens: Int {
        estimatedContextBreakdown.total
    }

    /// Per-category breakdown of estimated context tokens.
    /// During streaming, returns the active snapshot with live output tokens.
    /// Otherwise derives from the cached `ComposedContext` or a preview manifest.
    var estimatedContextBreakdown: ContextBreakdown {
        if let active = budgetTracker.activeBreakdown(
            isActive: isStreaming,
            outputTurn: turns.last
        ) {
            return active
        }

        let effectiveId = agentId ?? Agent.defaultId
        let executionMode = estimatedChatExecutionMode(agentId: effectiveId)

        let outputTokens = ContextBudgetManager.estimateOutputTokens(for: turns)
        let conversationTokens = ContextBudgetManager.estimateTokens(for: turns) - outputTokens
        var inputTokens = 0
        if !input.isEmpty { inputTokens += ContextBudgetManager.estimateTokens(for: input) }
        for attachment in pendingAttachments { inputTokens += attachment.estimatedTokens }

        if let ctx = cachedContext {
            return .from(
                context: ctx,
                conversationTokens: conversationTokens,
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )
        }

        #if OSAURUS_INTEL
        // No cached context yet — e.g. a session restored after launch that
        // hasn't sent this run. Build a lightweight preview from the agent's
        // effective system prompt + currently-registered tools so the budget
        // shows the real prefix (System Prompt + Tools + Conversation), not just
        // typing tokens. `from(context:)` estimates the tool-token cost.
        let previewPrompt = AgentManager.shared.effectiveSystemPrompt(for: effectiveId)
        let previewTools =
            ChatConfiguration.shared.disableTools ? [] : ToolRegistry.shared.openAISpecs()
        // Mirror the section split that `composeChatContext` emits on send, so
        // the preview popover lists the same rails (Persona, and Grounding when
        // a working folder is mounted) rather than a single "System Prompt".
        var previewSections: [PromptSection] = []
        if !previewPrompt.isEmpty {
            previewSections.append(
                PromptSection(id: "persona", label: "Persona", text: previewPrompt, tint: .purple))
        }
        let previewFolderSection = SystemPromptTemplates.folderContext(
            from: FolderContextService.shared.currentContext)
        if !previewFolderSection.isEmpty {
            previewSections.append(
                PromptSection(id: "grounding", label: "Grounding", text: previewFolderSection, tint: .teal))
        }
        let preview = ComposedContext(
            prompt: previewPrompt + previewFolderSection,
            tools: previewTools,
            promptSections: previewSections)
        return .from(
            context: preview,
            conversationTokens: conversationTokens,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
        #else
        // Mirror what `composeChatContext` will emit on the next send so
        // the welcome-screen popover lists the same sections (Agent Loop,
        // Capability Discovery, Skills, model family, …) instead of the
        // base+sandbox-only stub. Preflight tool delta and Plugin
        // Companions are query-dependent and stay deferred — the
        // auto-mode `Tools` row can under-count by that delta on turn 1.
        let preview = SystemPromptComposer.composePreviewContext(
            agentId: effectiveId,
            executionMode: executionMode,
            model: selectedModel
        )
        return .from(
            manifest: preview.manifest,
            toolTokens: preview.toolTokens,
            memoryTokens: cachedMemoryTokens,
            conversationTokens: conversationTokens,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
        #endif
    }

    /// Builds the full user message text, prepending any attached document contents wrapped in XML tags.
    ///
    /// Filenames are reduced to their basename and both the name and the body are
    /// XML-entity-escaped so that a hostile document cannot forge a closing
    /// `</attached_document>` tag or inject bracketed pseudo-tool markers that
    /// would otherwise reach the model as control text.
    static func buildUserMessageText(content: String, attachments: [Attachment]) -> String {
        let docs = attachments.filter(\.isDocument)
        guard !docs.isEmpty else { return content }

        var parts: [String] = []
        for doc in docs {
            if let name = doc.filename, let text = doc.documentContent {
                let attributes = attachedDocumentAttributes(for: doc, rawName: name)
                let safeText = xmlEscape(text)
                parts.append("<attached_document \(attributes)>\n\(safeText)\n</attached_document>")
            }
        }

        if !content.isEmpty {
            parts.append(content)
        }

        return parts.joined(separator: "\n\n")
    }

    static func buildUserChatMessage(
        content: String,
        attachments: [Attachment],
        supportsImages: Bool,
        supportsAudio: Bool,
        supportsVideo: Bool
    ) -> ChatMessage {
        let messageText = buildUserMessageText(content: content, attachments: attachments)
        let imageData = supportsImages ? attachments.images : []
        let audioPayloads =
            supportsAudio
            ? attachments.compactMap(audioPayload)
            : []
        let audios = audioPayloads.map { (data: $0.data, format: $0.format) }
        let localAudioSamples = audioPayloads.map(\.localSamples)
        let videos: [(data: Data, mimeSubtype: String)] =
            supportsVideo
            ? attachments.compactMap(videoPayload)
            : []

        if !imageData.isEmpty || !audios.isEmpty || !videos.isEmpty {
            return ChatMessage(
                role: "user",
                text: messageText,
                imageData: imageData,
                audios: audios,
                localAudioSamples: localAudioSamples,
                videos: videos
            )
        }

        return ChatMessage(role: "user", content: messageText)
    }

    private static func audioPayload(from attachment: Attachment) -> (
        data: Data,
        format: String,
        localSamples: LocalAudioSamples?
    )? {
        guard attachment.isAudio, let data = attachment.loadAudioData() else { return nil }
        let format = attachment.audioFormat?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return (
            data,
            (format?.isEmpty == false) ? format! : "wav",
            LiveVoiceAudioInputRegistry.shared.samples(for: attachment.id)
        )
    }

    private static func videoPayload(from attachment: Attachment) -> (data: Data, mimeSubtype: String)? {
        guard attachment.isVideo, let data = attachment.loadVideoData() else { return nil }
        return (data, videoMimeSubtype(for: attachment.filename))
    }

    private static func videoMimeSubtype(for filename: String?) -> String {
        let ext = ((filename ?? "") as NSString).pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch ext {
        case "mov", "qt", "quicktime":
            return "quicktime"
        case "m4v":
            return "mp4"
        case "":
            return "mp4"
        default:
            return ext
        }
    }

    private static func escapeAttachmentName(_ raw: String) -> String {
        xmlEscape(normalizedAttachmentName(raw))
    }

    private static func normalizedAttachmentName(_ raw: String) -> String {
        let basename = (raw as NSString).lastPathComponent
        let trimmed = basename.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "attachment" : trimmed
    }

    private static func attachedDocumentAttributes(for attachment: Attachment, rawName: String) -> String {
        var attributes: [(name: String, value: String)] = [
            ("name", normalizedAttachmentName(rawName))
        ]
        if attachment.structuredDocumentMetadata != nil {
            if let summary = attachment.businessDocumentSummary {
                attributes.append(contentsOf: summary.contextAttributes)
            }
        }
        return
            attributes
            .map { "\($0.name)=\"\(xmlEscape($0.value))\"" }
            .joined(separator: " ")
    }

    private static func xmlEscape(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Format token count for display (e.g., "1.2K", "15K")
    static func formatTokenCount(_ tokens: Int) -> String {
        if tokens < 1000 {
            return "\(tokens)"
        } else if tokens < 10000 {
            let k = Double(tokens) / 1000.0
            return String(format: "%.1fK", k)
        } else {
            let k = tokens / 1000
            return "\(k)K"
        }
    }

    #if OSAURUS_INTEL
    /// Ask the configured core model (falling back to the active chat model)
    /// for a short title summarizing the first exchange, then apply it. Runs
    /// off the send path; any failure leaves the first-line fallback title.
    private func generateLLMTitle(userText: String, assistantText: String, sessionId: UUID) {
        let titleModel =
            ChatConfiguration.shared.coreModelName ?? selectedModel ?? "deepseek-v4-flash"
        let engine = chatEngineFactory()
        let sys = ChatMessage(
            role: "system",
            content:
                "You write very short chat titles. Reply with ONLY a 3–6 word title in Title "
                + "Case — no quotes, no trailing punctuation, no preamble.")
        let usr = ChatMessage(
            role: "user",
            content:
                "First user message:\n\(userText)\n\nAssistant reply:\n"
                + "\(String(assistantText.prefix(800)))\n\nTitle:")
        let req = ChatCompletionRequest(
            model: titleModel,
            messages: [sys, usr],
            temperature: 0.3,
            max_tokens: 24,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil,
            session_id: nil
        )
        print("[ChatSession] generating title via core model '\(titleModel)' for session \(sessionId)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let resp = try await engine.completeChat(request: req)
                let raw = resp.choices.first?.message?.content ?? ""
                let cleaned = Self.cleanTitle(raw)
                print("[ChatSession] title raw='\(raw.prefix(60))' cleaned='\(cleaned)'")
                // Only apply if we're still on the same session and got a title.
                guard !cleaned.isEmpty, self.sessionId == sessionId else { return }
                self.title = cleaned
                self.save()
                self.onSessionChanged?()
                print("[ChatSession] title applied: '\(cleaned)'")
            } catch {
                print("[ChatSession] LLM title generation failed: \(error.localizedDescription)")
            }
        }
    }

    /// Generate an AI title on demand from the `/title` slash command
    /// (Intel port of upstream 3580502c). Reuses the same CloudChatEngine
    /// call as the automatic path in `generateLLMTitle`, but ignores
    /// `autoGenerateChatTitles` — the user explicitly asked for a rename —
    /// and surfaces the result (or failure) as a toast instead of failing
    /// silently, since the user is waiting on it.
    func generateTitleFromSlashCommand() {
        guard let sid = sessionId,
            let userTurn = turns.first(where: {
                $0.role == .user
                    && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        else {
            ToastManager.shared.infoLocalized(
                "Chat Title",
                message: "Send a message first, then use /title to name the chat."
            )
            return
        }
        let assistantText =
            turns.first(where: {
                $0.role == .assistant
                    && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })?.content ?? ""
        // Latch so a later clean run completion doesn't auto-title over the
        // name the user just asked for.
        llmTitleAttempted = true

        let titleModel = ChatConfiguration.shared.coreModelName ?? selectedModel ?? "deepseek-v4-flash"
        let engine = chatEngineFactory()
        let sys = ChatMessage(
            role: "system",
            content:
                "You write very short chat titles. Reply with ONLY a 3–6 word title in Title "
                + "Case — no quotes, no trailing punctuation, no preamble.")
        let usr = ChatMessage(
            role: "user",
            content:
                "First user message:\n\(userTurn.content)\n\nAssistant reply:\n"
                + "\(String(assistantText.prefix(800)))\n\nTitle:")
        let req = ChatCompletionRequest(
            model: titleModel,
            messages: [sys, usr],
            temperature: 0.3,
            max_tokens: 24,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil,
            session_id: nil
        )
        // Loading toast while the model thinks, updated in place to the
        // success/error outcome.
        let toastId = ToastManager.shared.loadingLocalized("Generating Title…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let resp = try await engine.completeChat(request: req)
                let raw = resp.choices.first?.message?.content ?? ""
                let cleaned = Self.cleanTitle(raw)
                guard !cleaned.isEmpty else {
                    ToastManager.shared.update(
                        id: toastId,
                        type: .error,
                        title: "Chat Title",
                        message: "Couldn't generate a title. Check that a model is available and try again."
                    )
                    return
                }
                ChatSessionsManager.shared.rename(id: sid, title: cleaned)
                if self.sessionId == sid { self.title = cleaned }
                self.onSessionChanged?()
                ToastManager.shared.update(
                    id: toastId,
                    type: .success,
                    title: "Chat Renamed",
                    message: cleaned
                )
            } catch {
                ToastManager.shared.update(
                    id: toastId,
                    type: .error,
                    title: "Chat Title",
                    message: "Couldn't generate a title. Check that a model is available and try again."
                )
            }
        }
    }

    /// Normalize a model-returned title: strip quotes/newlines, trim, cap length.
    static func cleanTitle(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.components(separatedBy: .newlines).first ?? t
        t = t.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "“", with: "")
            .replacingOccurrences(of: "”", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop a leading "Title:" the model sometimes echoes.
        if t.lowercased().hasPrefix("title:") {
            t = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        if t.count > 60 { t = String(t.prefix(57)) + "..." }
        return t
    }
    #endif

    func sendCurrent() {
        guard !isStreaming else { return }
        let text = input
        let attachments = pendingAttachments
        input = ""
        pendingAttachments = []
        send(text, attachments: attachments)
    }

    func stop() {
        #if OSAURUS_INTEL
        print(
            "[ChatSession] stop() called — isStreaming=\(isStreaming) "
                + "activeRunId=\(String(describing: activeRunId)) sessionId=\(String(describing: sessionId))"
        )
        #endif
        stopRequested = true
        let task = currentTask
        task?.cancel()
        if let runId = activeRunId {
            finalizeRun(runId: runId, persistConversationArtifacts: false)
        } else {
            completeRunCleanup()
        }
    }

    // MARK: - Queued Send (Cursor-style interrupt UX)

    /// Capture the current `input` + `pendingAttachments` + `pendingOneOffSkillId`
    /// into a single-slot pending send and clear the input. No-op if the
    /// payload is empty. Replacing semantics: a second call while a queue
    /// is already pending overwrites it. The transcript is NOT touched —
    /// the queued message only materializes as a `user` turn when the run
    /// finishes (auto-flush) or when `sendNowInterrupting()` is invoked.
    func enqueueSend(_ text: String, attachments: [Attachment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = !trimmed.isEmpty || !attachments.isEmpty
        guard hasContent else { return }
        queuedSend = QueuedSend(
            text: trimmed,
            attachments: attachments,
            oneOffSkillId: pendingOneOffSkillId
        )
        input = ""
        pendingAttachments = []
        pendingOneOffSkillId = nil
    }

    /// Drop the queued send without dispatching it.
    func cancelQueuedSend() {
        queuedSend = nil
    }

    /// Stop the currently streaming run and immediately dispatch the queued
    /// send as a fresh user turn. No-op if nothing is queued. The active
    /// run is finalized synchronously (`stop()` runs through
    /// `finalizeRun → completeRunCleanup`, flipping `isStreaming` to false)
    /// so the follow-up `send(...)` passes the `!isStreaming` guard. The
    /// stored `oneOffSkillId` is re-applied to `pendingOneOffSkillId` so
    /// the skill context attaches to the new turn.
    func sendNowInterrupting() {
        guard let pending = queuedSend else { return }
        queuedSend = nil
        if isStreaming || activeRunId != nil {
            stop()
        }
        if let skillId = pending.oneOffSkillId {
            pendingOneOffSkillId = skillId
        }
        send(pending.text, attachments: pending.attachments)
    }

    /// Appends a `user`-role turn carrying a plugin-supplied interrupt
    /// message. Called by `BackgroundTaskManager.interruptTask` when a
    /// plugin invokes `dispatch_interrupt(taskId, message)` with a
    /// non-empty `message`. The turn lands in the persisted transcript
    /// so the model picks it up on the next completion round.
    func appendInterruptMessage(_ message: String) {
        let turn = ChatTurn(role: .user, content: message)
        turns.append(turn)
        isDirty = true
        rebuildVisibleBlocks()
    }

    func reset() {
        stop()
        turns.removeAll()
        input = ""
        pendingAttachments = []
        pendingOneOffSkillId = nil
        queuedSend = nil
        voiceInputState = .idle
        showVoiceOverlay = false
        // Clear session identity for new chat
        if let prev = sessionId {
            let key = sessionStateKey(prev)
            Task { await SessionToolStateStore.shared.invalidate(key) }
        }
        sessionId = nil
        title = "New Chat"
        llmTitleAttempted = false
        createdAt = Date()
        updatedAt = Date()
        source = .chat
        sourcePluginId = nil
        externalSessionKey = nil
        dispatchTaskId = nil
        archived = false
        pinned = false
        projectId = nil
        isDirty = false

        // Reset agent-loop UI state.
        currentTodo = nil
        lastCompletionSummary = nil
        promptQueue.drainAll()
        let oldSid = expectedTodoSessionId
        Task { await AgentTodoStore.shared.clear(for: oldSid) }
        // Keep current agentId - don't reset when creating new chat within same agent

        // Clear caches
        blockMemoizer.clear()
        cachedContext = nil
        visibleBlocksStore.blocks = []
        visibleBlocksStore.groupHeaderMap = [:]

        resetGenerativeGreeting()

        applyEffectiveModel(for: agentId)
        rebuildVisibleBlocks()
    }

    /// Reset for a specific agent
    func reset(for newAgentId: UUID?) {
        // Reset under the OLD agentId so any save() triggered inside
        // stop() → completeRunCleanup() preserves the current session's
        // identity instead of stamping the new agent on it. See #1005.
        reset()
        agentId = newAgentId
        // reset() picked a model for the OLD agent; re-resolve for the
        // new one now that turns/sessionId are cleared.
        applyEffectiveModel(for: newAgentId)
        Task { [weak self] in await self?.refreshContextEstimates() }
    }

    // MARK: - Generative Greeting

    /// Asynchronously fetch (and cache) a delightful greeting + four quick
    /// actions for the current empty state. Idempotent for a given
    /// `(session, agent, model)` combination — re-appearing the empty
    /// state, scrolling, or theme changes won't re-fire the inference.
    ///
    /// State machine: `idle` (feature off / no model) → `loading` (task in
    /// flight) → `ready(payload)` on success, `failed` on any throw or
    /// cancellation. The UI uses `loading` to render a skeleton, and both
    /// `idle` and `failed` to render the static fallback.
    func loadGenerativeGreetingIfNeeded(agent: Agent, globallyEnabled: Bool) {
        guard agent.shouldUseGenerativeGreetings(globallyEnabled: globallyEnabled) else {
            generativeGreetingState = .idle
            generativeGreetingKey = nil
            generativeGreetingTask?.cancel()
            generativeGreetingTask = nil
            return
        }

        guard hasAnyModel else { return }
        guard let model = selectedModel, !model.isEmpty else { return }

        let sessionPart = sessionId?.uuidString ?? "draft"
        let key = "\(sessionPart):\(agent.id.uuidString):\(model)"
        if key == generativeGreetingKey { return }

        generativeGreetingKey = key
        generativeGreetingTask?.cancel()

        let snapshot = agent
        generativeGreetingTask = Task { [weak self] in
            // Tell the pool which (agent, model) the user is looking
            // at so its periodic ticker has a refill target even when
            // no popFresh / warmUp call is in flight.
            await GenerativeGreetingPool.shared.setActive(
                agent: snapshot,
                model: model
            )

            // Hot path: a pre-generated greeting is already waiting.
            // Skip the loading skeleton entirely and ride straight to
            // `.ready`, then fire a background warmUp to top the pool
            // back up to target.
            if let cached = await GenerativeGreetingPool.shared.popFresh(
                for: snapshot,
                model: model
            ) {
                // Commit to the UI atomically: only assign `.ready` if
                // the task hasn't been cancelled and the cache key
                // still matches. If it doesn't match (rapid hide/show,
                // agent switch landed mid-pop), push the cached entry
                // BACK into the pool — it cost us a model call to
                // produce, throwing it away on every fast switch is
                // wasteful. Returning a `Bool` from `MainActor.run`
                // lets us keep the commit guard atomic without
                // splitting it across two hops.
                let didCommit = await MainActor.run { () -> Bool in
                    guard let self = self else { return false }
                    guard !Task.isCancelled,
                        self.generativeGreetingKey == key
                    else { return false }
                    self.generativeGreetingState = .ready(cached)
                    return true
                }
                if !didCommit {
                    await GenerativeGreetingPool.shared.seed(
                        cached,
                        for: snapshot,
                        model: model
                    )
                    return
                }
                await GenerativeGreetingPool.shared.warmUp(
                    for: snapshot,
                    model: model
                )
                return
            }

            // Cold path: pool was empty (first session of the run, or
            // an invalidation just landed). Flip to `.loading` so the
            // empty state renders the skeleton, then generate inline
            // and seed the pool with the result so the *next* session
            // open is hot.
            await MainActor.run {
                guard let self = self else { return }
                guard self.generativeGreetingKey == key else { return }
                self.generativeGreetingState = .loading
            }
            do {
                let result = try await GenerativeGreetingService.shared.generate(
                    agent: snapshot,
                    fallbackModel: model
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self = self else { return }
                    guard self.generativeGreetingKey == key else { return }
                    self.generativeGreetingState = .ready(result)
                }
                await GenerativeGreetingPool.shared.warmUp(
                    for: snapshot,
                    model: model
                )
            } catch {
                guard !Task.isCancelled else { return }
                // Silent fallback — `.failed` flips the empty state back
                // to the static greeting + the agent's configured quick
                // actions. `.idle` is reserved for "feature is off" so
                // the UI can distinguish the two.
                await MainActor.run {
                    guard let self = self else { return }
                    guard self.generativeGreetingKey == key else { return }
                    self.generativeGreetingState = .failed
                }
            }
        }
    }

    /// Cancel any in-flight greeting generation and clear cached output.
    /// Called from `reset()`, `deinit`, and `ChatWindowManager.hideWindow`
    /// — the latter so re-opening the window pops a fresh entry from the
    /// pool instead of briefly flashing the previous session's greeting.
    func resetGenerativeGreeting() {
        generativeGreetingTask?.cancel()
        generativeGreetingTask = nil
        generativeGreetingKey = nil
        generativeGreetingState = .idle
    }

    /// Invalidate the token cache (called when tools/skills change)
    func invalidateTokenCache() {
        cachedContext = nil
        budgetTracker.clear()
        objectWillChange.send()
    }

    // MARK: - Persistence Methods

    /// Convert current state to persistable data
    func toSessionData() -> ChatSessionData {
        let turnData = turns.map { ChatTurnData(from: $0) }
        return ChatSessionData(
            id: sessionId ?? UUID(),
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            selectedModel: selectedModel,
            turns: turnData,
            agentId: agentId,
            source: source,
            sourcePluginId: sourcePluginId,
            externalSessionKey: externalSessionKey,
            dispatchTaskId: dispatchTaskId,
            archived: archived,
            pinned: pinned,
            capabilities: SessionCapability.derive(from: turnData),
            projectId: projectId
        )
    }

    /// Save current session state
    func save() {
        // Only save if there are turns
        guard !turns.isEmpty else { return }

        // Create session ID if this is a new session
        if sessionId == nil {
            sessionId = UUID()
            createdAt = Date()
            isDirty = true
        }

        // Only update timestamp if content actually changed
        if isDirty {
            updatedAt = Date()
            isDirty = false
        }

        // Auto-generate title from first user message if still default
        if title == "New Chat" {
            let turnData = turns.map { ChatTurnData(from: $0) }
            title = ChatSessionData.generateTitle(from: turnData)
        }

        let data = toSessionData()
        ChatSessionsManager.shared.save(data)
        onSessionChanged?()
    }

    /// Load session from persisted data
    func load(from data: ChatSessionData) {
        stop()
        sessionId = data.id
        title = data.title
        // Existing session already has a title — don't regenerate one.
        llmTitleAttempted = true
        createdAt = data.createdAt
        updatedAt = data.updatedAt
        agentId = data.agentId
        source = data.source
        sourcePluginId = data.sourcePluginId
        externalSessionKey = data.externalSessionKey
        dispatchTaskId = data.dispatchTaskId
        archived = data.archived
        pinned = data.pinned
        projectId = data.projectId

        // Restore the persisted model when it's still valid; otherwise
        // fall back to the agent's preferred model. `isLoadingModel`
        // suppresses the auto-persist sink so a load doesn't look like
        // the user just picked a model.
        if let savedModel = data.selectedModel,
            pickerItems.contains(where: { $0.id == savedModel })
        {
            isLoadingModel = true
            selectedModel = savedModel
            loadActiveModelOptions(for: selectedModel)
            isLoadingModel = false
        } else {
            applyEffectiveModel(for: data.agentId)
        }

        turns = data.turns.map { ChatTurn(from: $0) }
        voiceInputState = .idle
        showVoiceOverlay = false
        input = ""
        pendingAttachments = []
        isDirty = false  // Fresh load, not dirty
        // Clear caches to force a clean block rebuild for the new session
        blockMemoizer.clear()
        cachedContext = nil
        rebuildVisibleBlocks()

        Task { [weak self] in await self?.refreshContextEstimates() }
    }

    private func refreshMemoryTokens() async {
        let effectiveAgentId = agentId ?? Agent.defaultId
        guard !AgentManager.shared.effectiveMemoryDisabled(for: effectiveAgentId) else {
            if cachedMemoryTokens != 0 {
                cachedMemoryTokens = 0
                objectWillChange.send()
            }
            return
        }
        let context = await MemoryContextAssembler.assembleContext(
            agentId: effectiveAgentId.uuidString,
            config: MemoryConfigurationStore.load()
        )
        let newTokens = ContextBudgetManager.estimateTokens(for: context)
        guard newTokens != cachedMemoryTokens else { return }
        cachedMemoryTokens = newTokens
        objectWillChange.send()
    }

    /// Re-resolve every async input the welcome-screen preview composer
    /// needs. Currently only memory tokens, but kept as a single entry
    /// point so future async preview inputs land in one place instead of
    /// being scattered across the trigger sites (agent change, session
    /// reset, session load, capability config update).
    private func refreshContextEstimates() async {
        await refreshMemoryTokens()
    }

    /// Edit a user message and regenerate from that point
    func editAndRegenerate(turnId: UUID, newContent: String) {
        guard let index = turns.firstIndex(where: { $0.id == turnId }) else { return }
        guard turns[index].role == .user else { return }

        // Update the content
        turns[index].content = newContent

        // Remove all turns after this one
        turns = Array(turns.prefix(index + 1))

        // Mark as dirty and save
        isDirty = true
        rebuildVisibleBlocks()
        save()
        send("")  // Empty send to trigger regeneration with existing history
    }

    /// Delete a turn and all subsequent turns
    func deleteTurn(id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns = Array(turns.prefix(index))
        isDirty = true
        rebuildVisibleBlocks()
        save()
    }

    /// Remove a single assistant turn (and the tool turns that belong to it)
    /// while keeping every other turn in the conversation intact. Upstream
    /// c4d9d140.
    ///
    /// Unlike `deleteTurn(id:)`, which truncates from the given turn onward,
    /// this excises just one response. When the assistant turn issued tool
    /// calls, the following `.tool` turns carrying their results are orphaned
    /// the moment the assistant message goes away — a `tool` message with no
    /// preceding `tool_calls` is an invalid request shape that providers
    /// reject — so we drop those paired result turns together. Dropping the
    /// turn from `turns` is enough for both model requests and the context
    /// token estimate to stop counting it, since both derive from `turns`.
    func removeTurn(id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        let turn = turns[index]

        var indicesToRemove = IndexSet(integer: index)

        // Assistant turns that made tool calls own the `.tool` result turns that
        // immediately follow them; those results reference the call ids and must
        // leave with the assistant message so the remaining sequence stays valid.
        if turn.role == .assistant, let calls = turn.toolCalls, !calls.isEmpty {
            let callIds = Set(calls.map { $0.id })
            var cursor = index + 1
            while cursor < turns.count, turns[cursor].role == .tool {
                if let toolCallId = turns[cursor].toolCallId, callIds.contains(toolCallId) {
                    indicesToRemove.insert(cursor)
                }
                cursor += 1
            }
        }

        turns.remove(atOffsets: indicesToRemove)
        isDirty = true
        rebuildVisibleBlocks()
        save()
    }

    /// Remove the whole exchange an assistant turn belongs to: the user turn
    /// that prompted it plus every assistant/tool turn that answered that
    /// prompt. Upstream c4d9d140.
    ///
    /// Deleting an assistant reply on its own strands the user message (the
    /// next request would show an unanswered question the model just
    /// re-answers), so this is the coherent "drop this Q&A and keep the rest"
    /// operation. The exchange is the contiguous run from the nearest preceding
    /// `user` turn up to (but not including) the next `user` turn, which keeps
    /// tool-call/result pairings inside the block intact.
    func removeExchange(anchoredAt id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }

        // Walk back to the user turn that opened this exchange. If there's no
        // preceding user turn (e.g. an unprompted opening assistant message),
        // anchor the block at the turn itself.
        var start = index
        var back = index
        while back >= 0 {
            if turns[back].role == .user {
                start = back
                break
            }
            back -= 1
        }

        // Walk forward to just before the next user turn; everything in between
        // is part of answering the same prompt.
        var end = turns.count - 1
        var forward = index + 1
        while forward < turns.count {
            if turns[forward].role == .user {
                end = forward - 1
                break
            }
            forward += 1
        }

        turns.removeSubrange(start...end)
        isDirty = true
        rebuildVisibleBlocks()
        save()
    }

    /// Regenerate an assistant response (removes it and regenerates)
    func regenerate(turnId: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == turnId }) else { return }
        guard turns[index].role == .assistant else { return }

        // Remove this turn and all subsequent turns
        turns = Array(turns.prefix(index))
        isDirty = true
        rebuildVisibleBlocks()

        // Regenerate
        send("")
    }

    // MARK: - Share Artifact Processing

    /// Process share_artifact tool results in chat context.
    /// Uses the shared processing pipeline to copy files, persist to DB,
    /// and enrich the result metadata for ContentBlock display.
    ///
    /// `toolResult` is the new `ToolEnvelope.success` shape whose
    /// `result.text` carries the marker-delimited artifact blob. We
    /// extract the text, run the marker pipeline, and re-wrap the
    /// enriched marker block back into a success envelope. When marker
    /// parsing or file resolution fails we surface a structured
    /// `ToolEnvelope.failure(...)` so the model is told the truth instead
    /// of seeing a bogus "success" envelope.
    private func processShareArtifactResult(
        toolResult: String,
        executionMode: ExecutionMode
    ) -> String {
        guard let sessionId else { return toolResult }
        let agentName = SandboxAgentProvisioner.linuxName(
            for: (agentId ?? Agent.defaultId).uuidString
        )

        // Extract the marker block from the envelope. Older shapes (raw
        // marker-only string from before the envelope migration) are
        // accepted too so plugin authors who emit raw markers keep working.
        let markerText: String
        if let payload = ToolEnvelope.successPayload(toolResult) as? [String: Any],
            let text = payload["text"] as? String
        {
            markerText = text
        } else {
            markerText = toolResult
        }

        let outcome = SharedArtifact.processToolResultDetailed(
            markerText,
            contextId: sessionId.uuidString,
            contextType: .chat,
            executionMode: executionMode,
            sandboxAgentName: agentName
        )
        switch outcome {
        case .success(let processed):
            return ToolEnvelope.success(tool: "share_artifact", text: processed.enrichedToolResult)

        case .failure(let reason):
            // Surface a model-readable error per failure mode. Without
            // this differentiation the model just retries the same path
            // (the previous "could not resolve or copy" string was the
            // same envelope for "path rejected", "file missing", and
            // "copy failed" — three very different fixes).
            return Self.shareArtifactFailureEnvelope(
                reason: reason,
                executionMode: executionMode
            )
        }
    }

    /// Translate a `SharedArtifact.ResolutionFailure` into a
    /// `ToolEnvelope.failure` whose `message` tells the model exactly
    /// what went wrong AND what to try next. The "next" hint is keyed on
    /// `executionMode` so sandbox agents get a `sandbox_search_files`
    /// suggestion while folder agents get `file_tree`/`file_search`.
    private static func shareArtifactFailureEnvelope(
        reason: SharedArtifact.ResolutionFailure,
        executionMode: ExecutionMode
    ) -> String {
        let toolName = "share_artifact"
        let listingHint: String
        switch executionMode {
        case .sandbox:
            listingHint =
                "Verify the file with `sandbox_search_files(target=\"files\", pattern=\"<name>\")`, "
                + "or pass `content`+`filename` for inline data."
        case .hostFolder:
            listingHint =
                "Verify the file with `file_tree`/`file_search`, or pass `content`+`filename` "
                + "for inline data."
        case .none:
            listingHint =
                "Pass `content`+`filename` for inline data, or attach a working folder/sandbox first."
        }

        // Local helpers prefix every message with `share_artifact failed: `
        // and fill in the always-the-same `tool` / `retryable` fields, so
        // the per-case branches read at the level of the actual diagnostic.
        func fail(
            _ kind: ToolEnvelope.Kind,
            _ message: String,
            field: String? = nil,
            expected: String? = nil
        ) -> String {
            ToolEnvelope.failure(
                kind: kind,
                message: "share_artifact failed: \(message)",
                field: field,
                expected: expected,
                tool: toolName,
                retryable: true
            )
        }

        switch reason {
        case .markersMissing:
            return fail(
                .executionError,
                "marker block missing from tool result. This is a tool-runtime bug — "
                    + "retry once; if it persists, share the content inline."
            )
        case .noContentOrPath:
            return fail(
                .invalidArgs,
                "neither `path` nor `content` was provided. Pass an existing file path, "
                    + "or `content`+`filename` for inline text."
            )
        case .destinationRejected(let filename):
            return fail(
                .invalidArgs,
                "filename `\(filename)` was rejected (would escape the artifacts directory). "
                    + "Pass a plain basename like `report.md`.",
                field: "filename",
                expected: "single-segment filename without `..` or absolute path"
            )
        case .pathRejected(let path):
            return fail(
                .invalidArgs,
                "path `\(path)` was rejected (escapes the trusted root, is an unrelated absolute "
                    + "path, or contains traversal). \(listingHint)",
                field: "path",
                expected: "path under the agent home / working folder"
            )
        case .fileNotFound(let path, let searchedLocations):
            let searchedSummary =
                searchedLocations.isEmpty
                ? "(no candidates resolved)"
                : searchedLocations.joined(separator: ", ")
            return fail(
                .executionError,
                "file not found for `\(path)`. Searched: \(searchedSummary). \(listingHint)"
            )
        case .copyFailed(let source, let detail):
            return fail(
                .executionError,
                "copy from `\(source)` to artifacts dir threw: \(detail). "
                    + "Retry once; if it persists, share the content inline."
            )
        }
    }

    private struct RunContext {
        let hasContent: Bool
        let userContent: String
        let memoryAgentId: String
        let memoryConversationId: String
        /// Project this chat belongs to, if any — captured at run-start
        /// alongside the other memory fields so the completion handler
        /// (which may run detached, off the main actor) doesn't need to
        /// touch `@Published var projectId` itself. Threading this through
        /// (rather than overwriting `memoryAgentId`) keeps the existing
        /// per-agent memory-toggle check below untouched: writes route to
        /// the project namespace additively, they don't replace the
        /// agent's own.
        let projectId: UUID?
    }

    private func isRunActive(_ runId: UUID) -> Bool {
        activeRunId == runId && !Task.isCancelled
    }

    /// Push the rolling-rate's current value onto the live `ChatTurn` field
    /// at ~5Hz so the UI tok/s display ramps smoothly during streaming.
    /// Throttled because text streams can produce 100+ deltas/sec — every
    /// SwiftUI re-render of the stats cell costs an animation tick, and at
    /// full rate that swamps the MainActor on smaller responses. The
    /// chosen 0.18s cadence (~5.5Hz) matches the existing tool-arg rebuild
    /// throttle (line ~1199) for visual consistency. Skips the update when
    /// the rolling rate is still in warm-up (`currentRate` returns nil) so
    /// the cell shows nothing until the steady-state read is meaningful —
    /// avoids the prior "shows 12 tok/s for the first half-second then
    /// jumps to 60 tok/s" jitter users complained about.
    private func refreshLiveRate(
        rolling: inout RollingTokenRate,
        lastRefreshAt: inout Date,
        now: Date,
        turn: ChatTurn
    ) {
        guard now.timeIntervalSince(lastRefreshAt) >= 0.18 else { return }
        guard let rate = rolling.currentRate(at: now) else { return }
        lastRefreshAt = now
        turn.generationTokensPerSecond = rate
        // Don't bump generationTokenCount here — vmlx's authoritative count
        // arrives in the StreamingStatsHint sentinel and would be overwritten
        // by an estimate. Final stamp uses rolling.totalTokens only as a
        // last-resort fallback when the sentinel never fires.
    }

    private func trimTrailingEmptyAssistantTurn() {
        if let lastTurn = turns.last,
            lastTurn.role == .assistant,
            lastTurn.contentIsBlank,
            lastTurn.toolCalls == nil,
            !lastTurn.hasRenderableThinking,
            lastTurn.generationTokenCount == nil,
            lastTurn.generationTokensPerSecond == nil
        {
            turns.removeLast()
        }
    }

    private func consolidateAssistantTurns() {
        for turn in turns where turn.role == .assistant {
            turn.consolidateContent()
        }
    }

    private func beginRun(_ runId: UUID, context: RunContext) {
        activeRunId = runId
        activeRunContext = context
    }

    /// Best-effort estimate of the execution mode the next send will use.
    /// Prefers the registry's actual registered state (matches what
    /// `prepareChatExecutionMode` would resolve) so the token-budget preview
    /// doesn't disagree with the prompt that's actually sent. Falls back to
    /// the autonomous flag when sandbox tools have not yet been registered
    /// (first send of a session before any tool call has provisioned the
    /// container). When the user has a host folder mounted but sandbox is
    /// off, that wins — folder tools must enter the schema or
    /// `excludedToolNames(.none)` will hide them entirely.
    private func estimatedChatExecutionMode(agentId: UUID) -> ExecutionMode {
        let folder = FolderContextService.shared.currentContext
        let autonomous = AgentManager.shared.effectiveAutonomousExec(for: agentId)?.enabled == true
        let resolved = ToolRegistry.shared.resolveExecutionMode(
            folderContext: folder,
            autonomousEnabled: autonomous
        )
        // Optimistic estimate: when autonomous is on but sandbox tools haven't
        // registered yet, report `.sandbox` so the budget preview matches what
        // the next send will most likely produce after `registerTools` runs.
        if autonomous && resolved.usesSandboxTools == false { return .sandbox }
        return resolved
    }

    private func completeRunCleanup() {
        currentTask = nil
        isStreaming = false
        budgetTracker.clear()
        ServerController.signalGenerationEnd()
        trimTrailingEmptyAssistantTurn()
        consolidateAssistantTurns()
        rebuildVisibleBlocks()
        save()
        flushQueuedSendIfEligible()
    }

    /// Dispatch any queued send when the run ended naturally (no `stop()`
    /// in-flight, no streaming error). Cancelled or errored runs leave the
    /// queue in place so the user can re-decide via the chip or Send Now.
    /// Called from `completeRunCleanup` after state has been finalized.
    private func flushQueuedSendIfEligible() {
        guard !stopRequested, lastStreamError == nil else { return }
        guard let pending = queuedSend else { return }
        queuedSend = nil
        if let skillId = pending.oneOffSkillId {
            pendingOneOffSkillId = skillId
        }
        send(pending.text, attachments: pending.attachments)
    }

    /// Reused across runs so we don't pay the ICU date-symbol allocation that a
    /// fresh `ISO8601DateFormatter` (or the `ISO8601DateFormatter.string` static)
    /// triggers on every finalize. The time zone is reapplied per use.
    private static let sessionDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        return formatter
    }()

    private func finalizeRun(runId: UUID?, persistConversationArtifacts: Bool) {
        guard let runId, activeRunId == runId else {
            if activeRunId == nil, isStreaming {
                completeRunCleanup()
            }
            return
        }

        let context = activeRunContext
        activeRunId = nil
        activeRunContext = nil

        // Snapshot "this was the first exchange" BEFORE completeRunCleanup(),
        // which — via flushQueuedSendIfEligible() — may synchronously append
        // a second `.user` turn right here if the user queued a follow-up
        // message while this run was still streaming. That auto-flushed
        // turn belongs to the NEXT run, not this one; counting it here made
        // the `== 1` check below fail for the run that actually just
        // finished its first exchange, and since `llmTitleAttempted` is only
        // ever set true inside that (now permanently unreachable) guard,
        // auto-titling silently never fired again for the rest of the
        // session. Anything queued lands strictly after the assistant turn
        // this run just completed, so it can't affect which assistant turn
        // `turns.last(where: role == .assistant)` finds below.
        let isFirstUserExchange = turns.filter { $0.role == .user }.count == 1

        completeRunCleanup()

        guard persistConversationArtifacts, let context else { return }

        if let lastAssistant = turns.last(where: { $0.role == .assistant }),
            !lastAssistant.contentIsBlank || lastAssistant.hasRenderableThinking
        {
            lastCompletedAssistantTurnId = lastAssistant.id
        }

        let assistantContent = turns.last(where: { $0.role == .assistant })?.content

        #if OSAURUS_INTEL
        // Smart title from the core model after the first exchange. Upstream
        // never had model-generated titles (first-line only); this adds them
        // on Intel. One-shot, async, non-blocking; first-line title stays as
        // the fallback if the model call fails. Gated by
        // `ChatConfiguration.autoGenerateChatTitles` (upstream 5bb946f7's
        // opt-out toggle in Settings → Chat), default-on to preserve
        // pre-existing behavior.
        if ChatConfiguration.shared.autoGenerateChatTitles,
            let sid = sessionId, !llmTitleAttempted,
            isFirstUserExchange,
            let assistant = assistantContent, !assistant.isEmpty
        {
            llmTitleAttempted = true
            generateLLMTitle(
                userText: context.userContent, assistantText: assistant, sessionId: sid)
        }
        #endif

        let agentUUID = UUID(uuidString: context.memoryAgentId) ?? Agent.defaultId
        let memoryOff = AgentManager.shared.effectiveMemoryDisabled(for: agentUUID)

        if !memoryOff, context.hasContent, let sid = sessionId {
            let convId = sid.uuidString
            let aid = context.memoryAgentId
            let chunkIdx = turns.count
            let userChunkIndex = chunkIdx - 1
            let conversationTitle = title
            let userContent = context.userContent
            let userTokenCount = TokenEstimator.estimate(userContent)

            // Move the SQL insert + Vectura indexing off the main
            // actor. Previously `db.insertTranscriptTurn` was called
            // synchronously here (against the database's serial
            // queue), which blocked the chat view's main-thread
            // post-stream cleanup. The companion Vectura calls were
            // already detached.
            Task.detached {
                let db = MemoryDatabase.shared
                do {
                    try db.insertTranscriptTurn(
                        agentId: aid,
                        conversationId: convId,
                        chunkIndex: userChunkIndex,
                        role: "user",
                        content: userContent,
                        tokenCount: userTokenCount,
                        title: conversationTitle
                    )
                } catch {
                    MemoryLogger.database.warning("Failed to insert user transcript turn: \(error)")
                }
                let userTurn = TranscriptTurn(
                    conversationId: convId,
                    chunkIndex: userChunkIndex,
                    role: "user",
                    content: userContent,
                    tokenCount: userTokenCount,
                    agentId: aid
                )
                await MemorySearchService.shared.indexTranscriptTurn(userTurn)
                // Project memory (Phase 5): additively mirror the same turn
                // into the project's shared namespace, on top of the
                // agent-namespace write above.
                if let projectId = context.projectId {
                    await MemoryService.shared.mirrorTranscriptToProject(
                        projectId: projectId,
                        conversationId: convId,
                        chunkIndex: userChunkIndex,
                        role: "user",
                        content: userContent,
                        tokenCount: userTokenCount,
                        title: conversationTitle
                    )
                }
            }

            if let assistantContent, !assistantContent.isEmpty {
                let assistantTokenCount = TokenEstimator.estimate(assistantContent)
                Task.detached {
                    let db = MemoryDatabase.shared
                    do {
                        try db.insertTranscriptTurn(
                            agentId: aid,
                            conversationId: convId,
                            chunkIndex: chunkIdx,
                            role: "assistant",
                            content: assistantContent,
                            tokenCount: assistantTokenCount,
                            title: conversationTitle
                        )
                    } catch {
                        MemoryLogger.database.warning("Failed to insert assistant transcript turn: \(error)")
                    }
                    let assistantTurn = TranscriptTurn(
                        conversationId: convId,
                        chunkIndex: chunkIdx,
                        role: "assistant",
                        content: assistantContent,
                        tokenCount: assistantTokenCount,
                        agentId: aid
                    )
                    await MemorySearchService.shared.indexTranscriptTurn(assistantTurn)
                    if let projectId = context.projectId {
                        await MemoryService.shared.mirrorTranscriptToProject(
                            projectId: projectId,
                            conversationId: convId,
                            chunkIndex: chunkIdx,
                            role: "assistant",
                            content: assistantContent,
                            tokenCount: assistantTokenCount,
                            title: conversationTitle
                        )
                    }
                }
            }
        }

        if !memoryOff, context.hasContent {
            let formatter = Self.sessionDateFormatter
            formatter.timeZone = .current
            let today = formatter.string(from: Date())
            Task.detached {
                await MemoryService.shared.bufferTurn(
                    userMessage: context.userContent,
                    assistantMessage: assistantContent,
                    agentId: context.memoryAgentId,
                    conversationId: context.memoryConversationId,
                    sessionDate: today,
                    projectId: context.projectId
                )
            }
        }
    }

    /// Resolve the execution mode for the next send. When sandbox is on we
    /// `await registerTools` so the registry reflects the post-provision
    /// state before `resolveExecutionMode` reads it. The single resolver on
    /// `ToolRegistry` then applies the priority rule (sandbox > folder >
    /// none) and decides whether sandbox tools actually came online.
    func prepareChatExecutionMode(agentId: UUID) async -> ExecutionMode {
        let autonomous = AgentManager.shared.effectiveAutonomousExec(for: agentId)?.enabled == true
        if autonomous {
            await SandboxToolRegistrar.shared.registerTools(for: agentId)
        }
        return ToolRegistry.shared.resolveExecutionMode(
            folderContext: FolderContextService.shared.currentContext,
            autonomousEnabled: autonomous
        )
    }

    // MARK: - Private Helpers

    /// Processes the streaming delta loop from the chat engine, updating the given
    /// assistant turn and UI state. Returns any parsed tool invocations and the
    /// final updated assistant turn.
    private func processStreamDeltas(
        stream: AsyncThrowingStream<String, Error>,
        assistantTurn: ChatTurn,
        runId: UUID,
        streamStartTime: Date,
        ttftTrace: TTFTTrace?,
        selectedModel: String?
    ) async throws -> (invocations: [ServiceToolInvocation], finalTurn: ChatTurn) {
        var currentTurn = assistantTurn
        var uiDeltaCount = 0
        var firstDeltaTime: Date?
        // Throttle key for streaming tool-call argument rebuilds.
        var lastToolArgRebuildAt: Date = .distantPast
        // Throttle key to ensure the MainActor runloop gets a turn
        // to render SwiftUI updates even if the AsyncStream buffer
        // is saturated by a fast producer.
        var lastRunloopYieldAt: Date = .distantPast

        // Rolling tok/s estimator. Replaces the previous "single-final-
        // average" pattern that produced two visible artefacts:
        //
        //   1. Short responses appeared slow because the average included
        //      first-token latency + reasoning-parser stamp resolution
        //      (model warmup costs amortised over only ~100 tokens).
        //   2. Reasoning ON vs reasoning OFF on the same model showed
        //      noticeably different numbers — same decode rate, but the
        //      reasoning preamble's higher token count diluted setup costs
        //      so the AVERAGE looked higher with thinking on.
        //
        // The rolling rate skips a brief warm-up window then reports the
        // sliding-window decode rate (steady-state). It counts content,
        // reasoning, and tool-arg tokens uniformly so the visible value is
        // invariant across {thinking on/off, tools yes/no, local/remote}.
        // See `RollingTokenRate` doc for the window-choice rationale.
        var rollingRate = RollingTokenRate()
        // Throttle UI updates of the live rolling rate. The stream may
        // produce 100+ deltas/sec; clamping rate refreshes to ~5Hz keeps
        // SwiftUI repaints cheap without losing visible smoothness.
        var lastRateRefreshAt: Date = .distantPast

        // Reasoning text arrives as `StreamingReasoningHint` sentinel deltas
        // emitted by `GenerationEventMapper` (local MLX) or
        // `RemoteProviderService` (remote providers). The processor's
        // `receiveReasoning` routes it into the Think panel.
        var processor = StreamingDeltaProcessor(turn: currentTurn) { [weak self] in
            self?.rebuildVisibleBlocks()
        }

        // The engine surfaces parsed tool calls by *throwing* a
        // `ServiceToolInvocation` (or `ServiceToolInvocations`) at end-of-
        // stream. Catch them so this function can return them as data —
        // letting the throw escape would surface as an "Error: …
        // ServiceToolInvocation error 1" string in the UI.
        var capturedInvocations: [ServiceToolInvocation] = []

        debugLog("send: got stream, entering delta loop")
        do {
            for try await delta in stream {
                if !isRunActive(runId) {
                    processor.finalize()
                    return ([], currentTurn)
                }
                // Server-side tool call complete: add the call card + result turn to the chat log
                if let done = StreamingToolHint.decodeDone(delta) {
                    processor.finalize()
                    let call = ToolCall(
                        id: done.callId,
                        type: "function",
                        function: ToolCallFunction(name: done.name, arguments: done.arguments)
                    )
                    currentTurn.pendingToolName = nil
                    currentTurn.clearPendingToolArgs()
                    if currentTurn.toolCalls == nil { currentTurn.toolCalls = [] }
                    currentTurn.toolCalls!.append(call)
                    currentTurn.toolResults[done.callId] = done.result
                    let toolTurn = ChatTurn(role: .tool, content: done.result)
                    toolTurn.toolCallId = done.callId
                    let newAssistantTurn = ChatTurn(role: .assistant, content: "")
                    turns.append(contentsOf: [toolTurn, newAssistantTurn])
                    currentTurn = newAssistantTurn
                    processor = StreamingDeltaProcessor(
                        turn: newAssistantTurn
                    ) { [weak self] in self?.rebuildVisibleBlocks() }
                    rebuildVisibleBlocks()
                    continue
                }
                if let toolName = StreamingToolHint.decode(delta) {
                    currentTurn.pendingToolName = toolName.isEmpty ? nil : toolName
                    rebuildVisibleBlocks()
                    continue
                }
                if let argFragment = StreamingToolHint.decodeArgs(delta) {
                    currentTurn.appendToolArgFragment(argFragment)
                    // Always rebuild for the first few fragments so the chip
                    // appears immediately; afterwards cap at ~12 rebuilds/sec
                    // so the table stays responsive during long arg streams
                    // without hiding chunky provider deltas.
                    let count = currentTurn.pendingToolArgFragmentCount
                    let now = Date()
                    if count <= 3 || now.timeIntervalSince(lastToolArgRebuildAt) >= 0.08 {
                        lastToolArgRebuildAt = now
                        rebuildVisibleBlocks()
                    }
                } else if let stats = StreamingStatsHint.decode(delta) {
                    // Final stats from vmlx — captured for the post-loop
                    // stamp. We DELIBERATELY do NOT overwrite the rolling
                    // rate here: vmlx's `tokensPerSecond` is the full-
                    // generation average, which has the same first-token-
                    // amortisation problem the rolling rate was added to
                    // fix. The rolling rate's steady-state value is used
                    // for the visible bubble after the stream ends; vmlx's
                    // tokenCount is preserved as the authoritative count.
                    currentTurn.generationTokenCount = stats.tokenCount
                    // Vmlx tells us the model never closed `</think>` before
                    // EOS / max_tokens. Persist on the turn so the bubble
                    // renderer can surface a one-line banner suggesting
                    // the user toggle Disable Thinking for this prompt class.
                    currentTurn.unclosedReasoning = stats.unclosedReasoning
                } else if let reasoning = StreamingReasoningHint.decode(delta) {
                    let now = Date()
                    if firstDeltaTime == nil {
                        firstDeltaTime = now
                        ttftTrace?.set("first_chunk_ms", Int(now.timeIntervalSince(streamStartTime) * 1000))
                        ttftTrace?.mark("first_text_delta")
                        ttftTrace?.set("model", selectedModel ?? "unknown")
                        ttftTrace?.emit()
                    }
                    // Reasoning tokens count toward the rolling rate so
                    // thinking-ON and thinking-OFF show the same decode
                    // rate at steady state. See RollingTokenRate doc.
                    let tokens = ContextBudgetManager.estimateTokens(for: reasoning)
                    rollingRate.observe(tokens: tokens, at: now)
                    refreshLiveRate(
                        rolling: &rollingRate,
                        lastRefreshAt: &lastRateRefreshAt,
                        now: now,
                        turn: currentTurn
                    )
                    processor.receiveReasoning(reasoning)
                } else if !delta.isEmpty {
                    let now = Date()
                    if firstDeltaTime == nil {
                        firstDeltaTime = now
                        ttftTrace?.set("first_chunk_ms", Int(now.timeIntervalSince(streamStartTime) * 1000))
                        ttftTrace?.mark("first_text_delta")
                        ttftTrace?.set("model", selectedModel ?? "unknown")
                        ttftTrace?.emit()
                    }
                    uiDeltaCount += 1
                    // Content delta — counted uniformly with reasoning.
                    let tokens = ContextBudgetManager.estimateTokens(for: delta)
                    rollingRate.observe(tokens: tokens, at: now)
                    refreshLiveRate(
                        rolling: &rollingRate,
                        lastRefreshAt: &lastRateRefreshAt,
                        now: now,
                        turn: currentTurn
                    )
                    processor.receiveDelta(delta)
                }

                // Hand the main run loop a turn so SwiftUI can actually paint
                // any @Published mutations we just performed. Without this,
                // when many deltas land back-to-back (e.g. Venice tool args or
                // fast text streams) the consumer task monopolises the MainActor
                // and the render pass never fires — the UI appears to stall
                // mid-stream until the loop finishes. Gated to ~12 yields/sec
                // to avoid slowing down the stream with excessive 1ms sleeps.
                let now = Date()
                if now.timeIntervalSince(lastRunloopYieldAt) >= 0.08 {
                    lastRunloopYieldAt = now
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
            }
        } catch let invs as ServiceToolInvocations {
            capturedInvocations = invs.invocations
        } catch let inv as ServiceToolInvocation {
            capturedInvocations = [inv]
        }

        // Flush any remaining buffered content (including partial tags)
        processor.finalize()

        if let first = firstDeltaTime {
            currentTurn.timeToFirstToken = first.timeIntervalSince(streamStartTime)
            // Stamp the steady-state tok/s. Single source of truth across
            // local-MLX, remote-API, with-tools, and thinking-on/off paths
            // — the rolling rate observed every text-bearing delta during
            // the loop above. Falls back to full-generation average if the
            // response was too short for the warm-up to elapse (see
            // `RollingTokenRate.finalRate`).
            currentTurn.generationTokensPerSecond = rollingRate.finalRate()
            // Token count: prefer vmlx's authoritative count (already
            // assigned in the stats sentinel branch above) — only fall back
            // to our chars/4 estimate if the stats sentinel never fired
            // (remote provider paths that don't surface vmlx stats).
            if currentTurn.generationTokenCount == nil, rollingRate.totalTokens > 0 {
                currentTurn.generationTokenCount = rollingRate.totalTokens
            }
        }
        // Stamp stream-end wall-clock for opt-in export timing. Set
        // unconditionally so cancelled and zero-token streams still get
        // a timestamp — the token count tells the consumer how much was
        // actually generated.
        currentTurn.completedAt = Date()

        let totalTime = Date().timeIntervalSince(streamStartTime)
        print(
            "[Osaurus][UI] Stream consumption completed: \(uiDeltaCount) deltas in \(String(format: "%.2f", totalTime))s, final contentLen=\(currentTurn.contentLength)"
        )

        return (capturedInvocations, currentTurn)
    }

    func send(_ text: String, attachments: [Attachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = !trimmed.isEmpty || !attachments.isEmpty
        let isRegeneration = !hasContent && !turns.isEmpty
        guard hasContent || isRegeneration else { return }
        guard activeRunId == nil, !isStreaming else {
            #if OSAURUS_INTEL
            print(
                "[ChatSession] send BLOCKED by gate: activeRunId="
                    + "\(String(describing: activeRunId)) isStreaming=\(isStreaming) "
                    + "sessionId=\(String(describing: sessionId))"
            )
            #endif
            return
        }

        // Fresh run: a previous stop() may have left the flag true. The
        // auto-flush in completeRunCleanup keys off this, so clear it
        // before the new run can finalize.
        stopRequested = false

        // Any new user input clears a prior completion banner — we're
        // moving on to a follow-up. Clarify prompts (when active) live
        // in the bottom-pinned overlay with their own embedded input;
        // the main input bar is dimmed while a prompt is mounted, so
        // the user can't normally reach this path with a clarify
        // pending. The `drainAll()` here is defensive: if a prompt is
        // somehow still queued, dismiss it before sending so the new
        // turn doesn't race a stale overlay resolution.
        lastCompletionSummary = nil
        if promptQueue.current != nil {
            promptQueue.drainAll()
        }
        // Resume from any prior clarify pause BEFORE the new run starts so
        // the BTM streaming-state sink sees `.awaitingClarification`
        // cleared and the next streaming tick transitions the task back
        // to `.running` cleanly. Redundant nil → nil writes are
        // collapsed downstream by `removeDuplicates`.
        awaitingClarify = nil

        if hasContent {
            turns.append(ChatTurn(role: .user, content: trimmed, attachments: attachments))
            isDirty = true
            rebuildVisibleBlocks()

            // Immediately save new session so it appears in sidebar
            if sessionId == nil {
                sessionId = UUID()
                createdAt = Date()
                updatedAt = Date()
                isDirty = false  // Already set updatedAt
                // Auto-generate title from first user message
                let turnData = turns.map { ChatTurnData(from: $0) }
                title = ChatSessionData.generateTitle(from: turnData)
                let data = toSessionData()
                ChatSessionsManager.shared.save(data)
                onSessionChanged?()
            }
        }

        let memoryAgentId = (agentId ?? Agent.defaultId).uuidString
        let memoryConversationId = (sessionId ?? UUID()).uuidString

        let runId = UUID()
        beginRun(
            runId,
            context: RunContext(
                hasContent: hasContent,
                userContent: trimmed,
                memoryAgentId: memoryAgentId,
                memoryConversationId: memoryConversationId,
                projectId: projectId
            )
        )

        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.isRunActive(runId) else {
                #if OSAURUS_INTEL
                print(
                    "[ChatSession] run \(runId) went INACTIVE before start "
                        + "(activeRunId=\(String(describing: self.activeRunId)) "
                        + "cancelled=\(Task.isCancelled)) — aborting, no reply"
                )
                #endif
                return
            }
            debugLog("send: task started runId=\(runId) model=\(self.selectedModel ?? "nil")")
            lastStreamError = nil
            isStreaming = true
            ServerController.signalGenerationStart()
            defer {
                finalizeRun(runId: runId, persistConversationArtifacts: true)
            }

            var assistantTurn = ChatTurn(role: .assistant, content: "")
            turns.append(assistantTurn)
            // Must refresh block memoizer before first delta — otherwise visibleBlocks stays
            // user-only while isStreaming is true and the table early-returns without assistant rows.
            rebuildVisibleBlocks()
            #if DEBUG
                let ttftTrace: TTFTTrace? = TTFTTrace()
            #else
                let ttftTrace: TTFTTrace? = nil
            #endif
            do {
                let engine = chatEngineFactory()
                let chatCfg = ChatConfigurationStore.load()

                // MARK: - Capability Setup
                let effectiveAgentId = agentId ?? Agent.defaultId
                ttftTrace?.mark("prepare_exec_mode_start")
                let executionMode = await prepareChatExecutionMode(agentId: effectiveAgentId)
                ttftTrace?.mark("prepare_exec_mode_done")
                guard isRunActive(runId) else { return }

                let priorUserMessages: [ChatMessage] = turns.compactMap { t in
                    guard t.role == .user, !t.contentIsEmpty else { return nil }
                    return ChatMessage(role: "user", content: t.content)
                }

                // Reuse the per-session preflight + capabilities_load union
                // on subsequent sends so we skip the LLM-based selection.
                // First, ask the store to drop the cache if the
                // (executionMode, toolMode) fingerprint flipped since the
                // last turn — otherwise stale dynamically-loaded tools or
                // an empty manual-mode preflight would leak into the new
                // mode's schema.
                let liveToolMode = AgentManager.shared.effectiveToolSelectionMode(for: effectiveAgentId)
                let liveFingerprint = SessionToolState.fingerprint(
                    executionMode: executionMode,
                    toolMode: liveToolMode
                )
                let cachedSession: SessionToolState?
                if let sid = sessionId {
                    let key = sessionStateKey(sid)
                    await SessionToolStateStore.shared.invalidateIfFingerprintChanged(
                        key,
                        liveFingerprint: liveFingerprint
                    )
                    cachedSession = await SessionToolStateStore.shared.get(key)
                } else {
                    cachedSession = nil
                }
                let context = await SystemPromptComposer.composeChatContext(
                    agentId: effectiveAgentId,
                    executionMode: executionMode,
                    model: selectedModel,
                    query: trimmed,
                    messages: priorUserMessages,
                    toolsDisabled: chatCfg.disableTools,
                    cachedPreflight: cachedSession?.initialPreflight,
                    additionalToolNames: cachedSession?.loadedToolNames ?? [],
                    frozenAlwaysLoadedNames: cachedSession?.initialAlwaysLoadedNames,
                    trace: ttftTrace,
                    projectId: projectId
                )
                guard isRunActive(runId) else { return }

                var sys = context.prompt

                // Plugin-dispatched tasks (host->dispatch) carry their
                // source plugin id on the session. Append that plugin's
                // instructions so the dispatched chat sees the same
                // contract the plugin would have published via
                // host->complete. Mirrors `PluginHostAPI.prepareInference`
                // through the shared `PluginInstructionsResolver`. Without
                // this, plugin manifest `instructions` are silently
                // dropped on the dispatch path, leaving the model
                // unaware of plugin-specific contracts (e.g. Telegram's
                // `[reply_token …]` / `reply` / `reply_typing` flow).
                if let pid = sourcePluginId,
                    let pluginInstructions = PluginInstructionsResolver.instructions(
                        pluginId: pid,
                        agentId: agentId
                    )
                {
                    sys = sys.isEmpty ? pluginInstructions : sys + "\n\n" + pluginInstructions
                }

                // Inject one-off skill if the user selected one via slash command
                if let skillId = pendingOneOffSkillId {
                    pendingOneOffSkillId = nil
                    if let skill = SkillManager.shared.skill(for: skillId) {
                        let section = await SkillManager.shared.buildFullInstructions(for: skill)
                        sys += "\n\n## Active Skill: \(skill.name)\n\n\(section)"
                    }
                }

                var toolSpecs = context.tools
                let isManualTools = liveToolMode == .manual
                cachedContext = context

                // Persist the (possibly fresh) preflight + always-loaded
                // snapshot back onto the session so the next send reuses
                // both — preflight skips the LLM call, the always-loaded
                // snapshot freezes the schema against tools that register
                // mid-session. Preserves any capabilities_load names
                // already accumulated this session. Stamp the live
                // fingerprint so the invalidation rule above can detect
                // a flip on the next turn.
                if let sid = sessionId, cachedSession == nil {
                    await SessionToolStateStore.shared.setInitial(
                        sessionStateKey(sid),
                        preflight: context.preflight,
                        alwaysLoadedNames: context.alwaysLoadedNames,
                        fingerprint: liveFingerprint
                    )
                }

                // Manual mode ignores the preflight in `resolveTools`, so
                // surfacing a preflight panel from a stale auto-mode cache
                // would lie to the user about which tools the model is
                // actually getting. Gate on the live tool mode.
                if !isManualTools, !context.preflightItems.isEmpty {
                    assistantTurn.preflightCapabilities = context.preflightItems
                }

                budgetTracker.snapshot(context: context)

                let effectiveMaxTokensForAgent = AgentManager.shared.effectiveMaxTokens(for: effectiveAgentId)

                /// Convert a single turn to a ChatMessage (returns nil if should be skipped)
                @MainActor
                func turnToMessage(_ t: ChatTurn, isLastTurn: Bool) -> ChatMessage? {
                    switch t.role {
                    case .assistant:
                        // Skip the last assistant turn if it's empty (it's the streaming placeholder)
                        if isLastTurn && t.contentIsBlank && t.thinkingIsBlank && t.toolCalls == nil {
                            return nil
                        }

                        if t.contentIsBlank && t.thinkingIsBlank && (t.toolCalls == nil || t.toolCalls!.isEmpty) {
                            return nil
                        }

                        let content: String? = t.contentIsBlank ? nil : t.content
                        // DeepSeek's thinking mode requires echoing the
                        // previous `reasoning_content` on follow-ups
                        // (issue #959). `RemoteProviderService` strips it
                        // again for providers that don't need it.
                        let reasoning: String? = t.thinkingIsBlank ? nil : t.thinking

                        return ChatMessage(
                            role: "assistant",
                            content: content,
                            tool_calls: t.toolCalls,
                            tool_call_id: nil,
                            reasoning_content: reasoning
                        )
                    case .tool:
                        return ChatMessage(
                            role: "tool",
                            content: t.content,
                            tool_calls: nil,
                            tool_call_id: t.toolCallId
                        )
                    case .user:
                        return Self.buildUserChatMessage(
                            content: t.content,
                            attachments: t.attachments,
                            supportsImages: selectedModelSupportsImages,
                            supportsAudio: selectedModelSupportsAudio,
                            supportsVideo: selectedModelSupportsVideo
                        )
                    default:
                        return ChatMessage(role: t.role.rawValue, content: t.content)
                    }
                }

                @MainActor
                func buildMessages() -> [ChatMessage] {
                    var msgs: [ChatMessage] = []
                    if !sys.isEmpty { msgs.append(ChatMessage(role: "system", content: sys)) }

                    for (index, t) in turns.enumerated() {
                        let isLastTurn = index == turns.count - 1
                        if let msg = turnToMessage(t, isLastTurn: isLastTurn) {
                            msgs.append(msg)
                        }
                    }

                    return msgs
                }

                let maxAttempts = max(chatCfg.maxToolAttempts ?? 15, 1)
                let toolBudgetWarningThreshold = 3
                var attempts = 0
                var reachedToolLimit = false
                var pendingBudgetNotice: String?
                // Transient stream errors (e.g. provider closes connection
                // mid-tool-args, see `RemoteProviderService` truncation
                // detection) shouldn't immediately surface to the user — they
                // tend to retry cleanly. We retry the same iteration up to
                // `maxTransientRetries` times before giving up. The counter
                // is reset whenever a stream finishes naturally so unrelated
                // future failures get a fresh budget.
                let maxTransientRetries = 2
                var transientRetries = 0
                let effectiveTemp = AgentManager.shared.effectiveTemperature(for: effectiveAgentId)

                ttftTrace?.mark("pre_ttft_done")

                outer: while attempts < maxAttempts {
                    attempts += 1
                    ttftTrace?.mark("build_messages_start")
                    var msgs = buildMessages()
                    ttftTrace?.mark("build_messages_done")
                    ttftTrace?.set("messageCount", msgs.count)
                    ttftTrace?.set("conversationTurns", turns.count)

                    #if DEBUG
                        // Dump full prompt to debug log for TTFT analysis
                        if attempts == 1 {
                            var promptDump = "═══ FULL PROMPT DUMP ═══\n"
                            for (i, m) in msgs.enumerated() {
                                promptDump += "── [\(i)] role=\(m.role) chars=\(m.content?.count ?? 0) ──\n"
                                promptDump += (m.content ?? "(nil)") + "\n"
                            }
                            if let tools = toolSpecs.isEmpty ? nil : toolSpecs {
                                promptDump += "── TOOLS (\(tools.count)) ──\n"
                                for t in tools {
                                    promptDump += "  - \(t.function.name): \(t.function.description ?? "")\n"
                                }
                            }
                            promptDump += "═══ END PROMPT DUMP ═══"
                            debugLog(promptDump)
                        }
                    #endif
                    if let notice = pendingBudgetNotice {
                        msgs.append(ChatMessage(role: "user", content: notice))
                        pendingBudgetNotice = nil
                    }

                    // Memory now lives on the latest user message instead of
                    // the system prompt — keeps the system prefix byte-stable
                    // across turns so the MLX paged KV cache can reuse the
                    // entire conversation prefix.
                    SystemPromptComposer.injectMemoryPrefix(context.memorySection, into: &msgs)

                    let convTokens =
                        msgs
                        .filter { $0.role != "system" }
                        .reduce(0) { $0 + ContextBudgetManager.estimateTokens(for: $1.content) }
                    budgetTracker.updateConversation(tokens: convTokens, finishedOutputTurn: assistantTurn)
                    var req = ChatCompletionRequest(
                        model: selectedModel ?? "default",
                        messages: msgs,
                        temperature: effectiveTemp,
                        max_tokens: effectiveMaxTokensForAgent,
                        stream: true,
                        top_p: chatCfg.topPOverride,
                        frequency_penalty: nil,
                        presence_penalty: nil,
                        stop: nil,
                        n: nil,
                        tools: toolSpecs.isEmpty ? nil : toolSpecs,
                        tool_choice: toolSpecs.isEmpty ? nil : .auto,
                        session_id: sessionId?.uuidString
                    )
                    req.samplingParametersAreImplicit = true
                    req.modelOptions = activeModelOptions.isEmpty ? nil : activeModelOptions
                    req.ttftTrace = ttftTrace
                    debugLog(
                        "send: attempt=\(attempts) model=\(req.model) tools=\(req.tools?.count ?? 0) sessionId=\(req.session_id ?? "nil")"
                    )
                    // Cache-fingerprint diagnostic: one `[Cache]` log line +
                    // matching TTFT fields per send so we can audit KV reuse
                    // without instrumenting MLX. Helper lives on the store
                    // so the turn counter + previous-hint comparison sit
                    // next to the state they describe.
                    if let sid = sessionId {
                        await SessionToolStateStore.shared.recordSend(
                            sessionId: sessionStateKey(sid),
                            cacheHint: context.cacheHint,
                            trace: ttftTrace
                        )
                    }
                    // Tool calls parsed from this completion. Populated by
                    // either the single-throw or batch-throw catch below; the
                    // shared per-tool block then iterates through it.
                    var pendingInvocations: [ServiceToolInvocation] = []
                    do {
                        let streamStartTime = Date()
                        let (invocations, finalTurn) = try await processStreamDeltas(
                            stream: try await engine.streamChat(request: req),
                            assistantTurn: assistantTurn,
                            runId: runId,
                            streamStartTime: streamStartTime,
                            ttftTrace: ttftTrace,
                            selectedModel: selectedModel
                        )
                        assistantTurn = finalTurn
                        pendingInvocations = invocations

                        // Stream finished naturally without a tool call — reset
                        // the transient-retry budget so a future, unrelated
                        // failure later in the conversation gets a fresh
                        // allowance.
                        if pendingInvocations.isEmpty {
                            transientRetries = 0
                            break  // finished normally
                        }
                    } catch let error as RemoteProviderServiceError {
                        // Transient provider-side stream errors — most commonly
                        // mid-tool-args truncation flagged by
                        // `RemoteProviderService.makeToolInvocation`'s
                        // `wasRepaired` guard. Silently retry the same
                        // iteration up to `maxTransientRetries` times before
                        // surfacing to the user; the model can't see what it
                        // actually streamed last time so it would just retry
                        // with the same broken args.
                        if transientRetries < maxTransientRetries {
                            transientRetries += 1
                            attempts -= 1  // don't charge this against the tool-iteration budget
                            print(
                                "[Osaurus] Transient stream error (retry \(transientRetries)/\(maxTransientRetries)): \(error.localizedDescription)"
                            )
                            // Roll back any partial UI state from the failed
                            // attempt so the retry starts clean.
                            assistantTurn.pendingToolName = nil
                            assistantTurn.clearPendingToolArgs()
                            rebuildVisibleBlocks()
                            continue outer
                        }
                        throw error
                    }

                    // Shared per-tool processing for both single and batched
                    // catches. Iterates through every parsed tool call in
                    // order; on any execution rejection we break the outer
                    // loop just like the original single-tool code did.
                    if pendingInvocations.isEmpty {
                        break  // stream finished without surfacing any tool call
                    }

                    var rejectedDuringBatch = false
                    invocations: for inv in pendingInvocations {
                        guard isRunActive(runId) else { break outer }

                        let callId: String
                        if let preservedId = inv.toolCallId, !preservedId.isEmpty {
                            callId = preservedId
                        } else {
                            let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                            callId = "call_" + String(raw.prefix(24))
                        }
                        let call = ToolCall(
                            id: callId,
                            type: "function",
                            function: ToolCallFunction(name: inv.toolName, arguments: inv.jsonArguments),
                            geminiThoughtSignature: inv.geminiThoughtSignature
                        )
                        assistantTurn.pendingToolName = nil
                        assistantTurn.clearPendingToolArgs()
                        if assistantTurn.toolCalls == nil { assistantTurn.toolCalls = [] }
                        assistantTurn.toolCalls!.append(call)

                        // Build the matching tool-result turn for this call.
                        // Every assistant `tool_use` MUST be paired with a
                        // tool turn before the loop yields control —
                        // Anthropic's Messages API rejects subsequent sends
                        // otherwise ("tool_use ids were found without
                        // tool_result blocks immediately after"). This helper
                        // is shared by the agent-loop intercepts (`complete`,
                        // `clarify`) and the normal post-execution path so
                        // there's only one place that gets the pairing right.
                        @discardableResult
                        func recordToolTurn(_ result: String) -> ChatTurn {
                            assistantTurn.toolResults[callId] = result
                            let toolTurn = ChatTurn(role: .tool, content: result)
                            toolTurn.toolCallId = callId
                            return toolTurn
                        }

                        // Materialise the tool-call row BEFORE we await
                        // execute(...). Without this the chat skips
                        // straight from `pendingToolCall` (args still
                        // streaming) to `toolCallGroup` with the result
                        // already attached — `NativeToolCallRowView`
                        // never gets a chance to render with
                        // `item.result == nil`, so its inline live-
                        // streaming pane (TerminalDisplayView) never mounts
                        // for sandbox_exec / shell_run. Rebuilding here
                        // emits the row with a nil result; the row
                        // subscribes to LiveExecRegistry and starts
                        // streaming the moment the tool body registers
                        // its sink.
                        rebuildVisibleBlocks()

                        // Execute tool and append hidden tool result turn
                        var resultText: String
                        do {
                            // Log tool execution start
                            let truncatedArgs = inv.jsonArguments.prefix(200)
                            print(
                                "[Osaurus][Tool] Executing: \(inv.toolName) with args: \(truncatedArgs)\(inv.jsonArguments.count > 200 ? "..." : "")"
                            )

                            if executionMode.usesSandboxTools {
                                await SandboxToolRegistrar.shared.registerTools(for: effectiveAgentId)
                                if !isRunActive(runId) { break outer }
                            }

                            // Bind the session id so the unified Chat agent
                            // tools (`todo`, etc.) can address per-session
                            // state in their stores. Falls back to a stable
                            // string when no session has been created yet so
                            // brand-new chats still get a todo store entry.
                            let sessionIdForTools =
                                sessionId?.uuidString ?? "chatwindow-\(ObjectIdentifier(self).hashValue)"
                            resultText = try await ChatExecutionContext.$currentAgentId.withValue(effectiveAgentId) {
                                try await ChatExecutionContext.$currentSessionId.withValue(sessionIdForTools) {
                                    try await ChatExecutionContext.$currentAssistantTurnId.withValue(assistantTurn.id) {
                                        try await ChatExecutionContext.$currentToolCallId.withValue(callId) {
                                            try await ToolRegistry.shared.execute(
                                                name: inv.toolName,
                                                argumentsJSON: inv.jsonArguments
                                            )
                                        }
                                    }
                                }
                            }
                            if !isRunActive(runId) { break outer }

                            // Agent-loop intercepts: `complete` and `clarify`
                            // end the iteration loop. `todo` already wrote
                            // into AgentTodoStore via TaskLocal; the session
                            // observer mirrors it into the inline UI block.
                            //
                            // CRITICAL: gate the inline UI on whether the
                            // tool result is a success envelope. The previous
                            // implementation pulled `summary` straight from
                            // the JSON arguments and surfaced it regardless
                            // of whether `CompleteTool.execute` rejected it
                            // for being a placeholder ("done", "looks good").
                            // That let the inline completion banner show a
                            // rejected summary as if the loop had ended
                            // cleanly. We now only intercept when the result
                            // is a success envelope; on rejection the loop
                            // continues so the model sees the failure and
                            // retries with a real summary.
                            if inv.toolName == "complete" {
                                if !ToolEnvelope.isError(resultText) {
                                    self.lastCompletionSummary =
                                        Self.parseCompleteSummary(from: inv.jsonArguments) ?? resultText
                                    // Drain any pending prompts so a stale
                                    // clarify card doesn't sit on top of the
                                    // completion banner.
                                    self.promptQueue.drainAll()
                                    turns.append(recordToolTurn(resultText))
                                    rebuildVisibleBlocks()
                                    break outer
                                }
                                // Fall through — let the model see the
                                // failure envelope and try again with a
                                // proper summary.
                            }
                            if inv.toolName == "clarify" {
                                if !ToolEnvelope.isError(resultText),
                                    let payload = Self.parseClarifyPayload(from: inv.jsonArguments)
                                {
                                    // Build a ClarifyPromptState bound to
                                    // `self.send(...)` so the user's answer
                                    // dispatches as the next user turn
                                    // through the existing chat send path.
                                    // The agent loop ends here; the model
                                    // resumes on the next send with the
                                    // answer in history.
                                    turns.append(recordToolTurn(resultText))
                                    rebuildVisibleBlocks()
                                    // Surface the parsed payload on the
                                    // session BEFORE breaking the loop so
                                    // the BackgroundTaskManager observer
                                    // sees the clarify state ahead of the
                                    // streaming-end tick — that ordering
                                    // is what gates the COMPLETED-suppression
                                    // path for plugin-dispatched runs.
                                    self.awaitingClarify = payload
                                    let clarifyState = ClarifyPromptState(
                                        question: payload.question,
                                        options: payload.options,
                                        allowMultiple: payload.allowMultiple,
                                        onSubmit: { [weak self] answer in
                                            self?.send(answer)
                                        }
                                    )
                                    self.promptQueue.enqueue(.clarify(clarifyState))
                                    self.lastCompletionSummary = nil
                                    break outer
                                }
                                // Fall through on failure (empty question,
                                // etc.) so the model sees the rejection.
                            }

                            // Hot-load tools injected by capabilities_load or sandbox_plugin_register.
                            // Skipped in manual mode — the user's explicit tool set is fixed.
                            if !isManualTools,
                                inv.toolName == "capabilities_load"
                                    || inv.toolName == "sandbox_plugin_register"
                            {
                                let newTools = await CapabilityLoadBuffer.shared.drain()
                                for tool in newTools {
                                    if let existing = toolSpecs.firstIndex(where: {
                                        $0.function.name == tool.function.name
                                    }) {
                                        // `capabilities_load` upgrades compact bootstrap schemas to
                                        // full schemas in-place, so the next tool iteration can use
                                        // the complete argument contract without waiting for a
                                        // fresh compose.
                                        toolSpecs[existing] = tool
                                    } else {
                                        toolSpecs.append(tool)
                                    }
                                }
                                // Persist names into the session's tool union
                                // so they survive the next compose call
                                // without re-running preflight.
                                if let sid = sessionId {
                                    let names = newTools.map { $0.function.name }
                                    let preflight = context.preflight
                                    let snapshot = context.alwaysLoadedNames
                                    await SessionToolStateStore.shared.appendLoadedTools(
                                        sessionStateKey(sid),
                                        names: names,
                                        fallbackPreflight: preflight,
                                        fallbackAlwaysLoadedNames: snapshot
                                    )
                                }
                            }

                            if inv.toolName == "share_artifact" {
                                resultText = processShareArtifactResult(
                                    toolResult: resultText,
                                    executionMode: executionMode
                                )
                                if let artifact = SharedArtifact.fromEnrichedToolResult(resultText) {
                                    await PluginManager.shared.notifyArtifactHandlers(artifact: artifact)
                                }
                            }

                            if inv.toolName == "sandbox_secret_set",
                                let prompt = SecretPromptParser.parse(resultText)
                            {
                                let stored: Bool = await withCheckedContinuation { continuation in
                                    let promptState = SecretPromptState(
                                        key: prompt.key,
                                        description: prompt.description,
                                        instructions: prompt.instructions,
                                        agentId: prompt.agentId
                                    ) { value in
                                        continuation.resume(returning: value != nil)
                                    }
                                    // Route through the shared queue so
                                    // a clarify can't pop on top of a
                                    // pending secret (and vice versa).
                                    self.promptQueue.enqueue(.secret(promptState))
                                }
                                // The overlay's dismiss closure already
                                // called `promptQueue.advance()` once
                                // the user resolved; nothing to clean
                                // up here.
                                resultText =
                                    stored
                                    ? SecretToolResult.stored(key: prompt.key)
                                    : SecretToolResult.cancelled(key: prompt.key)
                            }

                            // Log tool success (truncated result)
                            let truncatedResult = resultText.prefix(500)
                            print(
                                "[Osaurus][Tool] Success: \(inv.toolName) returned \(resultText.count) chars: \(truncatedResult)\(resultText.count > 500 ? "..." : "")"
                            )
                        } catch {
                            // Store rejection/error as the result so UI shows "Rejected" instead of hanging.
                            // The structured envelope replaces the legacy `[REJECTED] …` string so
                            // local models read a clear `{ok, kind, message, retryable}` rather than
                            // a marker they misinterpret as a sticky policy refusal. `fromError`
                            // maps FolderToolError + registry permission codes to the right `kind`
                            // so user denials, missing files, and bad arguments don't all get the
                            // same opaque `executionError` treatment.
                            let rejectionMessage = ToolEnvelope.fromError(error, tool: inv.toolName)
                            turns.append(recordToolTurn(rejectionMessage))
                            rejectedDuringBatch = true
                            break invocations  // Stop processing remaining tools in batch
                        }
                        guard isRunActive(runId) else { break outer }
                        let toolTurn = recordToolTurn(resultText)

                        // Create a new assistant turn for subsequent content
                        // This ensures tool calls and text are rendered sequentially
                        let newAssistantTurn = ChatTurn(role: .assistant, content: "")

                        // Batch both appends into a single mutation to reduce
                        // the number of @Published change signals and SwiftUI layout passes.
                        turns.append(contentsOf: [toolTurn, newAssistantTurn])
                        assistantTurn = newAssistantTurn
                        rebuildVisibleBlocks()
                    }

                    // Per-iteration budget bookkeeping (one decrement per outer
                    // iteration regardless of how many tools the batch ran).
                    if rejectedDuringBatch {
                        break outer
                    }
                    let remaining = maxAttempts - attempts
                    if remaining <= 0 {
                        reachedToolLimit = true
                    } else if remaining <= toolBudgetWarningThreshold {
                        pendingBudgetNotice =
                            "[System Notice] Tool call budget: \(remaining) of \(maxAttempts) remaining. Wrap up your current work and provide a summary."
                    }
                    continue
                }

                if reachedToolLimit && isRunActive(runId) {
                    do {
                        var finalReq = ChatCompletionRequest(
                            model: selectedModel ?? "default",
                            messages: buildMessages(),
                            temperature: effectiveTemp,
                            max_tokens: effectiveMaxTokensForAgent,
                            stream: true,
                            top_p: chatCfg.topPOverride,
                            frequency_penalty: nil,
                            presence_penalty: nil,
                            stop: nil,
                            n: nil,
                            tools: nil,
                            tool_choice: nil,
                            session_id: sessionId?.uuidString
                        )
                        finalReq.samplingParametersAreImplicit = true
                        finalReq.modelOptions = activeModelOptions.isEmpty ? nil : activeModelOptions

                        let processor = StreamingDeltaProcessor(
                            turn: assistantTurn
                        ) { [weak self] in
                            self?.rebuildVisibleBlocks()
                        }

                        let stream = try await engine.streamChat(request: finalReq)
                        for try await delta in stream {
                            if !isRunActive(runId) { break }
                            if !delta.isEmpty { processor.receiveDelta(delta) }
                        }
                        processor.finalize()
                    } catch {
                        debugLog("send: final wrap-up call failed: \(error.localizedDescription)")
                    }
                }
            } catch {
                assistantTurn.content = "Error: \(error.localizedDescription)"
                lastStreamError = error.localizedDescription
            }
        }
    }
}

/// Backs the "also delete your message" checkbox in the delete-response
/// confirmation. Observing it (rather than a plain `@State` binding) lets the
/// checkbox live inside a `ThemedAlertCenter`-presented accessory, which is
/// constructed once at present time rather than re-rendered by `ChatView`'s
/// own body. Upstream c4d9d140.
@MainActor
final class DeleteMessageOptions: ObservableObject {
    @Published var alsoDeleteUserMessage: Bool = false
}

/// Checkbox rendered as the delete-response confirmation accessory. Ticking it
/// escalates the delete from "just this response" to the whole exchange.
private struct DeleteAlsoUserMessageToggle: View {
    @Environment(\.theme) private var theme
    @ObservedObject var options: DeleteMessageOptions

    var body: some View {
        Toggle(isOn: $options.alsoDeleteUserMessage) {
            Text("Also delete my message", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: - ChatView

struct ChatView: View {
    // MARK: - Window State

    /// Per-window state container (isolates this window from shared singletons)
    @ObservedObject private var windowState: ChatWindowState

    // MARK: - Environment & State

    @Environment(\.colorScheme) private var colorScheme

    @State private var focusTrigger: Int = 0
    @State private var isPinnedToBottom: Bool = true
    @State private var scrollToBottomTrigger: Int = 0
    @State private var keyMonitor: Any?
    // Inline editing state
    @State private var editingTurnId: UUID?
    @State private var editText: String = ""
    @State private var userImagePreview: NSImage?
    // Bonjour agent connection
    @State private var pendingDiscoveredAgent: DiscoveredAgent? = nil
    // Minimap
    @State private var activeMinimapTurnId: UUID?
    // Owns the minimap's expanded state here (stable identity) so it survives the
    // AnyView erasure on the messageThread closure. (Renée, 2026-06-13.)
    @State private var isMinimapExpanded: Bool = false
    @State private var scrollToTurnId: UUID?
    @State private var scrollToTurnTrigger: Int = 0
    // In-conversation find (Cmd+F). Visibility lives on `windowState` so the
    // window-level key monitor can toggle it; query/matches are view state.
    @State private var findQuery: String = ""
    /// Ordered turn ids whose content matches `findQuery`.
    @State private var findMatchTurnIds: [UUID] = []
    @State private var findMatchIndex: Int = 0
    // What's New modal
    @State private var pendingWhatsNew: WhatsNewRelease? = nil
    @State private var showAutoSpeakPrompt: Bool = false

    /// Convenience accessor for the window's theme
    private var theme: ThemeProtocol { windowState.theme }

    /// Convenience accessor for the window ID
    private var windowId: UUID { windowState.windowId }

    /// True while any prompt overlay (secret, clarify) is mounted.
    /// Drives the dim/blur on the message thread + main input bar so
    /// the prompt visibly takes the foreground. Single source of truth
    /// is `session.promptQueue.current`.
    private var isPromptOverlayActive: Bool {
        session.promptQueue.current != nil
    }

    /// Picker items filtered to the active Bonjour provider's models when a
    /// remote agent is selected, or ALL models (local + user-configured
    /// remote providers) when no remote agent is active.
    ///
    /// Prior to this fix, the no-agent branch hid every `.remote` model
    /// from the picker — which was correct for keeping Bonjour-discovered
    /// models from leaking into the local-only view, but also suppressed
    /// manually-configured remote providers (Ollama, custom OpenAI
    /// endpoints, etc.). Since user-configured providers are always
    /// intentional, they should be visible regardless of Bonjour state.
    private var filteredPickerItems: [ModelPickerItem] {
        if let providerId = windowState.selectedDiscoveredAgentProviderId {
            // Bonjour agent active: show only that agent's models.
            return session.pickerItems.filter {
                if case .remote(_, let id) = $0.source { return id == providerId }
                return false
            }
        }
        // No Bonjour agent: show everything — local, foundation, and
        // user-configured remote providers.
        return session.pickerItems
    }

    /// Observed session - needed to properly propagate @Published changes from ChatSession
    @ObservedObject private var observedSession: ChatSession

    /// Convenience accessor for the session (uses observedSession for proper SwiftUI updates)
    private var session: ChatSession { observedSession }

    // MARK: - Initializers

    /// Multi-window initializer with window state
    init(windowState: ChatWindowState) {
        _windowState = ObservedObject(wrappedValue: windowState)
        _observedSession = ObservedObject(wrappedValue: windowState.session)
    }

    /// Convenience initializer with window ID and optional initial state
    init(
        windowId: UUID,
        initialAgentId: UUID? = nil,
        initialSessionData: ChatSessionData? = nil
    ) {
        let agentId = initialSessionData?.agentId ?? initialAgentId ?? Agent.defaultId
        let state = ChatWindowState(
            windowId: windowId,
            agentId: agentId,
            sessionData: initialSessionData
        )
        _windowState = ObservedObject(wrappedValue: state)
        _observedSession = ObservedObject(wrappedValue: state.session)
    }

    private func showOnboardingAndClose() {
        ChatWindowManager.shared.closeWindow(id: windowState.windowId)
    }

    private func noteDiscoveredAgentSelected(_ agent: DiscoveredAgent) {
        Task { @MainActor in selectDiscoveredAgent(agent) }
    }

    private func handleChatToolbarSelectDiscovered(_ notification: Notification) {
        let winId = windowState.windowId
        guard let targetWindowId = notification.userInfo?["windowId"] as? UUID else { return }
        guard targetWindowId == winId else { return }
        guard let d = notification.object as? DiscoveredAgent else { return }
        DispatchQueue.main.async { selectDiscoveredAgent(d) }
    }

    private func relayAgentReceived(_ notification: Notification) {
        let winId = windowState.windowId
        guard let targetWindowId = notification.userInfo?["windowId"] as? UUID else { return }
        guard targetWindowId == winId else { return }
        guard let relay = notification.object as? PairedRelayAgent else { return }
        connectToRelayAgent(relay)
    }

    private func showMgmtWindow(_ tab: ManagementTab) {
        AppDelegate.shared?.showManagementWindow(initialTab: tab)
    }

    @ViewBuilder
    private func whatsNewContent(_ release: WhatsNewRelease) -> some View {
        WhatsNewModal(
            release: release,
            onClose: {
                WhatsNewGate.markShown(version: release.version)
                pendingWhatsNew = nil
            },
            onAction: { action in
                WhatsNewGate.markShown(version: release.version)
                pendingWhatsNew = nil
                switch action {
                case .openSandboxSettings: showMgmtWindow(.sandbox)
                case .openAPIKeysSettings: showMgmtWindow(.server)
                case .openSecurityDoc(let url): NSWorkspace.shared.open(url)
                case .openStorageSettings, .exportPlaintextBackup: showMgmtWindow(.storage)
                }
            }
        )
        .environment(\.theme, windowState.theme)
    }

    private func onPickerItemsChanged(_ newItems: [ModelPickerItem]) {
        guard let providerId = windowState.selectedDiscoveredAgentProviderId else { return }
        var providerItems: [ModelPickerItem] = []
        for item in newItems {
            if item.source.remoteProviderId == providerId { providerItems.append(item) }
        }
        guard let firstItem = providerItems.firstChatCapable else { return }
        let modelId = session.selectedModel
        var matched: ModelPickerItem?
        for item in newItems { if item.id == modelId { matched = item; break } }
        var currentIsFromProvider = false
        if let item = matched {
            currentIsFromProvider = (item.source.remoteProviderId == providerId)
        }
        if !currentIsFromProvider {
            session.selectedModel = firstItem.id
        }
    }

    private func onChangeSelectedProvider(_ providerId: UUID?) {
        guard providerId == nil else { return }
        let agentModel: String? = AgentManager.shared.effectiveModel(for: windowState.agentId)
        if let model = agentModel {
            let items: [ModelPickerItem] = session.pickerItems
            var found = false
            for item in items { if item.id == model { found = true; break } }
            if found { session.selectedModel = model; return }
        }
        if let firstChat = session.pickerItems.firstChatCapable {
            session.selectedModel = firstChat.id
        }
    }

    @ViewBuilder
    private func agentSheetContent(_ agent: DiscoveredAgent) -> some View {
        if agent.address != nil {
            PairingSheet(agent: agent) { apiKey, isPermanent in
                connectToDiscoveredAgent(agent, token: apiKey, isEphemeral: !isPermanent)
                pendingDiscoveredAgent = nil
            } onCancel: {
                pendingDiscoveredAgent = nil
            }
            .environment(\.theme, windowState.theme)
        } else {
            BonjourTokenSheet(agentName: agent.name) { token in
                connectToDiscoveredAgent(agent, token: token)
                pendingDiscoveredAgent = nil
            } onCancel: {
                pendingDiscoveredAgent = nil
            }
            .environment(\.theme, windowState.theme)
        }
    }

    var body: some View {
        chatModeContent
    }

    /// Shared overlay layer for in-chat prompts (secrets + clarify).
    /// Renders a subtle backdrop scrim behind the prompt card and
    /// switches between concrete overlays based on the current item in
    /// `session.promptQueue`. Keyed off `current?.id` so consecutive
    /// prompts crossfade in place rather than the new card snapping in.
    /// The scrim is intentionally non-dismissive (these are deliberate
    /// pauses, not modals); ESC still cancels via the card.
    @ViewBuilder
    private var promptOverlayLayer: some View {
        let current = session.promptQueue.current
        ZStack {
            if current != nil {
                Color.black
                    .opacity(theme.isDark ? 0.28 : 0.18)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .allowsHitTesting(true)
            }

            Group {
                switch current {
                case .secret(let s):
                    SecretPromptOverlay(state: s) {
                        session.promptQueue.advance()
                    }
                case .clarify(let c):
                    ClarifyPromptOverlay(state: c) {
                        session.promptQueue.advance()
                    }
                case .none:
                    EmptyView()
                }
            }
            .id(current?.id)
            .transition(.opacity)
        }
        .animation(theme.springAnimation(), value: current?.id)
    }

    /// Chat mode content — extracted to ChatContentView struct
    private var chatModeContent: some View {
        ChatContentView(
            windowState: windowState,
            observedSession: observedSession,
            session: session,
            pendingWhatsNew: $pendingWhatsNew,
            pendingDiscoveredAgent: $pendingDiscoveredAgent,
            focusTrigger: $focusTrigger,
            isPinnedToBottom: $isPinnedToBottom,
            filteredPickerItems: filteredPickerItems,
            theme: theme,
            keyMonitor: keyMonitor as Any?,
            chatBackground: AnyView(chatBackground),
            chatHeader: AnyView(chatHeader),
            emptyStateView: AnyView(emptyStateView),
            messageThread: { w, h in AnyView(messageThread(w, h)) },
            promptOverlayLayer: AnyView(promptOverlayLayer),
            onChatOverlayActivated: {},
            onSetupFindKeyMonitor: { setupKeyMonitor() },
            onCleanupFindKeyMonitor: { cleanupKeyMonitor() },
            handleChatToolbarSelectDiscovered: { n in handleChatToolbarSelectDiscovered(n) },
            onRelayAgentNotify: { n in relayAgentReceived(n) },
            onPickerItemsChanged: { items in onPickerItemsChanged(items) },
            onChangeSelectedProvider: { id in onChangeSelectedProvider(id) },
            whatsNewContent: { r in AnyView(whatsNewContent(r)) },
            agentSheetContent: { a in AnyView(agentSheetContent(a)) }
        )
    }

    /// Called when the user picks a discovered agent from the menu.
    /// If a persistent (non-ephemeral) paired provider already exists for this agent,
    /// connect directly without showing the pairing sheet.
    private func selectDiscoveredAgent(_ agent: DiscoveredAgent) {
        let manager = RemoteProviderManager.shared
        let hasPersistentProvider = manager.configuration.providers.contains(where: {
            $0.providerType == .osaurus
                && $0.remoteAgentId == agent.id
                && !manager.isEphemeral(id: $0.id)
        })
        if hasPersistentProvider {
            connectToDiscoveredAgent(agent, token: "", isEphemeral: false)
        } else {
            pendingDiscoveredAgent = agent
        }
    }

    private func connectToDiscoveredAgent(_ agent: DiscoveredAgent, token: String, isEphemeral: Bool = true) {
        // Strip trailing dot from mDNS hostnames (e.g. "device.local." -> "device.local")
        let rawHost = agent.host ?? "localhost"
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        let manager = RemoteProviderManager.shared

        let providerId: UUID
        // Reuse an existing Osaurus provider that already targets the same agent
        if let existing = manager.configuration.providers.first(where: {
            $0.providerType == .osaurus && $0.remoteAgentId == agent.id
        }) {
            providerId = existing.id
            var updated = existing
            updated.host = host
            updated.providerProtocol = .http
            updated.port = agent.port
            updated.enabled = true
            if let address = agent.address { updated.remoteAgentAddress = address }
            if !token.isEmpty {
                updated.authType = .apiKey
                manager.updateProvider(updated, apiKey: token)
            } else {
                manager.updateProvider(updated, apiKey: nil)
            }
            Task { try? await manager.connect(providerId: existing.id) }
        } else {
            // Use basePath="" so URLs are constructed directly as /agents/{id}/run
            let provider = RemoteProvider(
                name: agent.name,
                host: host,
                providerProtocol: .http,
                port: agent.port,
                basePath: "",
                authType: token.isEmpty ? .none : .apiKey,
                providerType: .osaurus,
                enabled: true,
                autoConnect: true,
                remoteAgentId: agent.id,
                remoteAgentAddress: agent.address
            )
            providerId = provider.id
            manager.addProvider(provider, apiKey: token.isEmpty ? nil : token, isEphemeral: isEphemeral)
        }

        windowState.selectedRelayAgent = nil
        windowState.selectedDiscoveredAgent = agent
        windowState.selectedDiscoveredAgentProviderId = providerId
        windowState.refreshPairedRelayAgents()
        session.reset()
        Task { await session.refreshPickerItems() }
    }

    private func connectToRelayAgent(_ relay: PairedRelayAgent) {
        let relayHost = "\(relay.remoteAgentAddress).agent.osaurus.ai"
        let manager = RemoteProviderManager.shared

        guard let existing = manager.configuration.providers.first(where: { $0.id == relay.providerId }) else {
            return
        }

        var updated = existing
        updated.host = relayHost
        updated.providerProtocol = .https
        updated.port = nil
        updated.enabled = true
        manager.updateProvider(updated, apiKey: nil)
        Task { try? await manager.connect(providerId: relay.providerId) }

        windowState.selectedDiscoveredAgent = nil
        windowState.selectedRelayAgent = relay
        windowState.selectedDiscoveredAgentProviderId = relay.providerId
        session.reset()
        Task { await session.refreshPickerItems() }
    }

    // MARK: - Empty State

    /// The chat empty-state surface, lifted into its own `@ViewBuilder`
    /// helper so the cumulative type-checker work in `body` stays under
    /// the budget — adding modifiers to the inline `ChatEmptyState(...)`
    /// here previously tipped the surrounding ZStack expression past the
    /// "unable to type-check in reasonable time" threshold.
    @ViewBuilder
    private var emptyStateView: some View {
        ChatEmptyState(
            hasModels: true,
            selectedModel: session.selectedModel,
            agents: windowState.agents,
            activeAgentId: windowState.agentId,
            quickActions: windowState.activeAgent.chatQuickActions
                ?? AgentQuickAction.defaultChatQuickActions,
            generativeGreetingState: session.generativeGreetingState,
            onOpenModelManager: {
                AppDelegate.shared?.showManagementWindow(initialTab: .models)
            },
            onUseFoundation: windowState.foundationModelAvailable
                ? {
                    session.selectedModel =
                        session.pickerItems.firstChatCapable?.id
                        ?? "foundation"
                } : nil,
            onQuickAction: { prompt in
                session.input = prompt
            },
            onOpenOnboarding: nil,
            activeDiscoveredAgent: windowState.selectedDiscoveredAgent,
            activeRelayAgent: windowState.selectedRelayAgent
        )
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .modifier(
            GenerativeGreetingTrigger(
                session: session,
                windowState: windowState
            )
        )
    }

    // MARK: - Background

    private var chatBackground: some View {
        ZStack {
            ThemedBackgroundLayer(
                cachedBackgroundImage: windowState.cachedBackgroundImage,
                showSidebar: windowState.showSidebar
            )

            if theme.glassEnabled {
                ThemedGlassSurface(
                    cornerRadius: 24,
                    topLeadingRadius: windowState.showSidebar ? 0 : nil,
                    bottomLeadingRadius: windowState.showSidebar ? 0 : nil
                )
                .allowsHitTesting(false)

                let baseBacking = theme.windowBackingOpacity
                let backingOpacity = baseBacking * (0.4 + theme.glassOpacityPrimary * 0.6)

                LinearGradient(
                    colors: [
                        theme.primaryBackground.opacity(backingOpacity + theme.glassOpacityPrimary * 0.3),
                        theme.primaryBackground.opacity(backingOpacity + theme.glassOpacitySecondary * 0.2),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: windowState.showSidebar ? 0 : 24,
                        bottomLeadingRadius: windowState.showSidebar ? 0 : 24,
                        bottomTrailingRadius: 24,
                        topTrailingRadius: 24,
                        style: .continuous
                    )
                )
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
        Color.clear
            .frame(height: 52)
            .allowsHitTesting(false)
    }

    // MARK: - Message Thread

    /// Isolated message thread view to prevent cascading re-renders
    private func messageThread(_ width: CGFloat, _ height: CGFloat) -> some View {
        ChatPerfTrace.shared.count("body.messageThread")
        // do not read `session.visibleBlocks` here as that would
        // subscribe this enclosing body to per-sync changes (via ChatSession's
        // objectWillChange, if visibleBlocks were @Published) and/or delay the
        // reactivity needed by the table. `IsolatedThreadView` observes the
        // store directly, so only *its* body re-runs on per-token updates
        let displayName = windowState.cachedAgentDisplayName
        let lastAssistantTurnId = session.lastAssistantTurnIdForThread
        let blocks = session.visibleBlocks
        let minimapMarkers = buildMinimapMarkers(from: blocks)

        let inlineInsetHeight = agentInlineInsetHeight

        // Thread + agent chrome in a ZStack, CLIPPED to the slot height so the
        // scroll view's Ventura over-sizing (see CenteredMessageScrollView) can't
        // bleed behind the header/composer. The minimap and scroll-to-bottom
        // button are `.overlay`s on this clipped frame: sized to the (stable)
        // thread area so they can't spill into the header/composer, yet not
        // themselves clipped — the minimap can still expand + scroll.
        // (Renée, 2026-06-13.)
        return ZStack {
            // Thread reserves a small top inset matching the *collapsed*
            // pill stack height so the topmost message stays visible
            // above the floating chrome. Expanded cards float over
            // content (semi-transparent material lets the conversation
            // read through). The inset animates with the same spring
            // as the pill mount/unmount so the thread visibly slides
            // when the agent emits a todo or completes.
            IsolatedThreadView(
                store: session.visibleBlocksStore,
                width: width,
                agentName: displayName,
                agentAvatar: windowState.cachedActiveAgent.avatar,
                agentCustomAvatarPath: windowState.cachedActiveAgent.customAvatarURL?.path,
                isStreaming: session.isStreaming,
                lastAssistantTurnId: lastAssistantTurnId,
                expandedBlocksStore: session.expandedBlocksStore,
                scrollToBottomTrigger: scrollToBottomTrigger,
                onScrolledToBottom: { isPinnedToBottom = true },
                onScrolledAwayFromBottom: { isPinnedToBottom = false },
                onCopy: copyTurnContent,
                onRegenerate: regenerateTurn,
                onEdit: beginEditingTurn,
                onDelete: deleteTurn,
                onSpeak: speakTurnContent,
                onDeleteMessage: confirmDeleteAssistantMessage,
                editingTurnId: editingTurnId,
                editText: $editText,
                onConfirmEdit: confirmEditAndRegenerate,
                onCancelEdit: cancelEditing,
                onUserImagePreview: openUserAttachmentPreview(attachmentId:),
                onVisibleTopUserTurnChanged: { turnId in
                    activeMinimapTurnId = turnId
                },
                scrollToTurnId: scrollToTurnId,
                scrollToTurnTrigger: scrollToTurnTrigger,
                searchHighlightQuery: windowState.isFindBarVisible
                    ? findQuery.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            )
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear
                    .frame(height: inlineInsetHeight)
                    .animation(theme.springAnimation(), value: inlineInsetHeight)
            }

            // Floating agent-loop chrome (Todo / Done) — top-anchored
            // overlay. Lives in the ZStack as a sibling to the thread
            // so it doesn't consume vertical space; pills compact, cards
            // expand on hover/pin (see `AgentInlineBlocks.swift`).
            VStack(spacing: AgentInlineBlockMetrics.stackSpacing) {
                agentInlineBlocks
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(session.lastCompletionSummary != nil || session.currentTodo != nil)

            // Find bar overlay (Cmd+F) — top-trailing, above the thread.
            if windowState.isFindBarVisible {
                VStack {
                    HStack {
                        Spacer()
                        ChatFindBar(
                            query: $findQuery,
                            matchIndex: findMatchIndex,
                            matchCount: findMatchTurnIds.count,
                            onPrevious: { advanceFindMatch(by: -1) },
                            onNext: { advanceFindMatch(by: 1) },
                            onClose: { windowState.isFindBarVisible = false }
                        )
                        .padding(.trailing, 16)
                        .padding(.top, inlineInsetHeight + 8)
                    }
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .onChange(of: findQuery) { _ in
                    recomputeFindMatches(query: findQuery, jumpToFirst: true)
                }
                .onChange(of: session.turns.count) { _ in
                    recomputeFindMatches(query: findQuery, jumpToFirst: false)
                }
                .onAppear {
                    recomputeFindMatches(query: findQuery, jumpToFirst: false)
                }
            }
        }
        .frame(height: height)
        .clipped()
        // Minimap — sized to the clipped thread frame (so it can't spill into the
        // header/composer) but drawn as an overlay so it isn't itself clipped;
        // expanded, it fills the height and scrolls internally. (Renée, 2026-06-13.)
        .overlay {
            if minimapMarkers.count >= 2 {
                HStack {
                    Spacer()
                    ChatMinimap(
                        markers: minimapMarkers,
                        activeMarkerId: activeMinimapTurnId,
                        onSelect: { turnId in
                            scrollToTurnId = turnId
                            scrollToTurnTrigger &+= 1
                        },
                        isExpanded: $isMinimapExpanded
                    )
                    .padding(.trailing, 22)
                }
                // Bound the minimap to the message area and CLIP it, so a long
                // chat's tall tick strip can't spill into the header/composer.
                // (Expanded, the minimap fills this height and scrolls.)
                // (Renée, 2026-06-13.)
                .frame(height: max(0, height - 16))
                .clipped()
                .allowsHitTesting(true)
            }
        }
        // Scroll-to-bottom button, pinned to the bottom-right of the thread frame
        // (above the composer), bounded to the thread area. (Renée, 2026-06-13.)
        .overlay(alignment: .bottomTrailing) {
            ScrollToBottomButton(
                isPinnedToBottom: isPinnedToBottom,
                hasTurns: session.hasVisibleThreadMessages,
                onTap: {
                    isPinnedToBottom = true
                    scrollToBottomTrigger += 1
                }
            )
        }
        .sheet(
            isPresented: Binding(
                get: { userImagePreview != nil },
                set: { if !$0 { userImagePreview = nil } }
            )
        ) {
            if let img = userImagePreview {
                ImageFullScreenView(image: img, altText: "")
                    .imageFullScreenSheetPresentation()
            }
        }
        // re-pin to bottom when any in-chat prompt overlay opens. previously
        // wired on the MessageThreadView itself. hoisted here after the store
        // isolation so only ChatView's @State pin toggles, not the thread's
        // per-sync data path
        .onReceive(NotificationCenter.default.publisher(for: .chatOverlayActivated)) { _ in
            isPinnedToBottom = true
        }
    }

    /// Floating agent-loop chrome rendered as a top-anchored overlay
    /// over the message thread (see `messageThread(_:)`). Each block
    /// is gated on the corresponding `@Published` state on
    /// `ChatSession`; nothing renders when the state is nil/empty.
    ///
    /// Order: Todo at the top (compact, persistent state); the Done
    /// banner sits below the Todo as a translucent overlay. The thread
    /// inset only reserves space for the Todo pill — the Done banner
    /// floats over conversation content until the user dismisses it.
    ///
    /// `clarify` used to live here too but has been promoted to a
    /// bottom-pinned overlay (see `promptOverlayLayer`) so the question
    /// stays anchored above the input bar instead of floating above the
    /// thread.
    @ViewBuilder
    private var agentInlineBlocks: some View {
        if let todo = session.currentTodo {
            InlineTodoBlock(todo: todo)
                .transition(
                    .opacity
                        .combined(with: .move(edge: .top))
                        .combined(with: .scale(scale: 0.96, anchor: .top))
                )
        }
        if let summary = session.lastCompletionSummary {
            InlineCompleteBlock(
                summary: summary,
                // Always false on Intel: the badge distinguishes an agent run that
                // halted awaiting approval from a completed one, and the agent loop
                // is amputated here, so a completion summary is never "blocked".
                isBlocked: false,
                onDismiss: { [weak session] in
                    session?.lastCompletionSummary = nil
                }
            )
            // Asymmetric transition: appear with a soft slide+scale so
            // arrival reads as "new event"; dismiss with pure opacity
            // so it cleanly fades away when the user clicks ×.
            .transition(
                .asymmetric(
                    insertion: .opacity
                        .combined(with: .move(edge: .top))
                        .combined(with: .scale(scale: 0.96, anchor: .top)),
                    removal: .opacity
                )
            )
        }
    }

    /// Top safe-area inset reserved for the floating Todo pill so the
    /// topmost message stays visible underneath it. The Done banner
    /// (when present) intentionally overlays content beneath the Todo
    /// — it's a transient notification the user dismisses, not a
    /// persistent layout fixture, so reserving space for it would just
    /// chop the visible chat. Returns 0 when no Todo is active.
    private var agentInlineInsetHeight: CGFloat {
        guard session.currentTodo != nil else { return 0 }
        let topPadding: CGFloat = 4
        let bottomBuffer: CGFloat = 6
        return topPadding + AgentInlineBlockMetrics.collapsedPillHeight + bottomBuffer
    }

}

/// Isolates the streaming-driven `visibleBlocks` observation from `ChatView`'s
/// body. This view is the only place `VisibleBlocksStore.objectWillChange`
/// propagates into SwiftUI; ChatView and its other children (FloatingInputCard,
/// toolbar, sidebar) stay outside the subscription and do not re-evaluate on
/// every streaming sync.
private struct IsolatedThreadView: View {
    @ObservedObject var store: VisibleBlocksStore
    let width: CGFloat
    let agentName: String
    let agentAvatar: String?
    let agentCustomAvatarPath: String?
    let isStreaming: Bool
    let lastAssistantTurnId: UUID?
    let expandedBlocksStore: ExpandedBlocksStore
    let scrollToBottomTrigger: Int
    let onScrolledToBottom: () -> Void
    let onScrolledAwayFromBottom: () -> Void
    let onCopy: (UUID) -> Void
    let onRegenerate: ((UUID) -> Void)?
    let onEdit: ((UUID) -> Void)?
    let onDelete: ((UUID) -> Void)?
    let onSpeak: ((UUID) -> Void)?
    let onDeleteMessage: ((UUID) -> Void)?
    let editingTurnId: UUID?
    let editText: Binding<String>?
    let onConfirmEdit: (() -> Void)?
    let onCancelEdit: (() -> Void)?
    let onUserImagePreview: ((String) -> Void)?
    var onVisibleTopUserTurnChanged: ((UUID?) -> Void)? = nil
    var scrollToTurnId: UUID? = nil
    var scrollToTurnTrigger: Int = 0
    /// Active in-conversation find query (Cmd+F); empty when the bar is closed.
    var searchHighlightQuery: String = ""

    var body: some View {
        let _ = ChatPerfTrace.shared.count("body.IsolatedThreadView")
        MessageThreadView(
            blocks: store.blocks,
            groupHeaderMap: store.groupHeaderMap,
            width: width,
            agentName: agentName,
            agentAvatar: agentAvatar,
            agentCustomAvatarPath: agentCustomAvatarPath,
            isStreaming: isStreaming,
            lastAssistantTurnId: lastAssistantTurnId,
            expandedBlocksStore: expandedBlocksStore,
            scrollToBottomTrigger: scrollToBottomTrigger,
            onScrolledToBottom: onScrolledToBottom,
            onScrolledAwayFromBottom: onScrolledAwayFromBottom,
            onCopy: onCopy,
            onRegenerate: onRegenerate,
            onEdit: onEdit,
            onDelete: onDelete,
            onSpeak: onSpeak,
            onDeleteMessage: onDeleteMessage,
            editingTurnId: editingTurnId,
            editText: editText,
            onConfirmEdit: onConfirmEdit,
            onCancelEdit: onCancelEdit,
            onUserImagePreview: onUserImagePreview,
            onVisibleTopUserTurnChanged: onVisibleTopUserTurnChanged,
            scrollToTurnId: scrollToTurnId,
            scrollToTurnTrigger: scrollToTurnTrigger,
            searchHighlightQuery: searchHighlightQuery
        )
    }
}

// Reopen ChatView's declaration for the remaining methods (threadCore was
// inlined into `messageThread` via `IsolatedThreadView` above)
extension ChatView {

    private func openUserAttachmentPreview(attachmentId: String) {
        if let img = ChatImageCache.shared.cachedImage(for: attachmentId) {
            userImagePreview = img
            return
        }
        for turn in session.turns {
            for att in turn.attachments where att.id.uuidString == attachmentId {
                if let data = att.imageData, let img = NSImage(data: data) {
                    userImagePreview = img
                    return
                }
            }
        }
        if let url = sharedArtifactImageURL(artifactId: attachmentId),
            let data = try? Data(contentsOf: url),
            let img = NSImage(data: data)
        {
            userImagePreview = img
        }
    }

    private func sharedArtifactImageURL(artifactId: String) -> URL? {
        for block in session.visibleBlocks {
            guard case let .sharedArtifact(art) = block.kind else { continue }
            guard art.id == artifactId, art.isImage, !art.hostPath.isEmpty else { continue }
            return URL(fileURLWithPath: art.hostPath)
        }
        return nil
    }

    /// Build minimap markers from the current block stream (one per user message)
    private func buildMinimapMarkers(from blocks: [ContentBlock]) -> [ChatMinimap.Marker] {
        var markers: [ChatMinimap.Marker] = []
        markers.reserveCapacity(8)
        for block in blocks {
            if case let .userMessage(text, _) = block.kind {
                markers.append(ChatMinimap.Marker(id: block.turnId, preview: text))
            }
        }
        return markers
    }

    /// Copy a turn's thinking + content to the clipboard
    private func copyTurnContent(turnId: UUID) {
        guard let turn = session.turns.first(where: { $0.id == turnId }) else { return }
        var textToCopy = ""
        if turn.hasRenderableThinking {
            textToCopy += turn.thinking
        }
        if !turn.contentIsBlank {
            if !textToCopy.isEmpty { textToCopy += "\n\n" }
            textToCopy += turn.visibleContent
        }
        guard !textToCopy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textToCopy, forType: .string)
    }

    /// Stable callback for regenerate action - prevents closure recreation
    private func regenerateTurn(turnId: UUID) {
        session.regenerate(turnId: turnId)
    }

    /// Read the assistant turn aloud via PocketTTS. If the model isn't downloaded,
    /// TTSService posts a notification that opens the TTS settings tab.
    private func speakTurnContent(turnId: UUID) {
        guard let turn = session.turns.first(where: { $0.id == turnId }) else { return }
        guard !turn.contentIsBlank else { return }
        let isStartingPlayback = TTSService.shared.playingMessageId != turnId
        if isStartingPlayback && !session.hasAskedAutoSpeak {
            session.hasAskedAutoSpeak = true
            showAutoSpeakPrompt = true
        }
        TTSService.shared.toggleSpeak(
            text: turn.visibleContent,
            messageId: turnId,
            voiceOverride: agentTTSVoiceOverride()
        )
    }

    /// Auto-speak the just-finished assistant turn when the per-session
    /// preference is on. Skips if TTS is disabled, the model isn't loaded,
    /// or another message is already playing (don't interrupt).
    private func handleAssistantTurnCompleted(turnId: UUID?) {
        guard let turnId else { return }
        guard session.autoSpeakAssistant else { return }
        guard TTSConfigurationStore.load().enabled else { return }
        guard TTSService.shared.isModelReady else { return }
        guard TTSService.shared.playingMessageId == nil else { return }
        guard let turn = session.turns.first(where: { $0.id == turnId }),
            !turn.contentIsBlank
        else { return }
        TTSService.shared.toggleSpeak(
            text: turn.visibleContent,
            messageId: turnId,
            voiceOverride: agentTTSVoiceOverride()
        )
    }

    /// active agent's voice override, or nil to use the global voice.
    private func agentTTSVoiceOverride() -> String? {
        let id = session.agentId ?? Agent.defaultId
        return AgentManager.shared.agent(for: id)?.ttsVoice
    }

    /// Stop any active generation and remove the turn (plus all subsequent turns)
    private func deleteTurn(turnId: UUID) {
        if session.isStreaming { session.stop() }
        session.deleteTurn(id: turnId)
        discardSessionIfEmptied()
    }

    /// Ask before deleting an assistant response. Deleting mid-thread can change
    /// what later turns were answering, so we always confirm. The dialog offers
    /// an "also delete my message" checkbox that escalates the delete to the
    /// whole exchange. Upstream c4d9d140.
    ///
    /// This fork is cloud-only (no resident local model whose KV cache would
    /// need reprocessing), so upstream's local-vs-remote branch on the warning
    /// copy collapses to the single remote-model line. Upstream also gains a
    /// line here when the turn is covered by a compaction summary
    /// (`conversationSummary`); that plumbing doesn't exist on Intel yet, so
    /// it's omitted — revisit once context compaction (ce414b3f) lands.
    private func confirmDeleteAssistantMessage(turnId: UUID) {
        guard let turn = session.turns.first(where: { $0.id == turnId }),
            turn.role == .assistant
        else { return }

        let hasToolCalls = !(turn.toolCalls?.isEmpty ?? true)

        var lines: [String] = [
            L("This removes this response from the conversation. It won't be sent to the model on later turns.")
        ]
        if hasToolCalls {
            lines.append(
                L("Any tool calls in this response and their results will be removed together.")
            )
        }

        let options = DeleteMessageOptions()
        let requestId = UUID()
        let scope = ThemedAlertScope.chat(windowState.windowId)
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: L("Delete this response?"),
                message: lines.joined(separator: "\n\n"),
                accessory: AnyView(DeleteAlsoUserMessageToggle(options: options)),
                buttons: [
                    .cancel(L("Cancel")),
                    .destructive(L("Delete")) { [weak session] in
                        guard let session else { return }
                        if session.isStreaming { session.stop() }
                        if options.alsoDeleteUserMessage {
                            session.removeExchange(anchoredAt: turnId)
                        } else {
                            session.removeTurn(id: turnId)
                        }
                        discardSessionIfEmptied()
                    },
                ],
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }

    /// A delete can empty the conversation (e.g. removing the only exchange).
    /// `save()` skips empty conversations, so the stale row would otherwise
    /// survive and reappear on reopen. Mirror the sidebar's delete of the
    /// current session: reset the window to a fresh chat, drop the persisted
    /// row, and refresh the history list. Upstream c4d9d140 also cancels a
    /// live `BackgroundTaskManager` task for the session here; that lookup
    /// (`liveTask(forSessionId:)`) isn't part of this fork's task manager —
    /// the callers above already stop an in-progress stream via
    /// `session.stop()`, which is this fork's equivalent live-run cancel.
    private func discardSessionIfEmptied() {
        guard session.turns.isEmpty, let id = session.sessionId else { return }
        session.reset()
        ChatSessionsManager.shared.delete(id: id)
        windowState.refreshSessions()
    }

    // MARK: - Inline Editing

    /// Begin inline editing of a user message
    private func beginEditingTurn(turnId: UUID) {
        guard let turn = session.turns.first(where: { $0.id == turnId }),
            turn.role == .user
        else { return }
        editText = turn.content
        editingTurnId = turnId
    }

    /// Confirm the edit and regenerate the assistant response
    private func confirmEditAndRegenerate() {
        guard let turnId = editingTurnId else { return }
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.editAndRegenerate(turnId: turnId, newContent: trimmed)
        editingTurnId = nil
        editText = ""
    }

    /// Dismiss the inline editor without changes
    private func cancelEditing() {
        editingTurnId = nil
        editText = ""
    }

    // MARK: - In-Conversation Find (Cmd+F)

    /// Recompute the ordered turn-id match list for `query` over the visible
    /// conversation. `jumpToFirst` scrolls to the first match (used while
    /// typing); otherwise the current match is preserved when it survives the
    /// recompute (used when streaming appends turns). Logic lives in
    /// `ChatFindMatcher` so the invariants are unit-tested.
    private func recomputeFindMatches(query: String, jumpToFirst: Bool) {
        let (state, jumpTo) = ChatFindMatcher.recompute(
            query: query,
            turns: session.turns,
            previous: ChatFindState(matchTurnIds: findMatchTurnIds, matchIndex: findMatchIndex),
            preserveCurrentMatch: !jumpToFirst
        )
        findMatchTurnIds = state.matchTurnIds
        findMatchIndex = state.matchIndex
        if let jumpTo {
            scrollToTurnId = jumpTo
            scrollToTurnTrigger &+= 1
        }
    }

    /// Step to the next/previous match, wrapping at both ends.
    private func advanceFindMatch(by delta: Int) {
        let (state, jumpTo) = ChatFindMatcher.advance(
            ChatFindState(matchTurnIds: findMatchTurnIds, matchIndex: findMatchIndex),
            by: delta
        )
        findMatchTurnIds = state.matchTurnIds
        findMatchIndex = state.matchIndex
        if let jumpTo {
            scrollToTurnId = jumpTo
            scrollToTurnTrigger &+= 1
        }
    }

    // Key monitor for Esc to cancel voice or close window
    private func setupKeyMonitor() {
        if keyMonitor != nil { return }

        let capturedWindowId = windowState.windowId
        let session = windowState.session
        let windowState = self.windowState

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak session, weak windowState] event in
            // Cmd+F opens the in-conversation find bar.
            if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                event.charactersIgnoringModifiers?.lowercased() == "f"
            {
                guard let ourWindow = ChatWindowManager.shared.getNSWindow(id: capturedWindowId),
                    event.window === ourWindow,
                    let windowState
                else { return event }
                windowState.isFindBarVisible = true
                return nil
            }

            // Esc key code is 53
            if event.keyCode == 53 {
                // Only handle Esc if this event is for our specific window
                // This prevents closed windows' monitors from handling events for other windows
                guard let ourWindow = ChatWindowManager.shared.getNSWindow(id: capturedWindowId),
                    event.window === ourWindow
                else {
                    return event
                }

                // Session deallocated means the window is gone — pass through
                guard let session else { return event }

                // Stage 0: Slash command popup is open — let the text view delegate handle it
                if SlashCommandRegistry.shared.isPopupVisible {
                    return event
                }

                // Stage 0.5: Find bar is open — close it before any other
                // transient UI so Esc can't fall through to window close
                // while the user is mid-search.
                if let windowState, windowState.isFindBarVisible {
                    windowState.isFindBarVisible = false
                    return nil
                }

                // Check if voice input is active AND overlay is visible
                if SpeechService.shared.isRecording && session.showVoiceOverlay {
                    // Stage 1: Cancel voice input
                    print("[ChatView] Esc pressed: Cancelling voice input")
                    Task {
                        // Stop streaming and clear transcription
                        _ = await SpeechService.shared.stopStreamingTranscription()
                        SpeechService.shared.clearTranscription()
                    }
                    return nil  // Swallow event
                } else {
                    // Stage 2: Close chat window
                    print("[ChatView] Esc pressed: Closing chat window")

                    // Also ensure we cleanup any zombie recording if it exists (hidden but recording)
                    if SpeechService.shared.isRecording {
                        print("[ChatView] Cleaning up zombie voice recording on window close")
                        Task {
                            _ = await SpeechService.shared.stopStreamingTranscription()
                            SpeechService.shared.clearTranscription()
                        }
                    }

                    Task { @MainActor in
                        ChatWindowManager.shared.closeWindow(id: capturedWindowId)
                    }
                    return nil  // Swallow event
                }
            }
            return event
        }
    }

    private func cleanupKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

// MARK: - Bonjour Token Sheet

/// Sheet shown when the user selects a Bonjour-discovered remote agent.
/// Prompts for an optional server token before connecting.
private struct BonjourTokenSheet: View {
    let agentName: String
    let onConnect: (String) -> Void
    let onCancel: () -> Void

    @State private var token: String = ""
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect to \(agentName)", bundle: .module)
                    .font(theme.font(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text("Enter the server token for this agent, or leave blank if none is required.", bundle: .module)
                    .font(theme.font(size: 13))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SecureField(L("Server token (optional)"), text: $token)
                .textFieldStyle(.roundedBorder)
                .font(theme.font(size: 13))

            HStack {
                Button {
                    onCancel()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    onConnect(token)
                } label: {
                    Text("Connect", bundle: .module)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

// MARK: - Pairing Sheet

/// Sheet shown when the user selects a Bonjour-discovered agent that has a crypto address.
/// Performs cryptographic pairing instead of prompting for a manual server token.
private struct PairingSheet: View {
    let agent: DiscoveredAgent
    let onSuccess: (String, Bool) -> Void  // (apiKey, isPermanent)
    let onCancel: () -> Void

    @State private var isPairing = false
    @State private var errorMessage: String? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pair with \(agent.name)", bundle: .module)
                    .font(theme.font(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(
                    "This will cryptographically verify both devices. The remote device will show an approval prompt.",
                    bundle: .module
                )
                .font(theme.font(size: 13))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let error = errorMessage {
                Text(error)
                    .font(theme.font(size: 12))
                    .foregroundColor(theme.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    onCancel()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isPairing)
                Spacer()
                if isPairing {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                } else {
                    Button {
                        Task { await performPairing() }
                    } label: {
                        Text("Pair", bundle: .module)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func performPairing() async {
        isPairing = true
        errorMessage = nil
        defer { isPairing = false }

        do {
            let (apiKey, isPermanent) = try await PairingClient.pair(with: agent)
            onSuccess(apiKey, isPermanent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Pairing Client

private enum PairingClient {
    struct PairRequestBody: Codable {
        let connectorAddress: String
        let agentId: String
        let nonce: String
        let signature: String
    }

    struct PairResponseBody: Codable {
        let agentAddress: String
        let apiKey: String
        let isPermanent: Bool
    }

    enum PairingError: LocalizedError {
        case missingHost
        case signFailed
        case networkError(Int)
        case decodingFailed
        case denied

        var errorDescription: String? {
            switch self {
            case .missingHost: return "Could not resolve the agent's network address."
            case .signFailed: return "Failed to sign the pairing request."
            case .networkError(let code): return "Pairing request failed (HTTP \(code))."
            case .decodingFailed: return "Unexpected response from the remote device."
            case .denied: return "Pairing was denied by the remote device."
            }
        }
    }

    static func pair(with agent: DiscoveredAgent) async throws -> (apiKey: String, isPermanent: Bool) {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 300

        var masterKey = try MasterKey.getPrivateKey(context: context)
        defer {
            masterKey.withUnsafeMutableBytes { ptr in
                if let base = ptr.baseAddress { memset(base, 0, ptr.count) }
            }
        }

        let connectorAddress = try PairingKey.deriveAddress(masterKey: masterKey)
        let nonce = UUID().uuidString

        let signature = try PairingKey.sign(payload: Data(nonce.utf8), masterKey: masterKey)
        let hexSig = "0x" + signature.hexEncodedString

        let rawHost = agent.host ?? ""
        guard !rawHost.isEmpty else { throw PairingError.missingHost }
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost

        let urlString = "http://\(host):\(agent.port)/pair"
        guard let url = URL(string: urlString) else { throw PairingError.missingHost }

        let body = PairRequestBody(
            connectorAddress: connectorAddress,
            agentId: agent.id.uuidString,
            nonce: nonce,
            signature: hexSig
        )
        let bodyData = try JSONEncoder().encode(body)

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode == 403 { throw PairingError.denied }
        guard statusCode == 200 else { throw PairingError.networkError(statusCode) }

        guard let decoded = try? JSONDecoder().decode(PairResponseBody.self, from: responseData) else {
            throw PairingError.decodingFailed
        }

        return (apiKey: decoded.apiKey, isPermanent: decoded.isPermanent)
    }
}

// MARK: - Shared Header Components
// HeaderActionButton, SettingsButton, CloseButton, PinButton are now in SharedHeaderComponents.swift
