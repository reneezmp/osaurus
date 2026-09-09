//
//  ChatContentView.swift
//  OsaurusCore
//
//  M10.5 Phase 7: Standalone View struct for the entire chat content body.
//  Separated to break opaque type metadata chain in chatModeContent.
//  Single struct avoids the pairwise metadata cycle that plagued
//  ChatInputSection+ChatSidebarSection coexistence.
//

import AppKit
import SwiftUI

struct ChatContentView: View {
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject var observedSession: ChatSession
    @ObservedObject var session: ChatSession
    @Binding var pendingWhatsNew: WhatsNewRelease?
    @Binding var pendingDiscoveredAgent: DiscoveredAgent?
    @Binding var focusTrigger: Int
    @Binding var isPinnedToBottom: Bool
    var filteredPickerItems: [ModelPickerItem]
    var theme: ThemeProtocol
    var keyMonitor: Any?
    var chatBackground: AnyView
    var chatHeader: AnyView
    var emptyStateView: AnyView
    var messageThread: (CGFloat, CGFloat) -> AnyView
    var promptOverlayLayer: AnyView
    var onChatOverlayActivated: () -> Void
    /// Installs / tears down the window-scoped Cmd+F (find bar) and Esc key
    /// monitor. Must run on appear/disappear here — `ChatView.body` just
    /// delegates to `chatModeContent` with no lifecycle hooks of its own
    /// (see `ChatView.setupKeyMonitor`/`cleanupKeyMonitor`), so this was the
    /// only place upstream's monitor wiring could still attach after the
    /// M10.5 Phase 7 extraction into this standalone view. It never got
    /// carried over — `.onDisappear` below was an empty stub — so Cmd+F
    /// silently had no monitor to catch it.
    var onSetupFindKeyMonitor: () -> Void
    var onCleanupFindKeyMonitor: () -> Void
    var handleChatToolbarSelectDiscovered: (Notification) -> Void
    var onRelayAgentNotify: (Notification) -> Void
    var onPickerItemsChanged: ([ModelPickerItem]) -> Void
    var onChangeSelectedProvider: (UUID?) -> Void
    var whatsNewContent: (WhatsNewRelease) -> AnyView
    var agentSheetContent: (DiscoveredAgent) -> AnyView

    // Measured header + composer heights so the message thread can get an EXPLICIT
    // height (window − header − composer) and STOP above the composer instead of
    // scrolling behind it. On Ventura the NSScrollView ignores a flexible maxHeight
    // (it inflates to its content height); only an explicit frame bounds it.
    // (Renée, 2026-06-13.)
    @State private var measuredHeaderHeight: CGFloat = 44
    @State private var measuredComposerHeight: CGFloat = 100

    /// User-adjustable width of the History sidebar, persisted across launches
    /// so a chosen width sticks. Clamped to `sidebarWidthRange` on read so a
    /// stale out-of-bounds value can never wedge the layout. Upstream 035ed272.
    @AppStorage("chatSidebarWidth") private var storedSidebarWidth: Double = 240
    /// Transient width while an edge drag is in flight. Kept in view state so
    /// the resize tracks the cursor at 60fps without hitting UserDefaults on
    /// every frame; the final value is committed to `storedSidebarWidth` on
    /// drag end. `nil` means no drag is active.
    @State private var liveSidebarWidth: Double?
    /// Width captured at the start of a drag. `translation` is cumulative from
    /// the gesture start, so the live width is always `anchor + translation`
    /// (adding to the running live value would double-count the delta).
    @State private var sidebarDragAnchor: Double?

    /// Allowed range for the resizable sidebar. The floor keeps the header
    /// controls usable; the ceiling stops the sidebar from crowding out the
    /// chat on narrow windows.
    private static let sidebarWidthRange: ClosedRange<Double> = 260...460

    /// Clamp a raw width to the allowed range.
    private func clampSidebarWidth(_ raw: Double) -> Double {
        min(max(raw, Self.sidebarWidthRange.lowerBound), Self.sidebarWidthRange.upperBound)
    }

    /// Effective sidebar width: the live drag value while resizing, otherwise
    /// the persisted width. Always clamped.
    private var clampedSidebarWidth: CGFloat {
        CGFloat(clampSidebarWidth(liveSidebarWidth ?? storedSidebarWidth))
    }

