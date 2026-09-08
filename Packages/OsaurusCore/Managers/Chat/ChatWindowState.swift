#if !OSAURUS_INTEL
//
//  ChatWindowState.swift
//  osaurus
//
//  Per-window state container that isolates each ChatView window from shared singletons.
//  Pre-computes values needed for view rendering so view body is read-only.
//

import AppKit
import Combine
import Foundation
import SwiftUI

/// Per-window state container for ChatView - each window creates its own instance
@MainActor
final class ChatWindowState: ObservableObject {
    // MARK: - Identity & Session

    let windowId: UUID
    let session: ChatSession
    let foundationModelAvailable: Bool

    // MARK: - View State

    @Published var showSidebar: Bool = false

    /// Drives the in-chat "Keep this chat running?" confirmation overlay
    /// that intercepts a close while `session.isStreaming` is true. Set
    /// from `ChatWindowManager.shouldAllowClose`; cleared by the alert's
    /// button actions in `ChatView`.
    @Published var showCloseConfirmation: Bool = false

    // MARK: - Agent State

    @Published var agentId: UUID
    @Published private(set) var agents: [Agent] = []
    @Published private(set) var discoveredAgents: [DiscoveredAgent] = []
    @Published var selectedDiscoveredAgent: DiscoveredAgent?
    @Published var selectedDiscoveredAgentProviderId: UUID?
    @Published private(set) var pairedRelayAgents: [PairedRelayAgent] = []
    @Published var selectedRelayAgent: PairedRelayAgent?

    // MARK: - Theme State

    @Published private(set) var theme: ThemeProtocol
    @Published private(set) var cachedBackgroundImage: NSImage?

    // MARK: - Pre-computed View Values

    @Published private(set) var filteredSessions: [ChatSessionData] = []
    @Published private(set) var cachedSystemPrompt: String = ""
    @Published private(set) var cachedActiveAgent: Agent = .default
    @Published private(set) var cachedAgentDisplayName: String = L("Assistant")

    // MARK: - Private

    private nonisolated(unsafe) var notificationObservers: [NSObjectProtocol] = []
    private var sessionRefreshWorkItem: DispatchWorkItem?
    private var bonjourCancellable: AnyCancellable?
    private var agentsCancellable: AnyCancellable?
    private var sessionsCancellable: AnyCancellable?

    // MARK: - Initialization

    init(windowId: UUID, agentId: UUID, sessionData: ChatSessionData? = nil) {
        self.windowId = windowId
        self.agentId = agentId
        self.session = ChatSession()
        self.foundationModelAvailable = AppConfiguration.shared.foundationModelAvailable
        self.theme = Self.loadTheme(for: agentId)

        // Load initial data
        self.agents = AgentManager.shared.agents
        self.filteredSessions = ChatSessionsManager.shared.sessions(for: agentId)

        // Pre-compute view values
        self.cachedSystemPrompt = AgentManager.shared.effectiveSystemPrompt(for: agentId)
        self.cachedActiveAgent = agents.first { $0.id == agentId } ?? .default
        self.cachedAgentDisplayName = Self.displayName(for: cachedActiveAgent)
        decodeBackgroundImageAsync(themeConfig: theme.customThemeConfig)

        // Configure session
        self.session.windowState = self
        self.session.agentId = agentId
        self.session.applyInitialModelSelection()
        if let data = sessionData {
            self.session.load(from: data)
        }
        self.session.onSessionChanged = { [weak self] in
            self?.refreshSessionsDebounced()
        }

        setupNotificationObservers()
        observeBonjourBrowser()
        observeAgentManager()
        observeSessionsManager()
        refreshPairedRelayAgents()
    }

