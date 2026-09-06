#if !OSAURUS_INTEL
//
//  ChatWindowManager.swift
//  osaurus
//
//  Manages multiple chat windows, each representing an independent session.
//  Handles window lifecycle, focus tracking, and VAD routing.
//

import AppKit
import Combine
import SwiftUI

/// Represents an active chat window with its associated session
public struct ChatWindowInfo: Identifiable, Sendable {
    public let id: UUID
    public let agentId: UUID
    public let sessionId: UUID?
    public let createdAt: Date

    public init(id: UUID = UUID(), agentId: UUID, sessionId: UUID? = nil, createdAt: Date = Date()) {
        self.id = id
        self.agentId = agentId
        self.sessionId = sessionId
        self.createdAt = createdAt
    }
}

/// Manages multiple chat windows in the application
@MainActor
public final class ChatWindowManager: NSObject, ObservableObject {
    public static let shared = ChatWindowManager()

    // MARK: - Published State

    /// All active chat windows
    @Published public private(set) var windows: [UUID: ChatWindowInfo] = [:]

    /// The last focused chat window ID (for hotkey toggle)
    @Published public private(set) var lastFocusedWindowId: UUID?

    // MARK: - Private State

    private var nsWindows: [UUID: NSWindow] = [:]
    private var windowDelegates: [UUID: ChatWindowDelegate] = [:]
    private var windowStates: [UUID: ChatWindowState] = [:]
    private var sessionCallbacks: [UUID: () -> Void] = [:]

    /// Sleep/wake observers on `NSWorkspace.shared.notificationCenter`.
    /// Held so we can detach them in `deinit`. Pause the greeting pool
    /// on sleep so a closed laptop doesn't keep firing background
    /// inferences against the GPU.
    nonisolated(unsafe) private var sleepObserver: NSObjectProtocol?
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?

    private override init() {
        super.init()
        installSleepWakeObservers()
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        if let token = sleepObserver { nc.removeObserver(token) }
        if let token = wakeObserver { nc.removeObserver(token) }
    }

