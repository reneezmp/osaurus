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
    @ObservedObject private var knowledgeManager = KnowledgeManager.shared

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
    @State private var isAgentPickerPresented = false
    @State private var memoryPreviewLines: [String] = []
    @State private var memoryItemCount = 0
    @State private var folderDisplayPath: String?

    // Rosy's normal Ventura content area is narrower than the upstream
    // window, so the split must engage before the old 760pt cutoff. Keep a
    // compact single-column mode for genuinely narrow windows.
    private let twoColumnBreakpoint: CGFloat = 680
    private let settingsColumnWidth: CGFloat = 320

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
        GeometryReader { proxy in
            Group {
                if proxy.size.width >= twoColumnBreakpoint {
                    twoColumnLayout
                } else {
                    singleColumnLayout
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .background(theme.primaryBackground)
        .onAppear {
            loadInstructions()
            loadMemoryPreview()
            folderDisplayPath = project?.folderPath
        }
        .task { await knowledgeManager.ensureLoaded() }
        // Leaving the page — back to a chat, or over to another project —
        // tears this view down, and the 600ms debounce does not survive that.
        // Flush so the last keystrokes are not lost. Safe unconditionally:
        // `projectId` cannot have changed under us (see the note above).
        .onDisappear { flushInstructions() }
        .sheet(isPresented: $showingAddChats) {
            addChatsSheet
        }
    }

    private var twoColumnLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    pageHeader
                    chatsSection
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    instructionsSection
                    knowledgeSection
                    folderSection
                    memorySection
                    defaultAgentSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(width: settingsColumnWidth)
            .background(theme.secondaryBackground.opacity(theme.isDark ? 0.18 : 0.3))
        }
    }

    private var singleColumnLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                pageHeader
                instructionsSection
                knowledgeSection
                folderSection
                memorySection
                defaultAgentSection
                chatsSection
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Knowledge

    private var knowledgeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Knowledge", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button(action: createKnowledgeCollection) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                        Text("New Collection", bundle: .module)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            Text("Collections every chat in this project can search.", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)

            let collections = knowledgeManager.collections.filter(\.isEnabled)
            if collections.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                    Text(
                        "No enabled collections yet. Create one to give this project's chats shared knowledge.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(sectionCardBackground)
            } else {
                VStack(spacing: 2) {
                    ForEach(collections) { collection in
                        knowledgeRow(collection)
                    }
                }
            }
        }
    }

    private func knowledgeRow(_ collection: KnowledgeCollection) -> some View {
        let granted = project?.knowledgeCollectionIds.contains(collection.id) == true
        return HStack(spacing: 10) {
            Button {
                shareKnowledgeCollection(collection.id, enabled: !granted)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(granted ? theme.accentColor : theme.secondaryText.opacity(0.6))
                    Image(systemName: "books.vertical")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: collection.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                        if !collection.summary.isEmpty {
                            Text(verbatim: collection.summary)
                                .font(.system(size: 10))
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { openKnowledgeCollection(collection.id) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .localizedHelp("View collection details")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(sectionCardBackground)
    }

    private var sectionCardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(theme.secondaryBackground.opacity(theme.isDark ? 0.35 : 0.5))
    }

    private func createKnowledgeCollection() {
        guard let project else { return }
        ManagementStateManager.shared.pendingKnowledgeCreate = .init(
            prefillName: "\(project.name) Collection",
            grantProjectId: project.id
        )
        AppDelegate.shared?.showManagementWindow(initialTab: .knowledge)
    }

    private func openKnowledgeCollection(_ id: UUID) {
        ManagementStateManager.shared.pendingKnowledgeDetailId = id
        AppDelegate.shared?.showManagementWindow(initialTab: .knowledge)
    }

    @MainActor
    private func shareKnowledgeCollection(_ collectionId: UUID, enabled: Bool) {
        guard var updated = projectManager.project(for: projectId) else { return }
        if enabled {
            if !updated.knowledgeCollectionIds.contains(collectionId) {
                updated.knowledgeCollectionIds.append(collectionId)
            }
        } else {
            updated.knowledgeCollectionIds.removeAll { $0 == collectionId }
        }
        projectManager.update(updated)
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

    // MARK: - Working Folder

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Working Folder", bundle: .module)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text("New chats in this project open with this folder.", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)

            if let path = folderDisplayPath, !path.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: (path as NSString).lastPathComponent)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                        Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Change", action: chooseFolder)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                        .pointingHandCursor()
                    Button(action: clearFolder) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .localizedHelp("Remove folder")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(sectionCardBackground)
            } else {
                Button(action: chooseFolder) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                        Text("Choose Folder…", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(sectionCardBackground)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = L("Choose Project Folder")
        panel.message = L("Choose a folder new chats in this project open with.")
        panel.prompt = L("Choose")

        let complete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if let path = await projectManager.setFolder(url, for: projectId) {
                    folderDisplayPath = path
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }

    private func clearFolder() {
        projectManager.clearFolder(for: projectId)
        folderDisplayPath = nil
    }

    // MARK: - Shared Memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Shared Memory", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button(action: openProjectMemory) {
                    HStack(spacing: 3) {
                        Text("Open in Memory", bundle: .module)
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            Text("What chats in this project have learned, shared across every agent.", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)

            if memoryPreviewLines.isEmpty {
                Text("Chats in this project will build shared memory here.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                    .background(sectionCardBackground)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(memoryPreviewLines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 7) {
                            Circle()
                                .fill(theme.accentColor.opacity(0.6))
                                .frame(width: 4, height: 4)
                                .padding(.top, 6)
                            Text(verbatim: line)
                                .font(.system(size: 12))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(2)
                        }
                    }
                    if memoryItemCount > memoryPreviewLines.count {
                        Text("\(memoryItemCount) stored memories", bundle: .module)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(sectionCardBackground)
            }
        }
    }

    private func loadMemoryPreview() {
        let key = MemoryNamespace.project(projectId).key
        Task.detached {
            let facts = (try? MemoryDatabase.shared.loadPinnedFacts(agentId: key, limit: 20)) ?? []
            let episodes =
                (try? MemoryDatabase.shared.loadEpisodes(agentId: key, days: 3650, limit: 20)) ?? []
            let transcripts =
                (try? MemoryDatabase.shared.loadTranscript(agentId: key, days: 3650, limit: 20)) ?? []
            let count = facts.count + episodes.count + transcripts.count

            var raw = facts.map(\.content)
            if raw.count < 3 { raw += episodes.map(\.summary) }
            if raw.count < 3 { raw += transcripts.map(\.content) }
            let lines = raw.prefix(3).map { value -> String in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.count > 110 ? String(trimmed.prefix(110)) + "…" : trimmed
            }

            await MainActor.run {
                memoryItemCount = count
                memoryPreviewLines = Array(lines)
            }
        }
    }

    private func openProjectMemory() {
        ManagementStateManager.shared.pendingMemoryProjectPreview =
            MemoryNamespace.project(projectId).key
        AppDelegate.shared?.showManagementWindow(initialTab: .memory)
    }

    // MARK: - Default Agent

    private var defaultAgentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Default Agent", bundle: .module)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text("New chats started from this project use this agent.", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)

            Button { isAgentPickerPresented.toggle() } label: {
                HStack(spacing: 8) {
                    if let agent = selectedDefaultAgent {
                        AgentAvatarView(
                            mascotId: agent.avatar,
                            name: agent.name,
                            tint: theme.accentColor,
                            diameter: 18,
                            customImageURL: agent.customAvatarURL,
                            monogramFontSize: 8,
                            borderWidth: 0
                        )
                        Text(verbatim: agent.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                    } else {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 14))
                            .foregroundColor(theme.secondaryText)
                        Text("Use Current Agent", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(sectionCardBackground)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .popover(isPresented: $isAgentPickerPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    defaultAgentRow(nil)
                    ForEach(selectableAgents) { agent in
                        defaultAgentRow(agent)
                    }
                }
                .padding(6)
                .frame(minWidth: 280)
                .background(theme.primaryBackground)
            }
        }
    }

    private var selectableAgents: [Agent] {
        agentManager.agents.filter { $0.id != Agent.defaultId }
    }

    private var selectedDefaultAgent: Agent? {
        guard let id = project?.defaultAgentId else { return nil }
        return agentManager.agents.first { $0.id == id }
    }

    private func defaultAgentRow(_ agent: Agent?) -> some View {
        let selected = project?.defaultAgentId == agent?.id
        return Button {
            isAgentPickerPresented = false
            setDefaultAgent(agent?.id)
        } label: {
            HStack(spacing: 8) {
                if let agent {
                    AgentAvatarView(
                        mascotId: agent.avatar,
                        name: agent.name,
                        tint: theme.accentColor,
                        diameter: 18,
                        customImageURL: agent.customAvatarURL,
                        monogramFontSize: 8,
                        borderWidth: 0
                    )
                    Text(verbatim: agent.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                } else {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 14))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 18, height: 18)
                    Text("Use Current Agent", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func setDefaultAgent(_ id: UUID?) {
        guard var updated = projectManager.project(for: projectId) else { return }
        updated.defaultAgentId = id
        projectManager.update(updated)
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