    /// Draggable divider on the sidebar's trailing edge. A thin visible seam
    /// with a wider invisible hit area; dragging resizes the sidebar. Uses
    /// `NSCursor.resizeLeftRight` push/pop (this fork's established cursor
    /// pattern — see `PromptCard.swift` — rather than upstream's
    /// `.pointerStyle(.columnResize)`, which is macOS 14+).
    private var sidebarResizeHandle: some View {
        // An 11pt-wide interactive strip straddling the trailing edge (offset
        // pushes half of it past the border) so the seam is grabbable right at
        // the boundary. The visible seam is a 1pt line at the strip's center;
        // the cursor area fills the strip.
        Color.clear
            .frame(width: 11)
            .frame(maxHeight: .infinity)
            .overlay {
                Rectangle()
                    .fill(theme.secondaryText.opacity(liveSidebarWidth != nil ? 0.55 : 0.12))
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .offset(x: 5)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        // Anchor to the width at gesture start so the rail
                        // tracks the cursor 1:1 without accumulating drift.
                        let anchor = sidebarDragAnchor ?? Double(clampedSidebarWidth)
                        if sidebarDragAnchor == nil {
                            sidebarDragAnchor = anchor
                        }
                        liveSidebarWidth = clampSidebarWidth(anchor + Double(value.translation.width))
                    }
                    .onEnded { _ in
                        if let final = liveSidebarWidth {
                            storedSidebarWidth = clampSidebarWidth(final)
                        }
                        liveSidebarWidth = nil
                        sidebarDragAnchor = nil
                    }
            )
    }

    var body: some View {
        GeometryReader { proxy in
            let windowWidth: CGFloat = proxy.size.width
            let showSidebar: Bool = windowState.showSidebar
            let sidebarWidth: CGFloat = showSidebar ? clampedSidebarWidth : 0
            let chatWidth = windowWidth - sidebarWidth
            let effectiveContentWidth = min(chatWidth, 1100)
            let chromeHeight = measuredHeaderHeight + measuredComposerHeight
            let threadHeight = max(80, proxy.size.height - chromeHeight)

            HStack(alignment: .top, spacing: 0) {
                // Sidebar
                let fSessions: [ChatSessionData] = windowState.filteredSessions
                let aId: UUID = windowState.agentId
                let sessId: UUID? = session.sessionId
                VStack(alignment: .leading, spacing: 0) {
                    if windowState.showSidebar {
                        ChatSessionSidebar(
                            sessions: fSessions,
                            agentId: aId,
                            currentSessionId: sessId,
                            width: sidebarWidth,
                            onSelect: { [weak windowState] data in
                                windowState?.openProjectId = nil
                                windowState?.loadSession(data)
                            },
                            onNewChat: { [weak windowState] in windowState?.startNewChat() },
                            onDelete: { [weak windowState] id in
                                guard let windowState else { return }
                                // If the row being deleted is the session
                                // currently loaded in this window, reset the
                                // live session FIRST. Otherwise the live
                                // session still holds that id + its turns and
                                // re-persists itself on the next send() or via
                                // the synchronous save() inside reset()→stop()→
                                // completeRunCleanup — resurrecting the row we
                                // just deleted. startNewChat may re-save it, so
                                // delete AFTER to guarantee it's gone.
                                if windowState.session.sessionId == id {
                                    windowState.startNewChat()
                                }
                                ChatSessionsManager.shared.delete(id: id)
                                windowState.refreshSessions()
                            },
                            onRename: { [weak windowState] id, title in
                                ChatSessionsManager.shared.rename(id: id, title: title)
                                // Keep the open view-model in sync so the next
                                // auto-save doesn't clobber the rename. (upstream #1482)
                                if session.sessionId == id { session.title = title }
                                windowState?.refreshSessions()
                            },
                            onSetArchived: { [weak windowState] id, archived in
                                ChatSessionsManager.shared.setArchived(id: id, archived: archived)
                                if session.sessionId == id { session.archived = archived }
                                windowState?.refreshSessions()
                            },
                            onSetPinned: { [weak windowState] id, pinned in
                                ChatSessionsManager.shared.setPinned(id: id, pinned: pinned)
                                // Keep the open view-model in sync so the next
                                // auto-save doesn't clobber the flag.
                                if session.sessionId == id { session.pinned = pinned }
                                windowState?.refreshSessions()
                            },
                            onExport: { _, _ in
                                // Export pipeline is amputated on Intel
                                // (ChatSessionExportCoordinator + ExportChooserSheet
                                // both live in excluded files). The Export menu
                                // item is gated to hidden inside the sidebar.
                            },
                            onOpenProject: { [weak windowState] projectId in
                                windowState?.openProjectId = projectId
                            }
                        )
                    }
                }
                .frame(width: sidebarWidth, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
                .overlay(alignment: .trailing) {
                    if windowState.showSidebar {
                        sidebarResizeHandle
                    }
                }
                .zIndex(1)

                // Main chat area
                ZStack {
                    chatBackground
                    if let openProjectId = windowState.openProjectId {
                        // Bug #5/#6 route: a project is open, so the main
                        // area renders the project page instead of the
                        // chat thread/composer. `chatBackground` above
                        // stays so the window chrome is continuous.
                        ProjectPageView(
                            projectId: openProjectId,
                            onSelectChat: { [weak windowState] data in
                                windowState?.loadSession(data)
                                windowState?.openProjectId = nil
                            },
                            onNewChat: { [weak windowState] in
                                guard let windowState else { return }
                                windowState.startNewChatInCurrentProject()
                            },
                            onLeave: { [weak windowState] in
                                windowState?.openProjectId = nil
                            }
                        )
                        // Load-bearing: keying the page to the project id makes
                        // switching projects a full teardown + rebuild with
                        // fresh @State, instead of re-pointing a live instance
                        // whose instructions buffer still holds the PREVIOUS
                        // project's text. Without this the buffer and its owner
                        // could desync across the lifecycle transition and the
                        // text was written to the wrong project — instructions
                        // appeared to migrate between projects.
                        .id(openProjectId)
                    } else {
                    VStack(spacing: 0) {
                        chatHeader
                            .background(
                                GeometryReader { g in
                                    Color.clear.preference(
                                        key: ChatHeaderHeightKey.self, value: g.size.height)
                                }
                            )
                        if let err = observedSession.lastStreamError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        if session.hasAnyModel || session.isDiscoveringModels {
                            let _ = observedSession.turns.count
                            if observedSession.turns.isEmpty {
                                emptyStateView
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                // EXPLICIT height = window − header − composer so the
                                // thread STOPS above the composer (instead of scrolling
                                // behind it). The NSScrollView ignores a flexible
                                // maxHeight on Ventura — it inflates to its content
                                // height — so only an explicit frame bounds it.
                                // (Renée, 2026-06-13.)
                                // messageThread self-sizes to `threadHeight` and
                                // clips its scroll view internally (overlays float
                                // outside that clip). (Renée, 2026-06-13.)
                                messageThread(effectiveContentWidth, threadHeight)
                                    .frame(maxWidth: .infinity)
                            }
                        } else {
                            VStack(spacing: 16) {
                                ProgressView().scaleEffect(0.8)
                                Text("Discovering models…").font(theme.font(size: 13)).foregroundStyle(theme.secondaryText)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                        }
                        FloatingInputCard(
                            text: $observedSession.input,
                            selectedModel: $observedSession.selectedModel,
                            pendingAttachments: $observedSession.pendingAttachments,
                            isContinuousVoiceMode: $observedSession.isContinuousVoiceMode,
                            voiceInputState: $observedSession.voiceInputState,
                            showVoiceOverlay: $observedSession.showVoiceOverlay,
                            pickerItems: filteredPickerItems,
                            activeModelOptions: $observedSession.activeModelOptions,
                            isStreaming: observedSession.isStreaming,
                            supportsImages: false,
                            estimatedContextTokens: observedSession.estimatedContextTokens,
                            contextBreakdown: observedSession.estimatedContextBreakdown,
                            onSend: { [weak observedSession] sentText in
                                // FloatingInputCard clears the `text` binding (which
                                // is $observedSession.input) just BEFORE calling
                                // onSend, so `session.sendCurrent()` would see an
                                // empty input and silently no-op. Instead, route
                                // the text it passes us directly through `send(_:
                                // attachments:)` which is what sendCurrent calls
                                // internally anyway.
                                guard let session = observedSession else { return }
                                let attachments = session.pendingAttachments
                                session.pendingAttachments = []
                                let body = sentText ?? ""
                                guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || !attachments.isEmpty
                                else { return }
                                session.send(body, attachments: attachments)
                            },
                            onStop: { [weak observedSession] in observedSession?.stop() },
                            focusTrigger: focusTrigger,
                            agentId: windowState.agentId,
                            windowId: windowState.windowId,
                            isCompact: windowState.showSidebar,
                            // Never wired up: FloatingInputCard's built-in /clear
                            // handler falls back to a "pass a handler" toast
                            // without this. Mirrors the Cmd+N "New Chat" action
                            // (`ChatWindowState.startNewChat()`) — same
                            // save-current/flush/reset-session/refresh-sidebar
                            // behavior the toolbar button and shortcut use.
                            onClearChat: { [weak windowState] in
                                windowState?.startNewChat()
                            },
                            onGenerateTitle: { [weak observedSession] in
                                observedSession?.generateTitleFromSlashCommand()
                            },
                            autoSpeakAssistant: $observedSession.autoSpeakAssistant,
                            queuedSend: $observedSession.queuedSend,
                            folderState: observedSession.folderState
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: ChatComposerHeightKey.self, value: g.size.height)
                            }
                        )
                    }
                    }
                }
                // Pin the chat column to the WINDOW's height (GeometryReader) and clip,
                // so a mis-measure can never push content past the window. The thread
                // gets an explicit height (above) computed from the measured header +
                // composer, so it stops above the composer with a real scrollbar.
                // (Renée, 2026-06-13.)
                .frame(height: proxy.size.height)
                .clipped()
                .onPreferenceChange(ChatHeaderHeightKey.self) { measuredHeaderHeight = $0 }
                .onPreferenceChange(ChatComposerHeightKey.self) { measuredComposerHeight = $0 }
            }
        }
        .frame(minWidth: 800, idealWidth: 950, maxWidth: .infinity, minHeight: 575, idealHeight: 610, maxHeight: .infinity)
        // The native Intel chat window already supplies the real macOS corner
        // mask. A second SwiftUI mask here cuts the content inward and leaves
        // the window background visible as gray wedges at all four corners.
        // Keep the upstream rounded content treatment for Apple Silicon.
        #if OSAURUS_INTEL
        .clipShape(Rectangle())
        #else
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        #endif
        #if OSAURUS_INTEL
        // The native frame clips the full-size hosting view at the correct
        // Ventura window radius. Its default backing color is AppKit gray,
        // though, and the antialiased edge exposes a one-pixel gray crescent
        // between that frame and the themed SwiftUI content. Keep the backing
        // synchronized with the active theme so those edge pixels disappear.
        .background(
            IntelChatWindowBackingColor(color: NSColor(theme.primaryBackground))
        )
        #endif
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .chatOverlayActivated)) { _ in
            focusTrigger &+= 1; isPinnedToBottom = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatToolbarSelectDiscoveredAgent)) { n in
            handleChatToolbarSelectDiscovered(n)
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatToolbarSelectRelayAgent)) { _ in }
        .onReceive(NotificationCenter.default.publisher(for: .vadStartNewSession)) { _ in }
        .onAppear {
            session.applyInitialModelSelection()
            onSetupFindKeyMonitor()
        }
        .onDisappear {
            onCleanupFindKeyMonitor()
        }
        .onChange(of: observedSession.pickerItems) { newItems in
            onPickerItemsChanged(newItems)
        }
        .onChange(of: windowState.selectedDiscoveredAgentProviderId) { providerId in
            onChangeSelectedProvider(providerId)
        }
        .environment(\.theme, windowState.theme)
        .tint(theme.accentColor)
        .sheet(item: $pendingWhatsNew) { release in
            whatsNewContent(release)
        }
        .sheet(item: $pendingDiscoveredAgent) { agent in
            agentSheetContent(agent)
        }
    }
}

#if OSAURUS_INTEL
private struct IntelChatWindowBackingColor: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> BackingColorView {
        BackingColorView(color: color)
    }

    func updateNSView(_ nsView: BackingColorView, context: Context) {
        nsView.color = color
        nsView.applyColor()
    }

    final class BackingColorView: NSView {
        var color: NSColor

        init(color: NSColor) {
            self.color = color
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyColor()
        }

        func applyColor() {
            window?.backgroundColor = color
        }
    }
}
#endif

// Measured heights of the chat chrome, used to give the message thread an explicit
// height (window − header − composer) so it stops above the composer.
private struct ChatHeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ChatComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