    /// Hook NSWorkspace's sleep/wake notifications to the pool's
    /// pause/resume seam. Notifications from `NSWorkspace` arrive on
    /// the main thread, but the pool is an actor so we hop through
    /// `Task` to call into it.
    private func installSleepWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await GenerativeGreetingPool.shared.pause() }
        }
        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await GenerativeGreetingPool.shared.resume() }
        }
    }

    // MARK: - Public API

    /// Create a new chat window with default agent
    /// - Parameters:
    ///   - agentId: The agent for this window (defaults to active agent)
    ///   - showImmediately: Whether to show the window immediately (default: true)
    /// - Returns: The window identifier
    @discardableResult
    public func createWindow(agentId: UUID? = nil, showImmediately: Bool = true) -> UUID {
        return createWindowInternal(agentId: agentId, sessionData: nil, showImmediately: showImmediately)
    }

    /// Create a new chat window with existing session data
    /// - Parameters:
    ///   - agentId: The agent for this window (defaults to active agent)
    ///   - sessionData: Optional existing session to load
    ///   - showImmediately: Whether to show the window immediately (default: true)
    /// - Returns: The window identifier
    @discardableResult
    func createWindow(
        agentId: UUID? = nil,
        sessionData: ChatSessionData?,
        showImmediately: Bool = true
    ) -> UUID {
        return createWindowInternal(agentId: agentId, sessionData: sessionData, showImmediately: showImmediately)
    }

    /// Internal implementation for creating windows
    private func createWindowInternal(
        agentId: UUID?,
        sessionData: ChatSessionData?,
        showImmediately: Bool
    ) -> UUID {
        let windowId = UUID()
        let effectiveAgentId = agentId ?? AgentManager.shared.activeAgentId

        let info = ChatWindowInfo(
            id: windowId,
            agentId: effectiveAgentId,
            sessionId: sessionData?.id,
            createdAt: Date()
        )

        windows[windowId] = info

        // Create the actual NSWindow
        let window = createNSWindow(
            windowId: windowId,
            agentId: effectiveAgentId,
            sessionData: sessionData
        )

        nsWindows[windowId] = window

        // Show the window if requested
        if showImmediately {
            showWindow(id: windowId)
        }

        print(
            "[ChatWindowManager] Created window \(windowId) for agent \(effectiveAgentId) (shown: \(showImmediately))"
        )

        return windowId
    }

    /// Stop all active sessions (chat and work) across all windows.
    /// Called during app termination to prevent crashes from in-flight inference.
    public func stopAllSessions() {
        for (_, state) in windowStates {
            state.cleanup()
        }
    }

    /// Close a chat window by ID
    public func closeWindow(id: UUID) {
        guard let window = nsWindows[id] else {
            print("[ChatWindowManager] No window found for ID \(id)")
            return
        }

        // Check if we should allow the close (may show background task dialog)
        guard shouldAllowClose(id: id) else {
            return
        }

        // Close will trigger the delegate which handles cleanup
        window.close()
    }

    /// Gate the close: if the session is mid-stream and not already
    /// detached to a background task, surface the in-chat confirmation
    /// overlay and tell AppKit to keep the window open. The user's pick
    /// (Continue in Background / Stop and Close) re-enters via
    /// `closeWindow(id:)`, which now passes this gate.
    private func shouldAllowClose(id: UUID) -> Bool {
        guard let state = windowStates[id] else { return true }
        if BackgroundTaskManager.shared.isWindowDetachedToBackground(windowId: id) {
            return true
        }
        guard state.session.isStreaming else { return true }
        state.showCloseConfirmation = true
        return false
    }

    /// Show/focus a window by ID
    public func showWindow(id: UUID) {
        guard let window = nsWindows[id] else {
            print("[ChatWindowManager] No window found for ID \(id)")
            return
        }

        // Unhide app if hidden
        NSApp.unhide(nil)

        // Deminiaturize if needed
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        // Activate app and bring this specific window forward
        _ = NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
        NSApp.activate(ignoringOtherApps: true)

        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)

        // Update last focused
        lastFocusedWindowId = id
    }

    /// Hide a window by ID
    public func hideWindow(id: UUID) {
        guard let window = nsWindows[id] else { return }
        // Drop any cached AI-generated empty-state content so re-opening
        // the window pops a fresh entry from `GenerativeGreetingPool`
        // instead of flashing the previous session's greeting before
        // the trigger replaces it. Idempotent — clearing an already
        // `.idle` session is a no-op.
        if let state = windowStates[id] {
            state.session.resetGenerativeGreeting()
        }
        // Tell the pool the user no longer has THIS window's agent on
        // screen so the 5-min ticker stops topping up its cache. The
        // pool scopes the clear to the matching agent so a second
        // visible window for a different agent keeps its active
        // pointer; same-agent multi-window is rare enough that any
        // residual over-clearing is recovered on the next empty-state
        // appearance via `setActive`.
        if let info = windows[id] {
            let agentId = info.agentId
            Task { await GenerativeGreetingPool.shared.clearActive(agentId: agentId) }
        }
        window.orderOut(nil)
        print("[ChatWindowManager] Hid window \(id)")
    }

    /// Toggle the last focused window (or create new if none exist)
    public func toggleLastFocused() {
        if let lastId = lastFocusedWindowId, let window = nsWindows[lastId] {
            // smart toggle: only hide if the window is already visible, frontmost, and the app is active
            // otherwise, toggling should just bring it to the front
            let isFrontmost = window.isVisible && window.isKeyWindow && NSApp.isActive

            if isFrontmost {
                hideWindow(id: lastId)
            } else {
                showWindow(id: lastId)
            }
        } else if let firstId = windows.keys.first {
            // No last focused, show first available
            showWindow(id: firstId)
        } else {
            // No windows exist, create new one
            createWindow()
        }
    }

    /// Find windows by agent ID
    public func findWindows(byAgentId agentId: UUID) -> [ChatWindowInfo] {
        windows.values.filter { $0.agentId == agentId }
    }

    /// Find a window by session ID
    public func findWindow(bySessionId sessionId: UUID) -> ChatWindowInfo? {
        windows.values.first { $0.sessionId == sessionId }
    }

    /// Check if any windows are visible
    public var hasVisibleWindows: Bool {
        nsWindows.values.contains { $0.isVisible }
    }

    /// True when any open chat session is currently streaming a model
    /// response. Read by `GenerativeGreetingPool` to defer background
    /// refills while an interactive turn is in flight — both calls
    /// share the same MLX context and unboxing them concurrently
    /// degrades token-per-second on the user's active conversation.
    public var isAnySessionStreaming: Bool {
        windowStates.values.contains { $0.session.isStreaming }
    }

    /// Get the count of active windows
    public var windowCount: Int {
        windows.count
    }

    /// Check if a specific window exists
    public func windowExists(id: UUID) -> Bool {
        windows[id] != nil
    }

    /// Get the NSWindow for a specific window ID (for event matching)
    public func getNSWindow(id: UUID) -> NSWindow? {
        nsWindows[id]
    }

    /// Get window info by ID
    public func windowInfo(id: UUID) -> ChatWindowInfo? {
        windows[id]
    }

    /// Get the window state for a specific window (for accessing session/agent)
    func windowState(id: UUID) -> ChatWindowState? {
        windowStates[id]
    }

    /// Returns the set of local model names selected by currently-open chat
    /// windows. Used as a "keep loaded for next interaction" hint for GC.
    ///
    /// Safety against unloading a model mid-stream is enforced by `ModelLease`
    /// inside `ModelRuntime.unloadModelsNotIn` — this set only needs to cover
    /// the UX heuristic of "the user still has a window open with this model
    /// selected, don't pay reload cost on their next keystroke".
    func activeLocalModelNames() -> Set<String> {
        Set(
            windowStates.values.compactMap { state in
                guard let model = state.session.selectedModel,
                    let found = ModelManager.findInstalledModel(named: model)
                else { return nil }
                return found.name
            }
        )
    }

    /// Set a callback to be invoked when window is about to close (for session saving)
    public func setCloseCallback(for windowId: UUID, callback: @escaping () -> Void) {
        sessionCallbacks[windowId] = callback
    }

    /// Set window pinned (float on top) state
    public func setWindowPinned(id: UUID, pinned: Bool) {
        guard let window = nsWindows[id] else { return }
        window.level = pinned ? .floating : .normal
        print("[ChatWindowManager] Window \(id) pinned: \(pinned)")
    }

    /// Focus all existing windows (for dock icon click)
    public func focusAllWindows() {
        guard !windows.isEmpty else { return }

        NSApp.unhide(nil)
        _ = NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)

        // Bring all windows to front without churn on key window state
        for (_, window) in nsWindows {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.orderFrontRegardless()
        }

        // Make the intended window key once
        if let lastId = lastFocusedWindowId, let window = nsWindows[lastId] {
            window.makeKeyAndOrderFront(nil)
        } else if let firstWindow = nsWindows.values.first {
            firstWindow.makeKeyAndOrderFront(nil)
        }

        print("[ChatWindowManager] Focused all \(windows.count) windows")
    }

    // MARK: - Background Task Window Support

    /// Lazily create a window from an `ExecutionContext`, reusing its sessions.
    /// Called when the user taps "View" on a dispatch toast.
    @discardableResult
    public func createWindowForContext(
        _ context: ExecutionContext,
        showImmediately: Bool = true
    ) -> UUID {
        let windowId = UUID()
        let windowState = ChatWindowState(windowId: windowId, executionContext: context)

        windows[windowId] = ChatWindowInfo(
            id: windowId,
            agentId: context.agentId,
            createdAt: Date()
        )

        let window = createNSWindowForBackgroundTask(windowId: windowId, windowState: windowState)
        nsWindows[windowId] = window
        windowStates[windowId] = windowState

        if showImmediately { showWindow(id: windowId) }

        print("[ChatWindowManager] Created window \(windowId) for context \(context.id)")
        return windowId
    }

    /// Create an NSWindow for viewing a background task (reuses existing window state)
    private func createNSWindowForBackgroundTask(
        windowId: UUID,
        windowState: ChatWindowState
    ) -> NSWindow {
        // Create ChatView with the existing window state
        let chatView = ChatView(windowState: windowState)
            .environment(\.theme, windowState.theme)

        let hostingController = NSHostingController(rootView: chatView)

        let panel = createChatPanel(windowId: windowId, windowState: windowState)
        panel.contentViewController = hostingController

        applyWindowFramePersistence(panel: panel)

        return panel
    }

    // MARK: - Private Helpers

    private func createNSWindow(
        windowId: UUID,
        agentId: UUID,
        sessionData: ChatSessionData?
    ) -> NSWindow {
        // Create per-window state container (isolates from shared singletons)
        let windowState = ChatWindowState(
            windowId: windowId,
            agentId: agentId,
            sessionData: sessionData
        )
        windowStates[windowId] = windowState

        // Create ChatView with window state
        let chatView = ChatView(windowState: windowState)
            .environment(\.theme, windowState.theme)

        let hostingController = NSHostingController(rootView: chatView)

        let panel = createChatPanel(windowId: windowId, windowState: windowState)
        panel.contentViewController = hostingController

        applyWindowFramePersistence(panel: panel)

        return panel
    }

    /// Shared logic for creating the basic ChatPanel with its toolbar and delegate.
    private func createChatPanel(windowId: UUID, windowState: ChatWindowState) -> ChatPanel {
        // Calculate centered position on active screen, with offset for multiple windows
        let defaultSize = NSSize(width: 800, height: 610)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main

        // Cascade offset based on number of existing windows (25pt per window)
        // Use count - 1 so the first window starts at the base position
        let cascadeOffset = CGFloat(max(0, windows.count - 1)) * 25.0

        let initialRect: NSRect
        if let s = screen {
            let vf = s.visibleFrame
            let baseOrigin = NSPoint(
                x: vf.midX - defaultSize.width / 2,
                y: vf.midY - defaultSize.height / 2
            )
            var origin = NSPoint(
                x: baseOrigin.x + cascadeOffset,
                y: baseOrigin.y - cascadeOffset
            )
            if origin.x + defaultSize.width > vf.maxX {
                origin.x = vf.minX + 50
            }
            if origin.y < vf.minY {
                origin.y = vf.maxY - defaultSize.height - 50
            }
            initialRect = NSRect(origin: origin, size: defaultSize)
        } else {
            initialRect = NSRect(origin: .zero, size: defaultSize)
        }

        let panel = ChatPanel(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.isReleasedWhenClosed = false
        // No AppKit snapshot restoration. Frame autosave (below, via
        // `applyWindowFramePersistence`) handles position persistence.
        panel.isRestorable = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .managed]

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.appearance = NSAppearance(named: windowState.theme.isDark ? .darkAqua : .aqua)

        let toolbar = NSToolbar(identifier: "ChatToolbar")
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        // Anchor the agent pill at the toolbar's geometric center; without
        // this it drifts off-axis because of the asymmetric leading/trailing
        // items and the traffic-light area.
        toolbar.centeredItemIdentifier = ChatToolbarDelegate.agentItem

        let toolbarDelegate = ChatToolbarDelegate(windowState: windowState, session: windowState.session)
        toolbar.delegate = toolbarDelegate
        panel.chatToolbarDelegate = toolbarDelegate
        panel.toolbar = toolbar
        panel.toolbarStyle = .unified

        // Set up delegate for lifecycle events
        let delegate = ChatWindowDelegate(windowId: windowId, manager: self)
        windowDelegates[windowId] = delegate
        panel.delegate = delegate

        return panel
    }

    /// Common method for window frame persistence and cascading.
    private func applyWindowFramePersistence(panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let cascadeOffset = CGFloat(max(0, windows.count - 1)) * 25.0

        // Try to load saved frame for ALL windows to get the user's preferred size
        _ = panel.setFrameUsingName(WindowFrameAutosaveKey.chat.rawValue)

        if windows.count > 1 {
            // Recalculate origin for subsequent windows in case the size changed from default
            let currentSize = panel.frame.size
            if let s = screen {
                let vf = s.visibleFrame
                let baseOrigin = NSPoint(
                    x: vf.midX - currentSize.width / 2,
                    y: vf.midY - currentSize.height / 2
                )
                var origin = NSPoint(
                    x: baseOrigin.x + cascadeOffset,
                    y: baseOrigin.y - cascadeOffset
                )
                if origin.x + currentSize.width > vf.maxX {
                    origin.x = vf.minX + 50
                }
                if origin.y < vf.minY {
                    origin.y = vf.maxY - currentSize.height - 50
                }
                panel.setFrameOrigin(origin)
            }
        }

        // Only the first window will save its changes back to the slot
        if windows.count == 1 {
            panel.setFrameAutosaveName(WindowFrameAutosaveKey.chat.rawValue)
        }
    }

    // Called by delegate when window becomes key
    fileprivate func windowDidBecomeKey(id: UUID) {
        lastFocusedWindowId = id
        print("[ChatWindowManager] Window \(id) became key")
    }

    // Called by delegate to determine if window should close (for Cmd+W, etc.)
    fileprivate func windowShouldClose(id: UUID) -> Bool {
        return shouldAllowClose(id: id)
    }

    // Called by delegate when window will close
    fileprivate func windowWillClose(id: UUID) {
        print("[ChatWindowManager] Window \(id) will close")

        let isDetachedToBackground = BackgroundTaskManager.shared.isWindowDetachedToBackground(windowId: id)

        // Only invoke save callback and cleanup if NOT detached to background
        // (background task needs the session to keep running)
        if !isDetachedToBackground {
            if let callback = sessionCallbacks[id] {
                callback()
            }
            windowStates[id]?.cleanup()
        }

        // Clean up all local references. BackgroundTaskState independently retains
        // the ChatWindowState it needs, so removing it here is always safe.
        sessionCallbacks.removeValue(forKey: id)
        windowDelegates.removeValue(forKey: id)
        windowStates.removeValue(forKey: id)

        let closedSessionId = windows[id]?.sessionId
        let closedAgentId = windows[id]?.agentId
        Task {
            if let sid = closedSessionId {
                PluginHostContext.invalidateSessionToolCache(sessionId: sid.uuidString)
            }
            if let aid = closedAgentId {
                // Drop any 10-second-TTL memory context snapshot so a freshly
                // opened window for the same agent rebuilds from current state.
                // Without this, a user who edits memory in window B and closes
                // window A could briefly see the stale A-era assembly on the
                // next compose pass.
                await MemoryContextAssembler.shared.invalidateCache(agentId: aid.uuidString)
            }
            let idlePolicy =
                ServerConfigurationStore.load()?.modelIdleResidencyPolicy
                ?? ServerConfiguration.default.modelIdleResidencyPolicy
            if idlePolicy == .immediately {
                let active = self.activeLocalModelNames()
                await ModelRuntime.shared.unloadModelsNotIn(active)
            }
        }

        // Sever NSWindow -> NSHostingController link so the SwiftUI view tree
        // and its @State storage are released even if the panel lingers briefly.
        nsWindows[id]?.contentViewController = nil
        nsWindows.removeValue(forKey: id)
        windows.removeValue(forKey: id)

        // Update last focused if this was the focused window
        if lastFocusedWindowId == id {
            lastFocusedWindowId = windows.keys.first
        }

        // Post notification for VAD resume
        NotificationCenter.default.post(name: .chatViewClosed, object: id)

        let msg = isDetachedToBackground ? " (detached to background)" : ""
        print("[ChatWindowManager] Window \(id) cleanup complete\(msg), remaining: \(windows.count)")
    }
}

