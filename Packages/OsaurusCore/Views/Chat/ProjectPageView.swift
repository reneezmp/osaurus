//
//  ProjectPageView.swift
//  osaurus
//
//  Full-width project page rendered in the chat window's main content area
//  (see `ChatWindowState.openProjectId` / `ChatContentView`). Replaces
//  `ProjectDetailView`'s themed-alert-sheet presentation — clicking a
//  project used to open a modal with no "inside a project" state at all;
//  closing it left you nowhere, and clicking again just reopened the same
//  modal. This is the real route upstream has: instructions editor, member
//  chat list, and a way back to the chat you came from, all inline instead
//  of stacked in a sheet.
//
//  Reuses `ProjectDetailView`'s logic verbatim (debounced instructions
//  auto-save, search, Add Existing sheet, remove-from-project) — only the
//  shell changed, from a themed-alert's fixed-width custom content to a
//  full-width scrollable page with its own header.
//

import AppKit
import SwiftUI

struct ProjectPageView: View {
    let projectId: UUID
    /// Loads a member chat — the caller is expected to also leave the page
    /// (clear `openProjectId`) so the loaded chat is what's visible.
    var onSelectChat: (ChatSessionData) -> Void
    /// Starts a brand-new chat tagged to this project and leaves the page.
    var onNewChat: () -> Void
    /// Leaves the project page, back to whichever chat is currently loaded
    /// in this window — no session change, just a route change.
    var onLeave: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.themedAlertScope) private var alertScope
    @ObservedObject private var projectManager = ProjectManager.shared
    @ObservedObject private var sessionsManager = ChatSessionsManager.shared
    @ObservedObject private var agentManager = AgentManager.shared

    // NOTE: `ChatContentView` mounts this view with `.id(projectId)`, so a
    // project switch tears the whole page down and builds a fresh one rather
    // than re-pointing a live instance. That is load-bearing: it makes
    // `projectId` immutable for the lifetime of this instance, so the buffer
    // below can only ever belong to one project. The previous design kept the
    // buffer alive across switches and tracked its owner in a second piece of
    // state; when the two desynced during a lifecycle transition the buffer
    // was written to the WRONG project, and instructions appeared to migrate
    // from one project to another. Do not reintroduce a cross-project buffer.
    @State private var instructions: String = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var query: String = ""
    @FocusState private var isSearchFocused: Bool
    @State private var showingAddChats = false
    @State private var titlebarInset: CGFloat = 0

    private var project: Project? { projectManager.project(for: projectId) }

    private var memberChats: [ChatSessionData] {
        sessionsManager.sessions(forProject: projectId)
    }

    private var filteredChats: [ChatSessionData] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return memberChats }
        return memberChats.filter { SearchService.matches(query: trimmed, in: $0.title) }
    }

    private var ungroupedChats: [ChatSessionData] {
        sessionsManager.sessions.values
            .filter { $0.projectId == nil && !$0.archived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader

            Divider().opacity(0.3)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    instructionsSection
                    Divider().opacity(0.5)
                    chatsSection
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        // `ChatContentView` paints through the transparent full-size titlebar.
        // Reserve this window's actual excluded top strip before the page
        // header reaches the traffic lights; it changes with toolbar layout.
        .padding(.top, titlebarInset)
        .background(
            TitlebarInsetReader { inset in
                guard abs(titlebarInset - inset) > 0.5 else { return }
                titlebarInset = inset
            }
        )
        .onAppear { loadInstructions() }
        // Leaving the page — back to a chat, or over to another project —
        // tears this view down, and the 600ms debounce does not survive that.
        // Flush so the last keystrokes are not lost. Safe unconditionally:
        // `projectId` cannot have changed under us (see the note above).
        .onDisappear { flushInstructions() }
        .sheet(isPresented: $showingAddChats) {
            addChatsSheet
        }
    }

    // MARK: - Header

    private var pageHeader: some View {
        HStack(spacing: 10) {
            Button(action: onLeave) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.secondaryBackground.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .localizedHelp("Back to Chat")

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.accentColor.opacity(theme.isDark ? 0.18 : 0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: "folder.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }

            Text(verbatim: project?.name ?? "")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)

            Button(action: presentRename) {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .localizedHelp("Rename Project")

            Spacer()

            Button(action: onNewChat) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("New Chat", bundle: .module)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(theme.accentColor.opacity(theme.isDark ? 0.18 : 0.12))
                )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .localizedHelp("New Chat in This Project")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func presentRename() {
        guard let project else { return }
        let requestId = UUID()
        let scope = alertScope
        let sheet = ProjectNamePromptSheet(initialName: project.name, submitLabel: "Save") { name in
            var updated = project
            updated.name = name
            projectManager.update(updated)
            ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
        }
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: L("Rename Project"),
                message: nil,
                buttons: [.cancel(L("Cancel"))],
                showsCloseButton: true,
                customContent: AnyView(sheet),
                width: 360,
                onDismiss: { ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId) }
            ),
            scope: scope
        )
    }

    // MARK: - Instructions

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Instructions", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text("Shared context added to every chat in this project.", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)

            TextEditor(text: $instructions)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140, maxHeight: 260)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.primaryBackground.opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
                .onChange(of: instructions) { newValue in
                    // Debounced auto-save — same 600ms debounce as
                    // `ProjectDetailView`, just re-housed.
                    let target = projectId
                    saveTask?.cancel()
                    saveTask = Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        guard !Task.isCancelled else { return }
                        await MainActor.run { writeInstructions(newValue, to: target) }
                    }
                }
        }
    }

    // MARK: - Instructions Persistence

    /// Loads the editor buffer for this page's project.
    private func loadInstructions() {
        saveTask?.cancel()
        saveTask = nil
        instructions = project?.instructions ?? ""
    }

    /// Writes any pending edit through immediately, cancelling the debounce.
    /// Called on teardown — the 600ms timer does not survive it.
    private func flushInstructions() {
        saveTask?.cancel()
        saveTask = nil
        writeInstructions(instructions, to: projectId)
    }

    /// Single write path. No-ops when the text is unchanged so a buffer
    /// resync cannot churn `updatedAt` or clobber a newer value.
    @MainActor
    private func writeInstructions(_ text: String, to target: UUID) {
        guard var proj = projectManager.project(for: target), proj.instructions != text
        else { return }
        proj.instructions = text
        projectManager.update(proj)
    }

    // MARK: - Chats

    private var chatsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            chatsHeader

            SidebarSearchField(
                text: $query,
                placeholder: "Search chats...",
                isFocused: $isSearchFocused,
                isSearching: false,
                showsRestingBorder: true
            )

            if memberChats.isEmpty {
                emptyChats
            } else if filteredChats.isEmpty {
                SidebarNoResultsView(searchQuery: query) { query = "" }
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(filteredChats) { session in
                        chatRow(session)
                    }
                }
            }
        }
    }

    private var chatsHeader: some View {
        HStack {
            Text("Chats", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Spacer()
            Button(action: { showingAddChats = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("Add Existing", bundle: .module)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.accentColor)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
    }

    private var emptyChats: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 22))
                .foregroundColor(theme.secondaryText.opacity(0.5))
            Text("No chats in this project yet", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func chatRow(_ session: ChatSessionData) -> some View {
        let agent = agentManager.agents.first { $0.id == session.agentId }
        return HStack(spacing: 10) {
            Button {
                onSelectChat(session)
            } label: {
                HStack(spacing: 10) {
                    if let agent {
                        AgentAvatarView(
                            mascotId: agent.avatar,
                            name: agent.name,
                            tint: theme.accentColor,
                            diameter: 24,
                            customImageURL: agent.customAvatarURL,
                            monogramFontSize: 10,
                            borderWidth: 0
                        )
                    } else {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 24, height: 24)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: session.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                        if let agent {
                            Text(verbatim: agent.displayName)
                                .font(.system(size: 10))
                                .foregroundColor(theme.secondaryText.opacity(0.85))
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            Button {
                ChatSessionsManager.shared.setProject(id: session.id, projectId: nil)
            } label: {
                Image(systemName: "folder.badge.minus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .localizedHelp("Remove from Project")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .pointingHandCursor()
    }

    // MARK: - Add Existing Chats Sheet

    private var addChatsSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add Chats to Project", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button(action: { showingAddChats = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider().opacity(0.3)

            AddChatsToProjectSheet(candidates: ungroupedChats) { selected in
                for id in selected {
                    ChatSessionsManager.shared.setProject(id: id, projectId: projectId)
                }
                showingAddChats = false
            }
            .padding(16)
        }
        .frame(width: 420, height: 480)
        .background(theme.primaryBackground)
    }
}

/// Reads only the window hosting this view. `contentLayoutRect` is expressed
/// in window coordinates, so convert it into the content view before finding
/// the top strip that AppKit excludes from layout.
private struct TitlebarInsetReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> TitlebarInsetView {
        let view = TitlebarInsetView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: TitlebarInsetView, context: Context) {
        nsView.onChange = onChange
    }

    final class TitlebarInsetView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private weak var observedWindow: NSWindow?
        private var layoutObservation: NSKeyValueObservation?
        private var resizeObserver: NSObjectProtocol?
        private var observationGeneration = 0
        private var pendingInset: CGFloat?
        private weak var pendingWindow: NSWindow?
        private var pendingGeneration = 0
        private var hasPendingCallback = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeWindow()
        }

        deinit {
            stopObservingWindow()
        }

        func reportInset() {
            guard let window, let contentView = window.contentView else {
                deferInset(0, for: nil)
                return
            }
            let layoutRect = contentView.convert(window.contentLayoutRect, from: nil)
            let inset = contentView.isFlipped
                ? layoutRect.minY - contentView.bounds.minY
                : contentView.bounds.maxY - layoutRect.maxY
            deferInset(max(0, inset), for: window)
        }

        private func observeWindow() {
            guard window !== observedWindow else {
                reportInset()
                return
            }
            stopObservingWindow()
            guard let window else {
                deferInset(0, for: nil)
                return
            }

            observedWindow = window
            layoutObservation = window.observe(\.contentLayoutRect, options: [.initial, .new]) { [weak self] _, _ in
                self?.reportInset()
            }
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.reportInset()
            }
            reportInset()
        }

        private func deferInset(_ inset: CGFloat, for window: NSWindow?) {
            pendingInset = inset
            pendingWindow = window
            pendingGeneration = observationGeneration
            guard !hasPendingCallback else { return }
            hasPendingCallback = true

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hasPendingCallback = false
                let inset = self.pendingInset
                let expectedWindow = self.pendingWindow
                let expectedGeneration = self.pendingGeneration
                self.pendingInset = nil

                guard expectedGeneration == self.observationGeneration,
                      self.window === expectedWindow,
                      let inset
                else { return }
                self.onChange?(inset)
            }
        }

        private func stopObservingWindow() {
            observationGeneration &+= 1
            layoutObservation = nil
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
                self.resizeObserver = nil
            }
            observedWindow = nil
        }
    }
}