    /// Wrap an existing `ExecutionContext`, reusing its sessions without duplication.
    /// Used for lazy window creation when a user clicks "View" on a toast.
    init(windowId: UUID, executionContext context: ExecutionContext) {
        self.windowId = windowId
        self.agentId = context.agentId
        self.session = context.chatSession
        self.foundationModelAvailable = AppConfiguration.shared.foundationModelAvailable
        self.theme = Self.loadTheme(for: context.agentId)

        self.agents = AgentManager.shared.agents
        self.filteredSessions = ChatSessionsManager.shared.sessions(for: context.agentId)
        self.cachedSystemPrompt = AgentManager.shared.effectiveSystemPrompt(for: context.agentId)
        self.cachedActiveAgent = agents.first { $0.id == context.agentId } ?? .default
        self.cachedAgentDisplayName = Self.displayName(for: cachedActiveAgent)
        decodeBackgroundImageAsync(themeConfig: theme.customThemeConfig)

        self.session.onSessionChanged = { [weak self] in
            self?.refreshSessionsDebounced()
        }

        setupNotificationObservers()
        observeBonjourBrowser()
        observeAgentManager()
        observeSessionsManager()
        refreshPairedRelayAgents()
    }

    deinit {
        print("[ChatWindowState] deinit – windowId: \(windowId)")
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Stops any running execution and breaks reference chains — call when window is closing.
    func cleanup() {
        removeEphemeralProviderIfNeeded()
        selectedDiscoveredAgent = nil
        selectedDiscoveredAgentProviderId = nil
        selectedRelayAgent = nil
        session.stop()
        session.onSessionChanged = nil
    }

    // MARK: - Close-Confirmation Actions

    /// "Continue in Background" — adopt the live session as a background
    /// task (visible in the notch) and dismiss the window.
    func confirmCloseInBackground() {
        BackgroundTaskManager.shared.detachChatWindow(windowId: windowId)
        ChatWindowManager.shared.closeWindow(id: windowId)
    }

    /// "Stop and Close" — cancel the in-flight stream, then dismiss.
    func confirmCloseAndStop() {
        session.stop()
        ChatWindowManager.shared.closeWindow(id: windowId)
    }

    // MARK: - API

    var activeAgent: Agent { cachedActiveAgent }

    var themeId: UUID? {
        AgentManager.shared.themeId(for: agentId)
    }

    func switchAgent(to newAgentId: UUID) {
        TTSService.shared.stop()
        if !session.turns.isEmpty { session.save() }
        adoptAgent(newAgentId)
        session.reset(for: newAgentId)
        refreshSessions()
    }

    func startNewChat() {
        TTSService.shared.stop()
        if !session.turns.isEmpty { session.save() }
        flushCurrentSession()
        session.reset(for: agentId)
        refreshSessions()
    }

    func loadSession(_ sessionData: ChatSessionData) {
        guard sessionData.id != session.sessionId else { return }
        TTSService.shared.stop()
        if !session.turns.isEmpty { session.save() }
        flushCurrentSession()

        let resolvedData = ChatSessionStore.load(id: sessionData.id) ?? sessionData
        let targetAgentId = resolvedData.agentId ?? Agent.defaultId

        // Sync the window's active agent with the loaded session so the
        // chat header, theme, dropdown, sidebar filter, and downstream
        // save()/reset() calls all reflect the conversation's true agent
        // (#1005). Without this, clicking "New Chat" afterwards silently
        // re-tags the conversation to the previously-selected agent.
        if targetAgentId != agentId {
            adoptAgent(targetAgentId)
        }

        session.load(from: resolvedData)
        refreshSessions()
    }

    /// Switch every per-agent piece of window state (`agentId`,
    /// discovered/relay-agent pills, theme, system-prompt cache, global
    /// active-agent pointer) to `newAgentId` WITHOUT touching the
    /// session's content. `switchAgent` calls this before resetting the
    /// session for a brand-new chat; `loadSession` calls it before
    /// loading turns from disk.
    private func adoptAgent(_ newAgentId: UUID) {
        removeEphemeralProviderIfNeeded()
        selectedDiscoveredAgent = nil
        selectedDiscoveredAgentProviderId = nil
        selectedRelayAgent = nil
        agentId = newAgentId
        refreshTheme()
        refreshAgentConfig()
        AgentManager.shared.setActiveAgent(newAgentId)
    }

    private func flushCurrentSession() {
        guard let sid = session.sessionId else { return }
        let agentStr = (session.agentId ?? Agent.defaultId).uuidString
        let convStr = sid.uuidString
        Task {
            await MemoryService.shared.flushSession(agentId: agentStr, conversationId: convStr)
        }
    }

    // MARK: - Refresh Methods

    func refreshAgents() {
        agents = AgentManager.shared.agents
        cachedActiveAgent = agents.first { $0.id == agentId } ?? .default
        cachedAgentDisplayName = Self.displayName(for: cachedActiveAgent)
    }

    func refreshSessions() {
        filteredSessions = ChatSessionsManager.shared.sessions(for: agentId)
    }

    /// Coalesces rapid `refreshSessions()` calls (e.g. during streaming saves).
    func refreshSessionsDebounced() {
        sessionRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.refreshSessions()
            }
        }
        sessionRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    func refreshTheme() {
        let newTheme = Self.loadTheme(for: agentId)
        let oldConfig = theme.customThemeConfig
        let newConfig = newTheme.customThemeConfig
        // Skip only if the full config is identical (not just the ID) and the
        // global font zoom is unchanged — the zoom lives on the theme instance,
        // not in the config, so it must be compared separately. Upstream 1b955c2b.
        let oldScale = (theme as? CustomizableTheme)?.fontScale
        let newScale = (newTheme as? CustomizableTheme)?.fontScale
        guard oldConfig != newConfig || oldScale != newScale else { return }
        let shouldRedecodeBackgroundImage = Self.needsBackgroundImageRedecode(
            oldConfig: oldConfig,
            newConfig: newConfig
        )

        theme = newTheme

        if shouldRedecodeBackgroundImage {
            decodeBackgroundImageAsync(themeConfig: newConfig)
        }
    }