// MARK: - Chat Panel

/// Custom panel that keeps native traffic lights and hosts a unified toolbar.
private final class ChatPanel: NSPanel {
    /// Keep toolbar delegate alive (NSToolbar's delegate is weak).
    var chatToolbarDelegate: ChatToolbarDelegate?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Chat Toolbar

/// Toolbar delegate that places each control in its own `NSToolbarItem`
/// so macOS applies native per-item styling (pill backgrounds, spacing).
@MainActor
private final class ChatToolbarDelegate: NSObject, NSToolbarDelegate {
    fileprivate static let sidebarItem = NSToolbarItem.Identifier("ChatToolbar.sidebar")
    fileprivate static let agentItem = NSToolbarItem.Identifier("ChatToolbar.agent")
    fileprivate static let actionItem = NSToolbarItem.Identifier("ChatToolbar.action")
    fileprivate static let pinItem = NSToolbarItem.Identifier("ChatToolbar.pin")

    /// Layout: sidebar on the leading edge, agent pill centered (via the
    /// toolbar's `centeredItemIdentifier`), action + pin on the trailing edge.
    /// The flexible spaces let the trailing items hug the right edge.
    /// Any stale identifiers AppKit may have persisted in user defaults
    /// fall through to `default: nil` in `itemForItemIdentifier`, which
    /// renders them as no-ops rather than crashing.
    private static let itemIdentifiers: [NSToolbarItem.Identifier] = [
        sidebarItem, .flexibleSpace, agentItem, .flexibleSpace, actionItem, pinItem,
    ]

