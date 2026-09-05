//
//  AppDelegate.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//  Intel fork — with HTTP server. M3 milestone.
//

import AppKit
import Combine
import SwiftUI
import os.log

private let log = Logger(subsystem: "ai.osaurus", category: "AppDelegate")

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    public static weak var shared: AppDelegate?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var managementWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    let updater = UpdaterViewModel()
    private let server = OsaurusServer()

    /// Surface mirror of upstream `AppDelegate.serverController`,
    /// read by `ConfigurationView`'s "Apply" affordances when the
    /// user mutates server-side runtime settings. Intel's actual
    /// HTTP server is the `server: OsaurusServer` above (env-var
    /// `DEEPSEEK_API_KEY` proxy via `OsaurusServer`), so this
    /// surface is a write-accepting no-op: assigning
    /// `serverController.configuration = ...` succeeds but doesn't
    /// restart anything. Surface added in M11 Phase 11.A.3.0.
    let serverController = IntelServerControllerSurface()

    private static let swiftUISettingsPlaceholderID = "com_apple_SwiftUI_Settings_window"
    private static let swiftUISettingsPlaceholderNotifications: [Notification.Name] = [
        NSWindow.didBecomeKeyNotification,
        NSWindow.didChangeOcclusionStateNotification,
    ]

    // MARK: - Launch

    public func applicationWillFinishLaunching(_ notification: Notification) {
        UncaughtExceptionLogger.install()
        AppDelegate.shared = self

        ProcessInfo.processInfo.disableAutomaticTermination(
            "Osaurus Intel — long-running"
        )

        if #available(macOS 26.0, *) {
            let hideDockIcon = ServerConfigurationStore.load()?.hideDockIcon ?? false
            NSApp.setActivationPolicy(hideDockIcon ? .accessory : .regular)
            suppressSwiftUISettingsPlaceholder()
            disableAppKitStateRestoration()
        }
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Lift the default 256-fd soft limit before the NIO server, plugin
        // host, and storage layer start opening descriptors — SwiftNIO dies
        // fatally on `kqueue(): Too many open files` (APPLE-MACOS-19T).
        FileDescriptorLimit.raiseToMaximum()

        if #unavailable(macOS 26.0) {
            let hideDockIcon = ServerConfigurationStore.load()?.hideDockIcon ?? false
            NSApp.setActivationPolicy(hideDockIcon ? .accessory : .regular)
        }

        DocumentAdaptersBootstrap.registerBuiltIns()

        Task.detached(priority: .background) {
            await StorageMaintenance.shared.start()
        }

        #if OSAURUS_INTEL
        // Intel memory: open the encrypted memory DB + prewarm the local embedder
        // so chat turns get embedded for recall and the first search isn't delayed
        // by a one-time model download.
        Task.detached(priority: .background) {
            await MemorySearchService.shared.initialize()
            // Phase 2: drain any sessions that were buffered but never distilled
            // before the previous launch ended (closed mid-debounce, quit, crash).
            await MemoryService.shared.recoverOrphanedSignals()
        }

        // Background consolidation: decay, near-duplicate episode merge,
        // pinned promotion, eviction, and transcript pruning. Never ran on
        // this fork (see IntelMemoryConsolidator.swift's header for why);
        // started here, off the main actor, so a slow first pass can never
        // delay launch. The actor itself gates on `consolidationIntervalHours`
        // against a persisted last-run timestamp, so this does not mean a
        // full pass runs on every launch.
        Task.detached(priority: .background) {
            await MemoryConsolidator.shared.start()
        }
        #endif

        let launchedByCLI = ProcessInfo.processInfo.arguments.contains("--launched-by-cli")
        if !launchedByCLI {
            LoginItemService.shared.applyStartAtLogin(
                ServerConfigurationStore.load()?.startAtLogin ?? false
            )
        }

        installStatusItem()

        // Register the global chat hotkey (Carbon-based HotKeyManager, works on
        // Intel) from the persisted ChatConfiguration, so the saved chord
        // summons/toggles the chat window from anywhere. No-op if unset.
        applyChatHotkey()

        // M13 follow-up (Renée 2026-06-04): bring up the floating toast overlay
        // panel. The whole toast rendering layer was un-body-swapped on Intel;
        // without this `setup()` the panel that hosts `ToastContainerView` is
        // never created, so `ToastManager.show()` appended toasts that had
        // nowhere to render. ToastManager already loaded the persisted config
        // (enabled by default) in its initializer.
        ToastWindowController.shared.setup()

        // Pre-warm the open-panel machinery. The first NSOpenPanel init in a
        // process loads the remote file-picker (ViewBridge) service, which can
        // take seconds cold — reported as a hang when it happens on the user's
        // click (folder selection, file attach). Creating one throwaway panel
        // now moves that one-time cost to launch idle time, a few seconds in,
        // when the user isn't mid-interaction. Must run on the main thread —
        // NSOpenPanel is main-thread-only, so the cost can't be moved off it,
        // only moved earlier.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            _ = NSOpenPanel()
        }

        #if DEBUG
            MainThreadWatchdog.shared.start()
        #endif

        let serverStartupTask = Task { @MainActor in
            let config = ServerConfigurationStore.load() ?? .default
            let serverConfig = OsaurusServer.Config(
                host: "127.0.0.1",
                port: config.port,
                trustLoopback: true
            )
            do {
                try await server.start(serverConfig, serverConfiguration: config)
                NSLog("[Osaurus Intel] HTTP server started on port \(config.port)")
            } catch {
                NSLog("[Osaurus Intel] Server start failed: \(error)")
            }

            do {
                try await MCPBridge.shared.start()
                NSLog("[Osaurus Intel] MCP server started")
            } catch {
                NSLog("[Osaurus Intel] MCP start failed: \(error)")
            }

            // M12 follow-up (Renée 2026-06-03): auto-reconnect enabled remote
            // MCP providers on launch (the real app does this at startup; the
            // wiring was missing on Intel). Without it, a provider stays
            // disconnected after relaunch — its tools never register, so the
            // chat + the agent capability picker can't see them.
            await MCPProviderManager.shared.connectEnabledProviders()
            NSLog("[Osaurus Intel] MCP providers reconnected")

            // M13 Schedules restore (Renée 2026-06-03): start the cron loop so
            // scheduled agents fire headless. The first iteration does cold-start
            // catch-up (any row whose scheduled_at already passed runs now), then
            // it polls the scheduler DB. Mirrors the Apple Silicon startup.
            NextRunScheduler.shared.start()
            NSLog("[Osaurus Intel] NextRunScheduler started")

            // M9 Watchers restore (Renée 2026-06-04): instantiate WatcherManager
            // so its FSEvents stream for all enabled watchers starts at launch
            // (its init calls startAllEnabledWatchers). On change it dispatches
            // through the same TaskDispatcher pipeline as Schedules. Without this
            // touch, the manager wouldn't exist until the Watchers tab is opened.
            _ = WatcherManager.shared
            NSLog("[Osaurus Intel] WatcherManager started with \(WatcherManager.shared.watchers.count) watcher(s)")

            // M9 Phase C–E (Renée 2026-06-04/05): scan ~/.osaurus-intel/Tools at
            // launch so native plugins load and their tools register into the
            // agent ToolRegistry immediately — available in chat without opening
            // the Plugins tab. loadAll() also fires the self-test / test-call
            // diagnostics when OSAURUS_INTEL_PLUGIN_SELFTEST / _TESTCALL are set.
            await PluginManager.shared.loadAll()
            NSLog("[Osaurus Intel] plugin scan complete (\(PluginManager.shared.loadedPlugins.count) loaded)")
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)

            if #available(macOS 26.0, *) {
                sweepSwiftUISettingsPlaceholder()
            }

            showChatWindow()

            if #available(macOS 26.0, *) {
                for name in Self.swiftUISettingsPlaceholderNotifications {
                    NotificationCenter.default.removeObserver(self, name: name, object: nil)
                }
            }
        }
    }

    // MARK: - Settings Placeholder Suppression

    private func disableAppKitStateRestoration() {
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    private func suppressSwiftUISettingsPlaceholder() {
        sweepSwiftUISettingsPlaceholder()
        for name in Self.swiftUISettingsPlaceholderNotifications {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleSwiftUIPlaceholderEvent(_:)),
                name: name,
                object: nil
            )
        }
    }

    private func sweepSwiftUISettingsPlaceholder() {
        for window in NSApp.windows
        where window.identifier?.rawValue == Self.swiftUISettingsPlaceholderID {
            hidePlaceholder(window)
        }
    }

    @objc private func handleSwiftUIPlaceholderEvent(_ note: Notification) {
        guard
            let window = note.object as? NSWindow,
            window.identifier?.rawValue == Self.swiftUISettingsPlaceholderID
        else { return }
        hidePlaceholder(window)
    }

    private func hidePlaceholder(_ window: NSWindow) {
        window.orderOut(nil)
        window.setIsVisible(false)
    }

    // MARK: - Window

    @MainActor
    private func showChatWindow() {
        NSApp.unhide(nil)
        _ = NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
        focusExistingChatWindowOrCreate()
    }

    /// Bring an existing chat window forward if one is open, otherwise
    /// create a fresh one. M11 fix: previously `showChatWindow` always
    /// called `createWindow()`, so every dock-icon click (which routes
    /// through `applicationShouldHandleReopen`) spawned a NEW chat
    /// window alongside the open one. Mirror the upstream
    /// `toggleLastFocused`/`showWindow` reuse logic: prefer the last-
    /// focused window, fall back to the first open window, and only
    /// create a new one when none exist.
    @MainActor
    private func focusExistingChatWindowOrCreate() {
        let manager = ChatWindowManager.shared
        if let lastId = manager.lastFocusedWindowId, manager.windows[lastId] != nil {
            manager.showWindow(id: lastId)
        } else if let firstId = manager.windows.keys.first {
            manager.showWindow(id: firstId)
        } else {
            _ = manager.createWindow()
        }
    }

    /// Menu-bar popover "Ask AI" action: dismiss the popover, then focus or
    /// open a chat window. (M12 follow-up — rich Intel status panel.)
    ///
    /// The window work is deferred to the next runloop tick: opening/creating
    /// a chat window synchronously from inside the popover's own SwiftUI button
    /// (while `performClose` is tearing the hosting view down) crashed the app.
    public func openChatFromStatusPanel() {
        popover?.performClose(nil)
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.focusExistingChatWindowOrCreate()
        }
    }

    /// Dismiss the menu-bar popover (used by its quick-action buttons before
    /// opening Settings, etc.).
    public func dismissStatusPopover() {
        popover?.performClose(nil)
    }

    // MARK: - Reopen

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            // `flag` is true when AppKit already sees a visible window;
            // in that case just re-activate without touching the window
            // set. When false (all windows closed/hidden, or only the
            // status-bar item is alive), focus an existing hidden window
            // or create one.
            if flag {
                NSApp.unhide(nil)
                _ = NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
            } else {
                showChatWindow()
            }
        }
        return true
    }

    // MARK: - Dock Menu

    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "About Osaurus", action: #selector(dockAbout), keyEquivalent: ""))
        return menu
    }

    @objc private func dockAbout() {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let versionLine =
            OsaurusBuildInfo.upstreamShortLabel.map { "\(shortVersion) · \($0)" } ?? shortVersion
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Osaurus",
            .applicationVersion: versionLine,
            .version: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
        ])
    }

    // MARK: - Terminate

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NSApp.reply(toApplicationShouldTerminate: true)
        return .terminateLater
    }

    public func applicationWillTerminate(_ notification: Notification) {
        NSLog("Osaurus (Intel) terminating")
        Task { @MainActor in
            await MCPBridge.shared.stop()
            await server.stop()
        }
        SharedConfigurationService.shared.remove()
    }

    // MARK: - Status Item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = NSImage(named: "osaurus") {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "Osaurus"
            }
            button.toolTip = "Osaurus (Intel)"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem = item
    }

    @objc private func togglePopover(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        showPopover()
    }

    public func showPopover() {
        guard let statusButton = statusItem?.button else { return }
        if let popover, popover.isShown {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        popover.contentViewController = NSHostingController(rootView: IntelStatusPanelView())
        self.popover = popover
        popover.show(relativeTo: statusButton.bounds, of: statusButton, preferredEdge: .minY)
        // ensure popover window can join all spaces and appear over full screen apps
        if let popoverWindow = popover.contentViewController?.view.window {
            popoverWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // Key the popover's own window instead of activating the app:
            // `NSApp.activate` while another app owns a full-screen space
            // deactivates that app, the auto-revealed menu bar retracts, and
            // the transient popover closes with it.
            popoverWindow.makeKey()
        }
    }

    @MainActor
    public func showManagementWindow(
        initialTab: ManagementTab? = nil,
        deeplinkAgentId: UUID? = nil
    ) {
        NSApp.unhide(nil)
        _ = NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)

        // Re-use the existing window if we already opened one this
        // session — Cmd+, on a window that's already open should bring
        // it forward, not spawn a duplicate.
        if let existing = managementWindow {
            if let tab = initialTab {
                ManagementStateManager.shared.selectedTab = tab
            }
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let root = ManagementView(
            initialTab: initialTab,
            deeplinkAgentId: deeplinkAgentId
        )
        .environmentObject(updater)
        // ServerView + IdentityView (Group A/B, M11) declare
        // `@EnvironmentObject var server: ServerController`. SwiftUI
        // resolves environment objects lazily, so IdentityView survived
        // without this (it only touches `server` in a key-rotation
        // method), but ServerView reads `server.serverHealth` in its
        // body and crashed the window on open ("No ObservableObject of
        // type ServerController found"). Inject the shared instance so
        // both are satisfied.
        .environmentObject(ServerController.shared)

        // Mirror the upstream `WindowManager.createWindow` construction
        // order: build the window with an explicit `contentRect` first,
        // attach the hosting controller second, then call
        // `layoutSubtreeIfNeeded` + a final `setContentSize` so the
        // SwiftUI tree doesn't render against a 0x0 frame on first show
        // (which produced an empty black window in Phase 11.0's first
        // launch). See `Packages/OsaurusCore/Managers/WindowManager.swift`
        // L257-326 for the upstream reference (excluded on Intel but
        // readable on disk).
        let defaultSize = NSSize(width: 1000, height: 700)
        let host = NSHostingController(rootView: root)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Osaurus Settings"
        window.minSize = NSSize(width: 900, height: 640)
        window.isReleasedWhenClosed = false
        window.isRestorable = false

        // Match the chat window's inline-traffic-light chrome: a transparent,
        // title-less titlebar so the SwiftUI content paints to the top edge
        // instead of sitting under a separate solid macOS title bar. SwiftUI
        // still insets its content for the titlebar's safe area, so the traffic
        // lights float over the sidebar's top without overlapping content
        // (same contract as `ChatWindowManager.createChatPanel`).
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // Phase 11.0-ter: mirror the appearance + opacity + background
        // contract that `ChatWindowManager.createChatPanel` sets on the
        // chat window (which renders correctly on Intel). Without
        // these three lines the Settings window was painting solid
        // black: SwiftUI's semantic colors (`.foregroundStyle(.tertiary)`
        // in `AppleSiliconOnlyTab`, `theme.primaryBackground` etc.)
        // were resolving against an indeterminate appearance, and the
        // window's default transparent background showed through to
        // nothing. Pinning the appearance to the current theme's
        // light/dark mode forces SwiftUI to pick the right colors.
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.appearance = NSAppearance(
            named: ThemeManager.shared.currentTheme.isDark ? .darkAqua : .aqua
        )

        window.contentViewController = host

        // Pre-layout to avoid jank + force-set the size again so the
        // first paint uses the intended dimensions.
        host.view.layoutSubtreeIfNeeded()
        window.setContentSize(defaultSize)

        window.center()
        window.makeKeyAndOrderFront(nil)
        managementWindow = window
    }

    // MARK: - NSPopoverDelegate

    public func popoverDidClose(_ notification: Notification) {
        log.debug("Popover closed")
    }

    // MARK: - Configuration View Surface
    //
    // Called from `ConfigurationView`'s hotkey picker after a new key chord is
    // captured, and once at launch. Registers the global hotkey via the
    // (un-excluded) Carbon-based `HotKeyManager` — architecture-independent, so
    // it works on Intel. The handler toggles the chat window (show/hide/create)
    // via `ChatWindowManager.toggleLastFocused`. A nil hotkey unregisters.
    @MainActor
    public func applyChatHotkey() {
        let hk = ChatConfiguration.shared.hotkey
        NSLog("[Osaurus] applyChatHotkey: hotkey=\(hk?.displayString ?? "nil")")
        HotKeyManager.shared.register(hotkey: hk) {
            NSLog("[Osaurus] hotkey handler → toggleLastFocused")
            ChatWindowManager.shared.toggleLastFocused()
        }
    }

    /// Server → Settings tab revival (2026-09-04, Renée): persists
    /// `config` to `server.json` and stops + restarts the live
    /// `OsaurusServer` in place so a changed port / CORS allow-list /
    /// request-body cap takes effect without quitting the app. Intel's
    /// HTTP server is loopback-only by design — this always binds
    /// `127.0.0.1` with `trustLoopback: true`, mirroring the launch-time
    /// config in `applicationDidFinishLaunching`. Called by the Intel
    /// `ServerController` stub's `restartServer()`.
    @MainActor
    func applyServerConfiguration(_ config: ServerConfiguration) async {
        ServerConfigurationStore.save(config)
        await server.stop()
        let serverConfig = OsaurusServer.Config(
            host: "127.0.0.1",
            port: config.port,
            trustLoopback: true
        )
        do {
            try await server.start(serverConfig, serverConfiguration: config)
            NSLog("[Osaurus Intel] HTTP server restarted on port \(config.port)")
        } catch {
            NSLog("[Osaurus Intel] Server restart failed: \(error)")
        }
    }
}