    nonisolated static func needsBackgroundImageRedecode(oldConfig: CustomTheme?, newConfig: CustomTheme?) -> Bool {
        BackgroundImageDecodeKey(config: oldConfig) != BackgroundImageDecodeKey(config: newConfig)
    }

    func refreshAgentConfig() {
        cachedSystemPrompt = AgentManager.shared.effectiveSystemPrompt(for: agentId)
        cachedActiveAgent = agents.first { $0.id == agentId } ?? .default
        cachedAgentDisplayName = Self.displayName(for: cachedActiveAgent)
        session.invalidateTokenCache()
    }

    func refreshAll() async {
        refreshAgents()
        refreshSessions()
        refreshTheme()
        refreshAgentConfig()
        await session.refreshPickerItems()
    }

    // MARK: - Private

    private func observeBonjourBrowser() {
        bonjourCancellable = BonjourBrowser.shared.$discoveredAgents
            .receive(on: RunLoop.main)
            .sink { [weak self] agents in
                self?.discoveredAgents = agents
                if let selected = self?.selectedDiscoveredAgent,
                    !agents.contains(where: { $0.id == selected.id })
                {
                    self?.removeEphemeralProviderIfNeeded()
                    self?.selectedDiscoveredAgent = nil
                    self?.selectedDiscoveredAgentProviderId = nil
                }
                self?.refreshPairedRelayAgents(discoveredAgents: agents)
            }
    }

    /// Mirror `AgentManager.shared.$agents` into this window so the picker,
    /// `cachedActiveAgent`, and `cachedAgentDisplayName` stay live across
    /// mutations from anywhere (AgentsView, onboarding, plugins, other
    /// windows). The publisher is already `@MainActor`-bound, so we skip
    /// `.receive(on:)` to avoid an unnecessary RunLoop hop.
    ///
    /// `@Published` replays its current value on subscribe; since the
    /// initializers populate the cached fields with the same source-of-
    /// truth values just before calling this, that first replay no-ops in
    /// the `oldActive == newActive` gate of `applyAgentsUpdate`.
    private func observeAgentManager() {
        agentsCancellable = AgentManager.shared.$agents
            .sink { [weak self] latest in
                self?.applyAgentsUpdate(latest)
            }
    }

    private func observeSessionsManager() {
        sessionsCancellable = ChatSessionsManager.shared.$sessions
            .dropFirst()
            .sink { [weak self] _ in
                self?.refreshSessions()
            }
    }