    private weak var windowState: ChatWindowState?
    private weak var session: ChatSession?

    init(windowState: ChatWindowState, session: ChatSession) {
        self.windowState = windowState
        self.session = session
        super.init()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.itemIdentifiers
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.itemIdentifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let windowState, let session else { return nil }

        switch itemIdentifier {
        case Self.sidebarItem:
            return makeHostingItem(
                identifier: itemIdentifier,
                rootView:
                    ChatToolbarSidebarView(windowState: windowState)
            )

        case Self.agentItem:
            return makeHostingItem(
                identifier: itemIdentifier,
                rootView:
                    ChatToolbarAgentView(windowState: windowState, session: session)
            )

        case Self.actionItem:
            return makeHostingItem(
                identifier: itemIdentifier,
                rootView:
                    ChatToolbarActionView(windowState: windowState, session: session)
            )

        case Self.pinItem:
            return makeHostingItem(
                identifier: itemIdentifier,
                rootView:
                    ChatToolbarPinView(windowState: windowState)
            )

        default:
            return nil
        }
    }

    private func makeHostingItem<Content: View>(
        identifier: NSToolbarItem.Identifier,
        rootView: Content
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        item.view = hostingView
        if #available(macOS 13.0, *) {
            item.isBordered = false
        }
        return item
    }
}