// MARK: - Intel Server Controller Surface
//
// Tiny mirror of upstream `ServerController`'s `configuration: Any?`
// setter, read by `ConfigurationView`'s "Apply server settings"
// affordance. Intel runs `OsaurusServer` directly from `AppDelegate`
// without a separate controller; the surface accepts assignments
// silently so the view's bindings type-check. Added in M11 Phase
// 11.A.3.0.
public final class IntelServerControllerSurface {
    public var configuration: Any?

    init(configuration: Any? = nil) {
        self.configuration = configuration
    }
}

// MARK: - Intel Status Panel (menu-bar popover)
//
// M12 follow-up (Renée 2026-06-03): the rich menu-bar card. The upstream
// `StatusPanelView` is built for local-server lifecycle (start/stop/restart,
// editable port, voice/VAD, model status) — none of which fits the Intel
// always-on cloud server, so restoring it faithfully would mean gating half
// the view. This is a self-contained Intel card mirroring the original's
// visual: app icon, name + version + Intel badge + running dot, server URL
// with copy, live CPU/RAM gauges (SystemMonitorService, NOT excluded), and
// the Ask AI / Settings / Quit quick actions.
struct IntelStatusPanelView: View {
    @ObservedObject private var monitor = SystemMonitorService.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var taskBanner = IntelTaskBanner.shared
    @State private var copied = false