    /// Reconcile our snapshot with a fresh emission from `AgentManager.$agents`.
    ///
    /// - Active agent missing → fall back to Default via `switchAgent`.
    /// - Otherwise always update the dropdown-facing snapshot (cheap path
    ///   that handles non-active mutations).
    /// - Only when the active agent's `Agent` value changed do we touch the
    ///   token cache, system-prompt cache, and theme — same gating the
    ///   removed `.agentUpdated` observer used to do, now driven by the
    ///   source-of-truth array's `Equatable` diff.
    ///
    /// IMPORTANT: do not read from `AgentManager.shared.agents` (or
    /// `effectiveSystemPrompt`, which routes through it) inside this
    /// method. Combine's `@Published` emits in `willSet`, so during the
    /// sink callback the singleton's storage still holds the OLD array;
    /// only `latest` and the resolved `newActive` are guaranteed fresh.
    private func applyAgentsUpdate(_ latest: [Agent]) {
        let oldActive = cachedActiveAgent
        agents = latest

        guard let newActive = latest.first(where: { $0.id == agentId }) else {
            #if OSAURUS_INTEL
            // SESSION-DEATH GUARD (Intel): a transient/partial `$agents`
            // emission must NEVER tear down the live session. The Intel
            // AgentManager rebuilds `agents` by re-decoding every custom-agent
            // JSON from disk on each reload; if the active agent's file is
            // momentarily unreadable (mid-write / transient I/O), it drops out
            // of `latest` for one emission. The old code reacted by calling
            // `switchAgent(.default)` -> `session.reset()`, wiping the
            // conversation and killing any in-flight run ("name flashes, then
            // poof"). Only fall back to Default when we're CONFIDENT the agent
            // is genuinely gone: list non-empty, not mid-stream, and the
            // agent's JSON truly no longer exists on disk.
            let agentFile = OsaurusPaths.agents()
                .appendingPathComponent("\(agentId.uuidString).json")
            let fileStillExists = FileManager.default.fileExists(atPath: agentFile.path)
            let trulyGone = !latest.isEmpty && !session.isStreaming && !fileStillExists
            if trulyGone {
                print("[ChatWindowState] active agent \(agentId) genuinely removed → fallback to Default")
                switchAgent(to: Agent.defaultId)
            } else {
                print(
                    "[ChatWindowState] IGNORING transient agents emission missing active agent "
                        + "\(agentId) (count=\(latest.count) streaming=\(session.isStreaming) "
                        + "fileExists=\(fileStillExists)) — keeping session alive"
                )
            }
            return
            #else
            // `switchAgent` updates theme/sessions/config and persists the
            // selection. `agents` was just swapped above, so any re-read
            // inside `switchAgent` sees the fresh list.
            switchAgent(to: Agent.defaultId)
            return
            #endif
        }

        cachedActiveAgent = newActive
        cachedAgentDisplayName = Self.displayName(for: newActive)

        guard newActive != oldActive else { return }

        // The Default agent's mutable settings live in `ChatConfiguration`
        // and are kept fresh by the `.appConfigurationChanged` observer;
        // here we only refresh the cache for the custom-agent case (using
        // the fresh `newActive`, not the stale singleton).
        if !newActive.isBuiltIn {
            cachedSystemPrompt = newActive.systemPrompt
        }
        session.invalidateTokenCache()

        if newActive.themeId != oldActive.themeId {
            refreshTheme()
        }
    }

    func refreshPairedRelayAgents(discoveredAgents: [DiscoveredAgent]? = nil) {
        let knownAgents = discoveredAgents ?? self.discoveredAgents
        let discoveredIds = Set(knownAgents.map(\.id))
        let manager = RemoteProviderManager.shared
        pairedRelayAgents = manager.configuration.providers.compactMap { provider in
            guard provider.providerType == .osaurus,
                !manager.isEphemeral(id: provider.id),
                let agentId = provider.remoteAgentId,
                let relayAddress = provider.remoteAgentAddress,
                !discoveredIds.contains(agentId)
            else { return nil }
            return PairedRelayAgent(
                id: agentId,
                name: provider.name,
                remoteAgentAddress: relayAddress,
                providerId: provider.id
            )
        }
    }

    private func removeEphemeralProviderIfNeeded() {
        guard let providerId = selectedDiscoveredAgentProviderId,
            RemoteProviderManager.shared.isEphemeral(id: providerId)
        else { return }
        RemoteProviderManager.shared.removeProvider(id: providerId)
    }