// MARK: - Toolbar Item Views

/// Sidebar toggle button.
private struct ChatToolbarSidebarView: View {
    @ObservedObject var windowState: ChatWindowState

    var body: some View {
        HeaderActionButton(
            icon: "sidebar.left",
            help: windowState.showSidebar ? "Hide sidebar" : "Show sidebar",
            action: {
                withAnimation(windowState.theme.animationQuick()) {
                    windowState.showSidebar.toggle()
                }
            }
        )
        .environment(\.theme, windowState.theme)
    }
}

/// Agent selector pill that lives in the toolbar's centered slot.
private struct ChatToolbarAgentView: View {
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject var session: ChatSession

    /// Incremented by the `/agent` slash command notification to pop the
    /// agent picker open from the input card.
    @State private var openPickerTrigger: Int = 0

    var body: some View {
        AgentPill(
            agents: windowState.agents,
            activeAgentId: windowState.agentId,
            onSelectAgent: { newAgentId in
                windowState.switchAgent(to: newAgentId)
            },
            discoveredAgents: windowState.discoveredAgents,
            onSelectDiscoveredAgent: { agent in
                NotificationCenter.default.post(
                    name: .chatToolbarSelectDiscoveredAgent,
                    object: agent,
                    userInfo: ["windowId": windowState.windowId]
                )
            },
            activeDiscoveredAgent: windowState.selectedDiscoveredAgent,
            pairedRelayAgents: windowState.pairedRelayAgents,
            onSelectRelayAgent: { relay in
                NotificationCenter.default.post(
                    name: .chatToolbarSelectRelayAgent,
                    object: relay,
                    userInfo: ["windowId": windowState.windowId]
                )
            },
            activeRelayAgent: windowState.selectedRelayAgent,
            onOpenActiveAgentSettings: {
                let active = windowState.agents.first { $0.id == windowState.agentId }
                let deeplinkId = (active?.isBuiltIn == false) ? active?.id : nil
                AppDelegate.shared?.showManagementWindow(
                    initialTab: .agents,
                    deeplinkAgentId: deeplinkId
                )
            },
            openPickerTrigger: openPickerTrigger
        )
        .environment(\.theme, windowState.theme)
        .onReceive(NotificationCenter.default.publisher(for: .chatToolbarOpenAgentPicker)) { notification in
            guard let targetWindowId = notification.userInfo?["windowId"] as? UUID,
                targetWindowId == windowState.windowId
            else { return }
            openPickerTrigger &+= 1
        }
    }
}

extension Notification.Name {
    static let chatToolbarSelectDiscoveredAgent = Notification.Name("chatToolbarSelectDiscoveredAgent")
    static let chatToolbarSelectRelayAgent = Notification.Name("chatToolbarSelectRelayAgent")
    /// Posted by the `/agent` slash command to pop open the toolbar's agent
    /// picker for the window identified in `userInfo["windowId"]`.
    static let chatToolbarOpenAgentPicker = Notification.Name("chatToolbarOpenAgentPicker")
}

/// Contextual action button: settings (empty state) or new-chat plus.
private struct ChatToolbarActionView: View {
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject var session: ChatSession

    var body: some View {
        Group {
            if session.turns.isEmpty {
                SettingsButton(action: {
                    AppDelegate.shared?.showManagementWindow(initialTab: nil)
                })
            } else {
                HeaderActionButton(
                    icon: "plus",
                    help: "New chat",
                    action: { windowState.startNewChat() }
                )
            }
        }
        .environment(\.theme, windowState.theme)
    }
}

/// Pin button. Observes windowState for reactive theme updates.
private struct ChatToolbarPinView: View {
    @ObservedObject var windowState: ChatWindowState

    var body: some View {
        PinButton(windowId: windowState.windowId)
            .environment(\.theme, windowState.theme)
    }
}

// MARK: - Window Delegate

@MainActor
private final class ChatWindowDelegate: NSObject, NSWindowDelegate {
    let windowId: UUID
    weak var manager: ChatWindowManager?

    init(windowId: UUID, manager: ChatWindowManager) {
        self.windowId = windowId
        self.manager = manager
        super.init()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        manager?.windowDidBecomeKey(id: windowId)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return manager?.windowShouldClose(id: windowId) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        manager?.windowWillClose(id: windowId)
    }
}
#else

// MARK: - Intel fork: minimal ChatWindowManager stub

import AppKit
import Combine
import SwiftUI

public struct ChatWindowInfo: Identifiable, Sendable {
    public let id: UUID
    public let agentId: UUID
    public let sessionId: UUID?
    public let createdAt: Date

    public init(id: UUID = UUID(), agentId: UUID, sessionId: UUID? = nil, createdAt: Date = Date()) {
        self.id = id
        self.agentId = agentId
        self.sessionId = sessionId
        self.createdAt = createdAt
    }
}

/// Behavior of the ⌘N shortcut in the File menu. Off (default) keeps ⌘N on
/// "New Window". On, ⌘N starts a new chat in the frontmost chat window (the
/// sidebar "New Chat" action) and "New Window" moves to ⇧⌘N. Toggled in
/// Chat settings, read by the app's File menu commands. Upstream e0eeba12.
public enum NewChatShortcutSetting {
    public static let defaultsKey = "chatCmdNStartsNewChatInCurrentWindow"
}