    private var theme: ThemeProtocol { themeManager.currentTheme }
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
    /// Reads the live port from `ServerController.shared` rather than a
    /// hardcoded literal — the Server → Settings tab can now change and
    /// persist the port, so a stale constant here would lie to the user.
    private var serverURL: String { "http://127.0.0.1:\(ServerController.shared.port)" }

    var body: some View {
        ZStack {
            theme.primaryBackground
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                header
                if let entry = taskBanner.entry {
                    taskRow(entry)
                }
                resourceCard
                actionBar
            }
            .padding(16)
        }
        .frame(width: 320, height: taskBanner.entry == nil ? 184 : 234)
        .environment(\.theme, theme)
        .tint(theme.accentColor)
    }

    // MARK: Background-task row (M13 — Intel task indicator)

    /// Persistent row tracking the most recent background/scheduled task. The
    /// upstream NotchView indicator is amputated on Intel; this is its
    /// replacement surface. Stays put after completion until the user dismisses
    /// it (the × button) or a new task replaces it.
    @ViewBuilder
    private func taskRow(_ entry: IntelTaskBanner.Entry) -> some View {
        HStack(spacing: 8) {
            // Tapping the body opens the task's chat session, then clears the
            // row. The dismiss × is a separate button so the two tap targets
            // don't collide.
            Button {
                openTaskSession(entry)
            } label: {
                HStack(spacing: 8) {
                    switch entry.status {
                    case .running:
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    case .completed:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(theme.successColor)
                    case .failed:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(theme.errorColor)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                        Text(taskStatusText(entry.status))
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open this conversation")

            Button {
                IntelTaskBanner.shared.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.07))
                )
        )
    }

    /// Open the chat window for a task's session (loaded from the persisted
    /// store), then clear the card row. Falls back to dismissing the popover
    /// even if the session can't be found (e.g. an empty run).
    private func openTaskSession(_ entry: IntelTaskBanner.Entry) {
        AppDelegate.shared?.dismissStatusPopover()
        if let data = ChatSessionsManager.shared.session(for: entry.id) {
            _ = ChatWindowManager.shared.createWindow(
                agentId: data.agentId,
                sessionData: data
            )
            NSApp.activate(ignoringOtherApps: true)
        }
        IntelTaskBanner.shared.dismiss()
    }

    private func taskStatusText(_ status: IntelTaskBanner.Status) -> String {
        switch status {
        case .running: return "Running…"
        case .completed: return "Finished"
        case .failed: return "Failed"
        }
    }

    // MARK: Header
    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onTapGesture {
                    AppDelegate.shared?.dismissStatusPopover()
                    AppDelegate.shared?.showManagementWindow(initialTab: .server)
                }
                .help("Open Server settings")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Osaurus")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(theme.primaryText)
                    Text("v\(appVersion)")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                    Text("Intel")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(theme.secondaryBackground))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    Circle()
                        .fill(theme.successColor)
                        .frame(width: 8, height: 8)
                        .help("Server running")
                }
                HStack(spacing: 6) {
                    Text(serverURL)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(serverURL, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(copied ? theme.successColor : theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Copy server URL")
                }
            }
        }
    }

    // MARK: Resource card
    private var resourceCard: some View {
        HStack(spacing: 16) {
            gauge(icon: "cpu", label: "CPU", value: monitor.cpuUsage)
            gauge(icon: "memorychip", label: "RAM", value: monitor.memoryUsage)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.secondaryBackground.opacity(0.6))
        )
    }

    private func gauge(icon: String, label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(Int(value.rounded()))%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(value > 85 ? theme.warningColor : theme.successColor)
            }
            .foregroundColor(theme.secondaryText)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.primaryText.opacity(0.1))
                    Capsule()
                        .fill(value > 85 ? theme.warningColor : theme.successColor)
                        .frame(width: geo.size.width * CGFloat(min(max(value, 0), 100) / 100))
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Action bar
    /// The chat user-bubble color (accent or custom bubble color at its
    /// configured opacity) — used to tint the menu-card action buttons so they
    /// match the conversation bubbles instead of the darker `buttonBackground`.
    private var bubbleColor: Color {
        (theme.userBubbleColor ?? theme.accentColor).opacity(theme.userBubbleOpacity)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            askAIButton
            Spacer()
            CircularIconButton(systemName: "gearshape", help: "Settings", fillColor: bubbleColor) {
                AppDelegate.shared?.dismissStatusPopover()
                AppDelegate.shared?.showManagementWindow()
            }
            CircularIconButton(systemName: "questionmark.circle", help: "Documentation", fillColor: bubbleColor) {
                if let url = URL(string: "https://docs.osaurus.ai/") {
                    NSWorkspace.shared.open(url)
                }
            }
            CircularIconButton(systemName: "power", help: "Quit", fillColor: bubbleColor) {
                NSApp.terminate(nil)
            }
        }
    }

    private var askAIButton: some View {
        Button {
            AppDelegate.shared?.openChatFromStatusPanel()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                Text("Ask AI").font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [theme.accentColor, theme.accentColor.opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Open chat")
    }
}
