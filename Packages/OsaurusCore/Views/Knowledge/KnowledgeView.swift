//
//  KnowledgeView.swift
//  osaurus
//
//  Intel management surface for the local Knowledge collection registry and
//  background indexer.
//

import AppKit
import SwiftUI

struct KnowledgeView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var integration = KnowledgeUIIntegration.shared
    @ObservedObject private var managementState = ManagementStateManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false
    @State private var isCreating = false
    @State private var createPrefillName = ""
    @State private var createGrantProjectId: UUID?
    @State private var selectedCollection: KnowledgeUICollection?
    @State private var toastMessage: String?
    @State private var toastIsError = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            ZStack {
                if integration.collections.isEmpty {
                    emptyState
                } else {
                    collectionGrid
                }

                if let toastMessage {
                    VStack {
                        Spacer()
                        ThemedToastView(
                            toastMessage,
                            type: toastIsError ? .error : .success
                        )
                        .padding(.bottom, 20)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
            integration.reload()
            applyPendingRequests()
        }
        .onReceive(managementState.$pendingKnowledgeCreate) { _ in
            applyPendingRequests()
        }
        .onReceive(managementState.$pendingKnowledgeDetailId) { _ in
            applyPendingRequests()
        }
        .onReceive(integration.$collections) { _ in
            applyPendingRequests()
        }
        .sheet(isPresented: $isCreating) {
            KnowledgeCollectionEditorSheet(
                initialName: createPrefillName,
                onSave: createCollection,
                onCancel: { isCreating = false }
            )
        }
        .sheet(item: $selectedCollection) { collection in
            KnowledgeCollectionDetailSheet(
                collection: collection,
                onEnableChanged: { enabled in
                    integration.setCollection(collection.id, enabled: enabled)
                    selectedCollection = integration.collection(for: collection.id)
                },
                onReindex: {
                    integration.reindexCollection(collection.id)
                    showToast("Re-indexing \"\(collection.name)\"")
                },
                onDelete: {
                    selectedCollection = nil
                    integration.deleteCollection(collection.id)
                    showToast("Deleted \"\(collection.name)\"")
                },
                onClose: { selectedCollection = nil }
            )
        }
    }

    private var header: some View {
        ManagerHeaderWithActions(
            title: L("Knowledge"),
            subtitle: L("Searchable folders of guides, policies, and templates"),
            count: integration.collections.count
        ) {
            HeaderIconButton(
                "arrow.clockwise",
                isLoading: integration.isRefreshing,
                help: "Refresh"
            ) {
                integration.reload()
            }

            Button(action: beginCreate) {
                Label("Add Collection", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private var emptyState: some View {
        SettingsEmptyState(
            icon: "books.vertical.fill",
            title: L("Add Your First Knowledge Collection"),
            subtitle: L(
                "Point Osaurus at a folder of guides, templates, and standards so agents can consult it on demand."
            ),
            examples: [
                .init(
                    icon: "doc.text",
                    title: L("Guides & Policies"),
                    description: L("How your team does things")
                ),
                .init(
                    icon: "square.on.square",
                    title: L("Templates"),
                    description: L("Wording you reuse")
                ),
                .init(
                    icon: "book",
                    title: L("How-To Steps"),
                    description: L("Instructions for everyday tasks")
                ),
            ],
            primaryAction: .init(
                title: L("Add Collection"),
                icon: "plus",
                handler: beginCreate
            ),
            hasAppeared: hasAppeared
        )
        .padding(.horizontal, 32)
    }

    private var collectionGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 300), spacing: 20),
                    GridItem(.flexible(minimum: 300), spacing: 20),
                ],
                spacing: 20
            ) {
                ForEach(Array(integration.collections.enumerated()), id: \.element.id) { index, collection in
                    KnowledgeCollectionCard(
                        collection: collection,
                        animationDelay: Double(index) * 0.05,
                        hasAppeared: hasAppeared,
                        onToggle: { enabled in
                            integration.setCollection(collection.id, enabled: enabled)
                        },
                        onReindex: {
                            integration.reindexCollection(collection.id)
                            showToast("Re-indexing \"\(collection.name)\"")
                        },
                        onDelete: {
                            integration.deleteCollection(collection.id)
                            showToast("Deleted \"\(collection.name)\"")
                        },
                        onOpenDetail: { selectedCollection = collection }
                    )
                }
            }
            .padding(24)
        }
        .opacity(hasAppeared ? 1 : 0)
    }

    private func beginCreate() {
        createPrefillName = ""
        createGrantProjectId = nil
        isCreating = true
    }

    private func createCollection(name: String, summary: String, folderPath: String) {
        isCreating = false
        Task { @MainActor in
            do {
                let collectionId = try await integration.createCollection(
                    name: name,
                    summary: summary,
                    folderPath: folderPath
                )
                if let projectId = createGrantProjectId,
                    var project = ProjectManager.shared.project(for: projectId)
                {
                    if !project.knowledgeCollectionIds.contains(collectionId) {
                        project.knowledgeCollectionIds.append(collectionId)
                        ProjectManager.shared.update(project)
                    }
                }
                createPrefillName = ""
                createGrantProjectId = nil
                showToast("Added \"(name)\"")
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    private func applyPendingRequests() {
        if let request = managementState.pendingKnowledgeCreate {
            managementState.pendingKnowledgeCreate = nil
            createPrefillName = request.prefillName
            createGrantProjectId = request.grantProjectId
            isCreating = true
        }

        if let id = managementState.pendingKnowledgeDetailId,
            let collection = integration.collection(for: id)
        {
            managementState.pendingKnowledgeDetailId = nil
            selectedCollection = collection
        }
    }

    private func showToast(_ message: String, isError: Bool = false) {
        toastMessage = message
        toastIsError = isError
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if toastMessage == message { toastMessage = nil }
        }
    }
}

private struct KnowledgeCollectionCard: View {
    @Environment(\.theme) private var theme

    let collection: KnowledgeUICollection
    let animationDelay: Double
    let hasAppeared: Bool
    let onToggle: (Bool) -> Void
    let onReindex: () -> Void
    let onDelete: () -> Void
    let onOpenDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(theme.accentColor.opacity(0.12)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(collection.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    Text(collection.folderPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Toggle(
                    "",
                    isOn: Binding(
                        get: { collection.isEnabled },
                        set: onToggle
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            if !collection.summary.isEmpty {
                Text(collection.summary)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                if !collection.isAvailable {
                    Label(collection.statusMessage ?? "Source folder unavailable", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(theme.errorColor)
                } else if let documentCount = collection.documentCount, let chunkCount = collection.chunkCount {
                    Label(
                        "\(documentCount) \(documentCount == 1 ? "document" : "documents") · \(chunkCount) \(chunkCount == 1 ? "chunk" : "chunks")",
                        systemImage: "doc.text"
                    )
                } else {
                    Label(collection.statusMessage ?? "Not indexed yet", systemImage: "clock")
                }
                if collection.isIndexing {
                    Label("Indexing…", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundColor(theme.accentColor)
                }
                if collection.gitRemoteURL != nil {
                    Label("Git", systemImage: "arrow.triangle.branch")
                }
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)

            if let statusMessage = collection.statusMessage, collection.isAvailable {
                Text(statusMessage)
                    .font(.system(size: 10))
                    .foregroundColor(theme.errorColor)
            }

            HStack {
                Button("Details", action: onOpenDetail)
                    .buttonStyle(.borderless)
                Spacer()
                Button(action: onReindex) {
                    Label("Re-index", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(Text("Delete collection", bundle: .module))
            }
            .font(.system(size: 11, weight: .medium))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder.opacity(0.7), lineWidth: 1)
                )
        )
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 12)
        .animation(
            .spring(response: 0.4, dampingFraction: 0.8).delay(animationDelay),
            value: hasAppeared
        )
    }
}

private struct KnowledgeCollectionEditorSheet: View {
    @Environment(\.theme) private var theme

    let onSave: (String, String, String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var summary = ""
    @State private var folderPath = ""
    @State private var validationMessage: String?

    init(
        initialName: String = "",
        onSave: @escaping (String, String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _name = State(initialValue: initialName)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Knowledge Collection", bundle: .module)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Text(
                "Choose a folder whose contents should remain the source of truth. Osaurus indexes it in place.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            TextField("What is this collection for?", text: $summary)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                TextField("Folder", text: $folderPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…", action: chooseFolder)
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 11))
                    .foregroundColor(theme.errorColor)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 300)
        .background(theme.primaryBackground)
        .environment(\.theme, theme)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = url.lastPathComponent
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Enter a name for this collection."
            return
        }
        guard !trimmedPath.isEmpty else {
            validationMessage = "Choose a folder for this collection."
            return
        }
        onSave(trimmedName, summary.trimmingCharacters(in: .whitespacesAndNewlines), trimmedPath)
    }
}

private struct KnowledgeCollectionDetailSheet: View {
    @Environment(\.theme) private var theme

    let collection: KnowledgeUICollection
    let onEnableChanged: (Bool) -> Void
    let onReindex: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(collection.name)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Knowledge collection", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }
                Spacer()
                Toggle(
                    "Enabled",
                    isOn: Binding(
                        get: { collection.isEnabled },
                        set: onEnableChanged
                    )
                )
                .toggleStyle(.switch)
            }

            if !collection.summary.isEmpty {
                Text(collection.summary)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Folder", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                Text(collection.folderPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.secondaryBackground))

            if !collection.isAvailable {
                Label(collection.statusMessage ?? "Source folder unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(theme.errorColor)
            } else if let documentCount = collection.documentCount, let chunkCount = collection.chunkCount {
                Label(
                    "\(documentCount) indexed \(documentCount == 1 ? "document" : "documents") · \(chunkCount) \(chunkCount == 1 ? "chunk" : "chunks")",
                    systemImage: "doc.text"
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
            } else {
                Label(collection.statusMessage ?? "Not indexed yet", systemImage: "clock")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            HStack {
                Button("Delete", role: .destructive, action: onDelete)
                Spacer()
                Button("Re-index", action: onReindex)
                Button("Done", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 340)
        .background(theme.primaryBackground)
        .environment(\.theme, theme)
    }
}