@MainActor
public final class ChatWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    public static let shared = ChatWindowManager()

    @Published public private(set) var windows: [UUID: ChatWindowInfo] = [:]
    @Published public private(set) var lastFocusedWindowId: UUID?

    public var windowCount: Int { windows.count }
    public var hasVisibleWindows: Bool { !windows.isEmpty }

    private var nsWindows: [UUID: NSWindow] = [:]
    private var windowStates: [UUID: ChatWindowState] = [:]
    /// M12 Gap 1: retains each window's toolbar delegate (NSToolbar holds
    /// its delegate weakly, so without this the centered agent pill would
    /// vanish the moment `createWindow` returns).
    private var toolbarDelegates: [UUID: IntelChatToolbarDelegate] = [:]

    public func createWindow(agentId: UUID? = nil) -> UUID {
        // M12 Gap 1: default to the user's active agent instead of a
        // throwaway UUID, so a freshly opened window is tied to a real
        // agent (Default unless overridden) and the toolbar pill shows it.
        let resolvedAgentId = agentId ?? AgentManager.shared.activeAgentId
        let info = ChatWindowInfo(agentId: resolvedAgentId)
        windows[info.id] = info
        lastFocusedWindowId = info.id

        let state = ChatWindowState(windowId: info.id, agentId: resolvedAgentId)
        windowStates[info.id] = state

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Osaurus (Intel)"
        // Unified toolbar look that matches the Apple Silicon chat window:
        // transparent titlebar + full-size content so the SwiftUI ChatView
        // flows under the toolbar that hosts the centered agent pill.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: state.theme.isDark ? .darkAqua : .aqua)

        let toolbar = NSToolbar(identifier: "IntelChatToolbar")
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.centeredItemIdentifier = IntelChatToolbarDelegate.agentItem
        let toolbarDelegate = IntelChatToolbarDelegate(windowState: state)
        toolbar.delegate = toolbarDelegate
        toolbarDelegates[info.id] = toolbarDelegate
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // M13 follow-up (Renée 2026-06-04): host a ThemedAlertHost scoped to
        // this chat window so themed confirmations raised from inside it
        // actually render. The sidebar's delete-conversation dialog presents
        // through `ThemedAlertCenter` keyed on `@Environment(\.themedAlertScope)`;
        // without a matching host in the window's view tree the dialog had
        // nowhere to draw, so "Delete" silently no-op'd. `.chat(info.id)`
        // gives each window its own scope (no cross-window dialog bleed).
        let chatView = ChatView(windowState: state)
            .themedAlertScope(.chat(info.id))
            .overlay(ThemedAlertHost(scope: .chat(info.id)))
        window.contentView = NSHostingView(rootView: chatView)
        // M12 follow-up (Renée 2026-06-03 crashes): the manager owns each
        // window's lifecycle. `isReleasedWhenClosed = false` is deliberate —
        // with `true`, AppKit auto-released the window on close while our
        // `nsWindows` dict still held it, so (a) a later `showWindow(id:)`
        // (menu-bar "Ask AI") poked freed memory, and (b) once we added the
        // delegate to purge bookkeeping, removing our strong ref on top of
        // AppKit's release double-freed it mid-close. With `false`, our dict is
        // the sole strong ref; `windowWillClose` removes it → ARC frees the
        // window cleanly after the close stack unwinds.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        nsWindows[info.id] = window
        // Activate + front (works when summoned via hotkey from another app).
        bringToFront(window)

        return info.id
    }

    /// Open a window for a background/scheduled task's execution context.
    ///
    /// M13 Schedules restore: `BackgroundTaskManager.openTaskWindow` calls this
    /// when the user clicks to view a running scheduled task. Scheduled runs
    /// execute headless (no window), so this only backs the "view task"
    /// affordance — it reuses the battle-tested `createWindow` builder seeded
    /// with the task's agent. (Binding the window to the task's existing
    /// session content is a follow-up; the headless run has already produced
    /// its output.)
    @discardableResult
    public func createWindowForContext(
        _ context: ExecutionContext,
        showImmediately: Bool = true
    ) -> UUID {
        let id = createWindow(agentId: context.agentId)
        if !showImmediately { nsWindows[id]?.orderOut(nil) }
        return id
    }

    /// Overload that opens a window pre-loaded with a stored session.
    /// Used by AgentDetailView's history rows (un-body-swapped in M11
    /// Phase 11.A.4) to reopen a past conversation. Mirrors the upstream
    /// `createWindow(agentId:sessionData:showImmediately:)` signature.
    @discardableResult
    func createWindow(
        agentId: UUID,
        sessionData: ChatSessionData?,
        showImmediately: Bool = true
    ) -> UUID {
        let id = createWindow(agentId: agentId)
        if let sessionData, let state = windowStates[id] {
            state.loadSession(sessionData)
        }
        return id
    }

    func windowState(id: UUID) -> ChatWindowState? {
        windowStates[id]
    }

    public func focusAllWindows() {
        for (_, window) in nsWindows {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func setCloseCallback(for windowId: UUID, callback: @escaping () -> Void) {}

    public func toggleLastFocused() {
        // Toggle closed only if our chat is genuinely the frontmost window
        // right now (app active + window key). Otherwise summon it.
        if NSApp.isActive,
            let id = lastFocusedWindowId,
            let window = nsWindows[id],
            window.isKeyWindow
        {
            NSLog("[ChatWindowManager] toggleLastFocused → hide (frontmost)")
            window.orderOut(nil)
            return
        }
        if let id = lastFocusedWindowId, let window = nsWindows[id] {
            NSLog("[ChatWindowManager] toggleLastFocused → summon lastFocused")
            bringToFront(window)
        } else if let window = nsWindows.values.first {
            NSLog("[ChatWindowManager] toggleLastFocused → summon first window (count=\(nsWindows.count))")
            bringToFront(window)
        } else {
            NSLog("[ChatWindowManager] toggleLastFocused → no windows, creating one")
            _ = createWindow()
        }
    }

    public func showWindow(id: UUID) {
        guard let window = nsWindows[id] else {
            NSLog("[ChatWindowManager] showWindow: no window for id \(id)")
            return
        }
        bringToFront(window)
    }

    /// Start a new chat in the frontmost chat window, mirroring the sidebar
    /// "New Chat" button. Targets the last-focused window as long as it still
    /// exists, even when hidden, and brings it to the front first. Returns
    /// false when no chat window exists so the caller can fall back to
    /// creating a new window. Upstream e0eeba12.
    @discardableResult
    public func startNewChatInLastFocusedWindow() -> Bool {
        let targetId: UUID? =
            if let lastId = lastFocusedWindowId, windowStates[lastId] != nil {
                lastId
            } else {
                windowStates.keys.first
            }
        guard let targetId, let state = windowStates[targetId] else { return false }
        showWindow(id: targetId)
        state.startNewChat()
        return true
    }

    /// Bring a window (and the app) reliably to the front from anywhere —
    /// including from another app or over a full-screen Space. Activating the
    /// app is what makes a global-hotkey summon work from the background;
    /// `.moveToActiveSpace` makes the window follow to the current Space instead
    /// of appearing on its original (possibly hidden) one.
    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.collectionBehavior.insert(.moveToActiveSpace)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    public func closeWindow(id: UUID) {
        windows.removeValue(forKey: id)
        nsWindows[id]?.close()
        nsWindows.removeValue(forKey: id)
        windowStates[id]?.cleanup()
        windowStates.removeValue(forKey: id)
        toolbarDelegates.removeValue(forKey: id)
        if lastFocusedWindowId == id {
            lastFocusedWindowId = windows.keys.first
        }
    }

    // MARK: - NSWindowDelegate (Intel chat windows)

    private func windowId(for window: NSWindow) -> UUID? {
        nsWindows.first(where: { $0.value === window })?.key
    }

    /// Purge a closed window's bookkeeping so nothing later references the
    /// freed NSWindow. Does NOT call `window.close()` (AppKit is already
    /// closing it) or rely on the entry still being present.
    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let id = windowId(for: window)
        else { return }
        windows.removeValue(forKey: id)
        nsWindows.removeValue(forKey: id)
        windowStates[id]?.cleanup()
        windowStates.removeValue(forKey: id)
        toolbarDelegates.removeValue(forKey: id)
        if lastFocusedWindowId == id {
            lastFocusedWindowId = windows.keys.first
        }
    }

    /// Track the genuinely-focused window so "Ask AI" / dock reopen target the
    /// right one (and never a stale id).
    public func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let id = windowId(for: window)
        else { return }
        lastFocusedWindowId = id
    }

    public func findWindows(byAgentId agentId: UUID) -> [(id: UUID, info: ChatWindowInfo)] {
        windows.filter { $0.value.agentId == agentId }.map { ($0.key, $0.value) }
    }

    public func getNSWindow(id: UUID) -> NSWindow? {
        nsWindows[id]
    }

    public func activeLocalModelNames() -> Set<String> {
        Set()
    }

    public var isAnySessionStreaming: Bool { false }

    public func setWindowPinned(id: UUID, pinned: Bool) {}

    public func stopAllSessions() {
        windowStates.values.forEach { $0.cleanup() }
        windows.removeAll()
        nsWindows.removeAll()
        windowStates.removeAll()
        toolbarDelegates.removeAll()
    }
}