    private static func loadTheme(for agentId: UUID) -> ThemeProtocol {
        if let themeId = AgentManager.shared.themeId(for: agentId),
            let custom = ThemeManager.shared.installedThemes.first(where: { $0.metadata.id == themeId })
        {
            return CustomizableTheme(config: custom)
        }
        return ThemeManager.shared.currentTheme
    }

    /// Built-in (Default) agent always renders as the localized "Assistant"
    /// label so the chat header doesn't expose the internal `"Default"` name;
    /// custom agents render their stored name verbatim.
    private static func displayName(for agent: Agent) -> String {
        agent.isBuiltIn ? L("Assistant") : agent.name
    }

    private func decodeBackgroundImageAsync(themeConfig: CustomTheme?) {
        Task { [weak self] in
            let decoded = themeConfig?.background.decodedImage()
            self?.cachedBackgroundImage = decoded
        }
    }

    private struct BackgroundImageDecodeKey: Equatable {
        let themeId: UUID?
        let backgroundType: ThemeBackground.BackgroundType?
        let imageData: String?

        init(config: CustomTheme?) {
            self.themeId = config?.metadata.id
            self.backgroundType = config?.background.type
            self.imageData = config?.background.imageData
        }
    }

    private func setupNotificationObservers() {
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .activeAgentChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.refreshAgents() } }
        )
        // Note: .chatOverlayActivated intentionally not observed here
        // State is loaded in init(), refreshAll() would cause excessive re-renders
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .appConfigurationChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.refreshAgentConfig() } }
        )
        // refresh theme when any theme on disk changes. refreshTheme()
        // re-resolves from `installedThemes`/`currentTheme` and no ops via its
        // config equality guard if this window's effective theme is unchanged,
        // so windows pinned to an agent specific theme also pick up live edits
        // to that theme without waiting for a reopen
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .globalThemeChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshTheme() }
            }
        )
        // Note: `.agentUpdated` is intentionally not observed here.
        // `observeAgentManager()` covers active-custom-agent updates by
        // diffing the published `agents` array, and the
        // `.appConfigurationChanged` observer above covers Default-agent
        // updates (whose settings live in `ChatConfiguration`).

        // Clear the selected paired/relay agent pill when its provider is
        // removed from settings.
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .remoteProviderStatusChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                        let providerId = self.selectedDiscoveredAgentProviderId
                    else { return }
                    let providerExists = RemoteProviderManager.shared.configuration.providers
                        .contains(where: { $0.id == providerId })
                    guard !providerExists else { return }
                    self.selectedDiscoveredAgent = nil
                    self.selectedRelayAgent = nil
                    self.selectedDiscoveredAgentProviderId = nil
                    self.refreshPairedRelayAgents()
                }
            }
        )
    }
}
#else
// Intel fork: ChatWindowState stub matching original properties
import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class ChatWindowState: ObservableObject {
    let windowId: UUID
    let session: ChatSession
    let foundationModelAvailable: Bool = false

    @Published var showSidebar: Bool = true
    @Published var showCloseConfirmation: Bool = false
    /// Drives the in-conversation find bar (Cmd+F). Set by the window-level
    /// key monitor (which cannot touch `ChatView`'s `@State`) and cleared by
    /// the bar's close button or the Esc dismissal chain.
    @Published var isFindBarVisible: Bool = false
    @Published var agentId: UUID
    @Published var agents: [Agent] = []
    @Published var discoveredAgents: [DiscoveredAgent] = []
    @Published var selectedDiscoveredAgent: DiscoveredAgent? = nil
    @Published var selectedDiscoveredAgentProviderId: UUID? = nil
    @Published var pairedRelayAgents: [PairedRelayAgent] = []
    @Published var selectedRelayAgent: PairedRelayAgent? = nil
    @Published var theme: ThemeProtocol
    @Published var cachedBackgroundImage: NSImage? = nil
    @Published var filteredSessions: [ChatSessionData] = []
    @Published var cachedSystemPrompt: String = ""
    @Published var cachedActiveAgent: Agent = .default
    @Published var cachedAgentDisplayName: String = "Assistant"
    @Published var selectedModel: String = "deepseek-v4-pro"
    @Published var availableModels: [String] = ["deepseek-v4-pro", "deepseek-v4-flash"]
    /// Non-nil while the window's main content area is showing a project
    /// page instead of the chat thread/composer. In-memory window state only
    /// (not persisted `Codable`), so a plain stored property is safe here —
    /// this is NOT `ChatSessionData`/`Project`, the types the "never add a
    /// non-optional stored property to a persisted Codable type" rule guards.
    @Published public var openProjectId: UUID?

    /// Holds the `.globalThemeChanged` notification observer so it can be
    /// torn down in `cleanup()`. M11 Phase 11.A.1.x bug fix: prior to this,
    /// the Intel `ChatWindowState` stub set `theme` once in init and never
    /// observed the upstream `globalThemeChanged` notification (posted by
    /// `ThemeManager.applyCustomTheme` / `setAppearanceMode` /
    /// `clearCustomTheme`). Picking a theme in the Settings → Themes tab
    /// (un-body-swapped in 11.A.1) updated the management window but left
    /// chat windows pinned to whatever theme was active at window-creation
    /// time. Mirrors the upstream observer registered in
    /// `ChatWindowState.observeAppConfigurationChanges()` (excluded on Intel).
    private var themeObserver: NSObjectProtocol?

    /// M12 Gap 1 (agent picker): keeps `agents` mirrored to
    /// `AgentManager.shared.$agents` so the toolbar's `AgentPill` dropdown
    /// always reflects creates/deletes/renames made in Settings → Agents.
    /// Mirrors the upstream `agentsCancellable` (the AS `ChatWindowState`
    /// subscribes the same way; that path is excluded on Intel).
    private var agentsCancellable: AnyCancellable?

    /// M13 Schedules follow-up (Renée 2026-06-04): keeps the sidebar's session
    /// list reactive to `ChatSessionsManager.shared.$sessions`. Mirrors the
    /// upstream `sessionsCancellable` (the AS path subscribes the same way;
    /// it was missing on Intel). Without it, sessions saved outside this
    /// window — a headless scheduled run, a stream landing in a sibling
    /// window — only appeared after a manual refresh (switching agents).
    private var sessionsCancellable: AnyCancellable?

    var activeAgent: Agent { cachedActiveAgent }
    var themeId: UUID? { nil }

    init(windowId: UUID, agentId: UUID, sessionData: ChatSessionData? = nil) {
        self.windowId = windowId
        self.agentId = agentId
        self.session = ChatSession()
        self.theme = ThemeManager.shared.currentTheme
        self.filteredSessions = ChatSessionsManager.shared.sessions(for: agentId)
        self.session.windowState = self
        self.session.agentId = agentId
        self.session.onSessionChanged = { [weak self] in
            self?.refreshSessions()
        }
        observeThemeChanges()
        observeAgents()
        observeSessionsManager()
    }

    init(windowId: UUID, executionContext: Any? = nil) {
        self.windowId = windowId
        self.agentId = AgentManager.shared.activeAgentId
        self.session = ChatSession()
        self.theme = ThemeManager.shared.currentTheme
        self.filteredSessions = ChatSessionsManager.shared.sessions(for: agentId)
        self.session.agentId = agentId
        observeThemeChanges()
        observeAgents()
        observeSessionsManager()
    }

    /// Stay subscribed to the sessions store so the sidebar refreshes when a
    /// session is saved/deleted/renamed anywhere — including headless
    /// scheduled runs. Mirrors the upstream observer (ChatWindowState.swift
    /// AS branch); `dropFirst` skips the seed value we already read in `init`.
    private func observeSessionsManager() {
        sessionsCancellable = ChatSessionsManager.shared.$sessions
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshSessions() }
    }

    /// Seed `agents` from `AgentManager` and stay subscribed to its
    /// `@Published` list. Also refreshes the per-agent caches the chat
    /// header reads (`cachedActiveAgent`, `cachedAgentDisplayName`,
    /// `cachedSystemPrompt`).
    private func observeAgents() {
        refreshAgents()
        agentsCancellable = AgentManager.shared.$agents
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAgents() }
    }

    /// Mirror the live agent list + recompute the active-agent caches.
    private func refreshAgents() {
        agents = AgentManager.shared.agents
        cachedActiveAgent = agents.first { $0.id == agentId } ?? .default
        cachedAgentDisplayName =
            cachedActiveAgent.name.isEmpty ? "Assistant" : cachedActiveAgent.name
        cachedSystemPrompt = AgentManager.shared.effectiveSystemPrompt(for: agentId)
    }

    /// Switch the window's active agent and start a fresh chat for it.
    /// Mirrors the upstream `switchAgent(to:)` (AS path, excluded on Intel):
    /// stop any speech, persist the current turns, repoint every per-agent
    /// piece of window state, then reset the session under the new agent.
    func switchAgent(to newAgentId: UUID) {
        guard newAgentId != agentId else { return }
        TTSService.shared.stop()
        if !session.turns.isEmpty { session.save() }
        agentId = newAgentId
        AgentManager.shared.setActiveAgent(newAgentId)
        refreshAgents()
        refreshTheme()
        session.reset(for: newAgentId)
        refreshSessions()
    }

    /// Subscribe to `.globalThemeChanged` so theme picks in Settings
    /// propagate to this chat window in real time. Mirrors the upstream
    /// observer in `ChatWindowState.observeAppConfigurationChanges()`
    /// (excluded on Intel) that drives the same behavior on Apple Silicon.
    private func observeThemeChanges() {
        themeObserver = NotificationCenter.default.addObserver(
            forName: .globalThemeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshTheme() }
        }
    }

    /// Re-read the active theme from `ThemeManager` and republish it.
    /// Intel uses the global `currentTheme` directly because the per-agent
    /// theme override machinery (upstream's `Self.loadTheme(for:)`) is
    /// excluded — every chat window inherits the user's picked theme
    /// regardless of which agent is active.
    func refreshTheme() {
        let newTheme = ThemeManager.shared.currentTheme
        // `@Published` deduplicates on Equatable-of-self semantics, but
        // `ThemeProtocol` isn't Equatable, so we always republish here.
        // SwiftUI's environment-key diffing inside the view layer handles
        // no-op redraws cleanly.
        theme = newTheme
    }

    func confirmCloseInBackground() { showCloseConfirmation = false }
    func confirmCloseAndStop() { showCloseConfirmation = false }
    func refreshPairedRelayAgents(discoveredAgents: [DiscoveredAgent]? = nil) {}

    func cleanup() {
        if let observer = themeObserver {
            NotificationCenter.default.removeObserver(observer)
            themeObserver = nil
        }
        agentsCancellable?.cancel()
        agentsCancellable = nil
        sessionsCancellable?.cancel()
        sessionsCancellable = nil
    }
    func startNewChat() {
        session.reset()
        refreshSessions()
    }

    /// Keep ⌘N in the open project, or in the current session's project.
    /// Intel has no per-chat folder state, so the upstream project-folder
    /// default cannot be applied here without overwriting global folder
    /// context; that slice is deliberately deferred.
    func startNewChatInCurrentProject() {
        let projectID = openProjectId ?? session.projectId
        guard let project = ProjectManager.shared.project(for: projectID) else {
            openProjectId = nil
            startNewChat()
            return
        }
        startNewChat(in: project)
    }

    func startNewChat(in project: Project) {
        openProjectId = nil
        if let defaultAgentID = project.defaultAgentId,
           defaultAgentID != agentId,
           agents.contains(where: { $0.id == defaultAgentID })
        {
            switchAgent(to: defaultAgentID)
        } else {
            startNewChat()
        }
        session.projectId = project.id
    }

    var isProjectPageVisible: Bool { openProjectId != nil }
    func loadSession(_ sessionData: ChatSessionData) {
        // Some UI surfaces may hand us a metadata-only row. Resolve the full
        // Intel session from its durable manager before loading so a later
        // incremental save cannot replace a stored transcript with an empty
        // snapshot (upstream 9af6f53d).
        let resolved = Self.resolvedSessionData(
            sessionData,
            stored: ChatSessionsManager.shared.session(for: sessionData.id)
        )
        session.load(from: resolved)
        refreshSessions()
    }

    static func resolvedSessionData(
        _ candidate: ChatSessionData, stored: ChatSessionData?
    ) -> ChatSessionData {
        candidate.turns.isEmpty ? (stored ?? candidate) : candidate
    }
    func refreshSessions() {
        filteredSessions = ChatSessionsManager.shared.sessions(for: agentId)
    }
}
#endif