// MARK: - Intel Chat Toolbar (M12 Gap 1 — agent picker)

/// Hosts the centered agent pill (plus a leading sidebar toggle and a
/// trailing settings/new-chat action) in the Intel chat window's unified
/// toolbar. Mirrors the Apple Silicon `ChatToolbarDelegate` layout, scoped
/// to the Intel build because the AS delegate lives inside this file's
/// `#if !OSAURUS_INTEL` branch alongside the amputated window-lifecycle
/// machinery (BackgroundTaskManager / ModelRuntime / ServerConfigurationStore).
@MainActor
final class IntelChatToolbarDelegate: NSObject, NSToolbarDelegate {
    static let sidebarItem = NSToolbarItem.Identifier("IntelChatToolbar.sidebar")
    /// Back-to-project chip — shows the current chat's project name (when
    /// it has one) and reopens that project's detail sheet. Empty/hidden
    /// otherwise; always present in the toolbar so we don't need to
    /// reconfigure `NSToolbar`'s item set at runtime.
    static let projectItem = NSToolbarItem.Identifier("IntelChatToolbar.project")
    static let agentItem = NSToolbarItem.Identifier("IntelChatToolbar.agent")
    static let actionItem = NSToolbarItem.Identifier("IntelChatToolbar.action")

    /// Layout mirrors upstream exactly:
    ///   [sidebar, project, flexibleSpace, agent, flexibleSpace, action]
    /// where upstream's equivalent of `projectItem` is its `backItem`.
    ///
    /// The agent pill MUST be the only item between the two flexible spaces.
    /// `centeredItemIdentifier` is set to it, and putting a second item
    /// inside that group pushes the pill visibly off-centre. An earlier
    /// change moved `projectItem` next to the pill to make the chip easier
    /// to find; it did that at the cost of the centring, so the chip is
    /// back where upstream keeps it, on the leading edge.
    private static let ids: [NSToolbarItem.Identifier] = [
        sidebarItem, projectItem, .flexibleSpace, agentItem, .flexibleSpace, actionItem,
    ]

    private weak var windowState: ChatWindowState?

    init(windowState: ChatWindowState) {
        self.windowState = windowState
        super.init()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.ids
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.ids
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let windowState else { return nil }
        switch itemIdentifier {
        case Self.sidebarItem:
            return host(itemIdentifier, IntelToolbarSidebarView(windowState: windowState))
        case Self.projectItem:
            return host(
                itemIdentifier,
                IntelToolbarProjectView(windowState: windowState, session: windowState.session)
            )
        case Self.agentItem:
            return host(itemIdentifier, IntelToolbarAgentView(windowState: windowState))
        case Self.actionItem:
            return host(
                itemIdentifier,
                IntelToolbarActionView(windowState: windowState, session: windowState.session)
            )
        default:
            return nil
        }
    }

    private func host<Content: View>(
        _ identifier: NSToolbarItem.Identifier,
        _ rootView: Content
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        item.view = hosting
        item.isBordered = false
        return item
    }
}

// MARK: - Intel Toolbar Item Views

private struct IntelToolbarSidebarView: View {
    @ObservedObject var windowState: ChatWindowState

    var body: some View {
        HeaderActionButton(
            icon: "sidebar.left",
            help: windowState.showSidebar ? "Hide sidebar" : "Show sidebar",
            action: {
                withAnimation(.easeOut(duration: 0.2)) {
                    windowState.showSidebar.toggle()
                }
            }
        )
        .environment(\.theme, windowState.theme)
    }
}

/// Back-to-project toolbar chip. Renders nothing when the current chat has
/// no project; otherwise shows the project's name and routes the window's
/// main content area to the project page (`ChatWindowState.openProjectId`)
/// — a real "inside the project" state, not the old themed-alert modal
/// (`ProjectDetailView`) that left you nowhere once closed. Capsule styling
/// mirrors `AgentPill`'s pill chrome (`pillBackground`/`pillBorder` below)
/// so it reads as part of the same toolbar family.
private struct IntelToolbarProjectView: View {
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject var session: ChatSession
    @ObservedObject private var projectManager = ProjectManager.shared
    @State private var isHovered = false

    var body: some View {
        Group {
            // Hidden while a project page is open: that page draws its own
            // header with the same folder glyph and name, and the chip would
            // render straight over it — the identical overlap the agent pill
            // and action items are gated for just above. The chip is a way
            // back INTO a project from a chat; on the project page there is
            // nothing to go back to.
            if windowState.openProjectId == nil,
                let pid = session.projectId, let project = projectManager.project(for: pid)
            {
                Button(action: { windowState.openProjectId = pid }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10, weight: .medium))
                        Text(verbatim: project.name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(windowState.theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(windowState.theme.secondaryBackground.opacity(isHovered ? 0.9 : 0.65))
                    )
                }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .localizedHelp("Back to Project")
            }
        }
        .environment(\.theme, windowState.theme)
    }
}

/// Centered agent selector — the headline of M12 Gap 1. Reuses the
/// upstream `AgentPill` (un-body-swapped for Intel in this same commit).
private struct IntelToolbarAgentView: View {
    @ObservedObject var windowState: ChatWindowState
    @State private var openPickerTrigger: Int = 0

    var body: some View {
        // Bug fix: when a project page is open in the window's main
        // content area, this chat-scoped pill used to keep rendering on top
        // of it, overlapping the project title. Gating on `openProjectId`
        // mirrors `IntelToolbarProjectView`'s existing empty-else pattern
        // just below, which already collapses that item out of the toolbar
        // layout rather than leaving an invisible-but-occupied gap.
        Group {
            if windowState.openProjectId == nil {
                AgentPill(
                    agents: windowState.agents,
                    activeAgentId: windowState.agentId,
                    onSelectAgent: { windowState.switchAgent(to: $0) },
                    onOpenActiveAgentSettings: {
                        let active = windowState.agents.first { $0.id == windowState.agentId }
                        let deeplinkId = (active?.isBuiltIn == false) ? active?.id : nil
                        AppDelegate.shared?.showManagementWindow(
                            initialTab: .agents,
                            deeplinkAgentId: deeplinkId
                        )
                    },
                    openPickerTrigger: openPickerTrigger
                )
                // Bridge the `/agent` slash command into the Intel toolbar's
                // agent picker — mirrors the non-Intel branch's listener
                // (line ~810). (Renée, 2026-06-14.)
                .onReceive(NotificationCenter.default.publisher(for: .chatToolbarOpenAgentPicker)) { notification in
                    guard let targetWindowId = notification.userInfo?["windowId"] as? UUID,
                        targetWindowId == windowState.windowId
                    else { return }
                    openPickerTrigger &+= 1
                }
            }
        }
        .environment(\.theme, windowState.theme)
    }
}

private struct IntelToolbarActionView: View {
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject var session: ChatSession

    var body: some View {
        Group {
            // Bug fix: the settings gear / "+ New Chat" button used to
            // render on top of the project page's own header once a project
            // was open, overlapping its controls. Same gating pattern as
            // `IntelToolbarAgentView` above.
            if windowState.openProjectId == nil {
                if session.turns.isEmpty {
                    SettingsButton(action: {
                        AppDelegate.shared?.showManagementWindow(initialTab: nil)
                    })
                } else {
                    HeaderActionButton(
                        icon: "plus",
                        help: "New chat",
                        action: { windowState.startNewChat() }
                    )
                }
            }
        }
        .environment(\.theme, windowState.theme)
    }
}
#endif
