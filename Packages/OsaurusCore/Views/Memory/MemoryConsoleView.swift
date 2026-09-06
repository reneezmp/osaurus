//
//  MemoryConsoleView.swift
//  OsaurusCore (Intel fork)
//
//  Phase 4 — Memories console view (docs/MEMORY_PLAN.md Phase 4). Ports
//  upstream's `MemoryManagementConsoleView.swift`. Data contracts + service
//  live in `Models/Chat/IntelConformers/IntelMemoryConsole.swift` — read
//  that file's header first for the deliberate deviations (no disable
//  mutation, no per-row transcript forget, health reuses
//  `MemoryDiagnosticsSnapshot`, context preview has no query field).
//
//  macOS 13: every `onChange(of:)` below is the single-parameter form
//  (`{ _ in ... }`); upstream's is the two-parameter macOS 14+ form
//  (`{ _, _ in ... }` — see `upstream-console-view.swift:160,171` in the
//  recon scratch dir).
//
//  SF Symbols substituted for macOS 13 (verified live in this fork's
//  compiled `Views/` tree, not just inside a `#if !OSAURUS_INTEL` block —
//  see each call site below for the grep evidence):
//   * `stethoscope` (upstream's "Storage health" toggle icon) → `waveform`.
//     `stethoscope` only ever appears inside `#if !OSAURUS_INTEL` in this
//     fork (`Views/Settings/ProviderDiagnosticsRowsView.swift` — the whole
//     file is gated; `Views/Sandbox/SandboxView.swift:654,665` — both
//     inside its dead branch). `waveform` is confirmed live and
//     unconditional in `Views/Settings/ServerView.swift:2060,2139`.
//   * `doc.text.magnifyingglass` (upstream's "Context preview" toggle +
//     panel header icon, used twice) → `eye`, reusing the icon already on
//     the panel's own preview-trigger button. `doc.text.magnifyingglass`
//     is explicitly flagged absent by `docs/MEMORY_PLAN.md` §4.
//     `eye` is confirmed live and unconditional in
//     `Views/Skill/SkillsView.swift:692` and
//     `Views/Chat/FloatingInputCard.swift:1617`.
//   * `pause.circle` (upstream's "Disable" row-action icon) is not used at
//     all — the Disable control itself is omitted (see deviation #1 in
//     `IntelMemoryConsole.swift`), so there's no icon to substitute.
//   * `magnifyingglass`, `xmark.circle.fill`, `eye`, `exclamationmark.triangle`,
//     `pin.fill`, `doc.text`, `text.bubble`, `info.circle`, `trash`, `xmark`
//     are all used unmodified from upstream — each confirmed live and
//     unconditional elsewhere in this fork (`Views/Settings/ProvidersView.swift`,
//     `Views/Settings/ServerView.swift`, `Views/Insights/InsightsView.swift`,
//     `Views/Settings/StorageSettingsView.swift`,
//     `Views/Chat/ChatSessionSidebar.swift`, `Views/Skill/SkillEditorSheet.swift`,
//     `Views/Insights/InsightsDetailPane.swift`,
//     `Views/Settings/PermissionsView.swift`).
//

#if OSAURUS_INTEL

import SwiftUI

// MARK: - Tab wrapper

/// Hosts the console inside the Memory view's `.memories` tab, matching the
/// `ScrollView { VStack(spacing: 16) { ... }.padding(24) }` framing upstream
/// uses for its own `memoriesTab`, plus this fork's own sibling-tab chrome
/// (full-bleed `theme.primaryBackground`, matching `MemoryIdentityTabContent`
/// etc. in `MemoryView.swift`).
struct MemoryConsoleTabContent: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MemoryManagementConsoleView(
                    agents: agentManager.agents,
                    onMemoryChanged: {},
                    showToast: { message, isError in
                        if isError {
                            ToastManager.shared.error(message)
                        } else {
                            ToastManager.shared.success(message)
                        }
                    }
                )
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
    }
}

// MARK: - Console

struct MemoryManagementConsoleView: View {
    @Environment(\.theme) private var theme

    let agents: [Agent]
    let onMemoryChanged: () -> Void
    let showToast: (String, Bool) -> Void

    private let service = MemoryManagementConsoleService()

    @State private var searchText = ""
    @State private var scope: MemoryConsoleScope = .all
    @State private var agentFilter = MemoryAgentFilter.all
    @State private var isLoading = false
    @State private var showDiagnostics = false
    @State private var showContextPreview = false
    @State private var snapshot: MemoryConsoleSnapshot?
    @State private var selectedItem: MemoryConsoleItem?
    @State private var pendingForget: MemoryConsoleItem?
    @State private var previewAgentId = Agent.defaultId.uuidString
    @State private var previewTokenLimit = 800
    @State private var contextPreview: MemoryContextPreview?
    @State private var isPreviewLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchToolbar
            filtersRow

            if showDiagnostics, let health = snapshot?.health {
                diagnosticsPanel(health)
            }

            if showContextPreview {
                contextPreviewPanel
            }

            Divider().opacity(0.5)

            resultsPanel
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
        .onAppear {
            if snapshot == nil { refresh() }
        }
        .sheet(item: $selectedItem) { item in
            MemoryConsoleInspectSheet(item: item)
                .frame(minWidth: 560, minHeight: 520)
        }
        .themedAlert(
            L("Forget Memory?"),
            isPresented: Binding(
                get: { pendingForget != nil },
                set: { if !$0 { pendingForget = nil } }
            ),
            message: L("This permanently deletes the selected memory row. This cannot be undone."),
            primaryButton: .destructive(L("Forget")) {
                performForget()
            },
            secondaryButton: .cancel(L("Cancel")) {
                pendingForget = nil
            },
            presentationStyle: .contained
        )
    }

    private var searchToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.tertiaryText)

                TextField(
                    "",
                    text: $searchText,
                    prompt: Text("Search memories", bundle: .module)
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { refresh() }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        refresh()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help(Text("Clear search", bundle: .module))
                }

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )

            consoleToggleButton(
                title: "Storage health",
                icon: "waveform",
                isActive: showDiagnostics
            ) {
                showDiagnostics.toggle()
                if showDiagnostics { refresh() }
            }

            consoleToggleButton(
                title: "Context preview",
                icon: "eye",
                isActive: showContextPreview
            ) {
                showContextPreview.toggle()
            }
        }
    }

    // No "Include disabled" toggle next to the agent filter, unlike
    // upstream. Deliberately omitted, not forgotten: `MemoryDatabase`
    // never writes any `status` besides `active` on this fork (no
    // soft-disable path — `evictPinnedFacts` hard-deletes), and
    // `IntelMemoryConsole.swift`'s query layer hardcodes `active` and has
    // no `includeDisabled` field at all (see that file's own "Deliberate
    // deviations" doc comment, item 1). A toggle here would filter nothing
    // and always show the same rows — a dead control, which is worse than
    // no control per this project's house rules. Unblocking it needs, in
    // `MemoryDatabase` (owned by another lane): an `UPDATE ... SET status
    // = 'disabled'` mutation for `pinned_facts` / `episodes`, and dropping
    // the hardcoded `WHERE status = 'active'` from `loadPinnedFacts` /
    // `searchPinnedFactsText` / `loadEpisodes` / `searchEpisodesText` in
    // favor of a parameter — then `MemoryConsoleQuery` gains
    // `includeDisabled` and this row gets its `Toggle`.
    private var filtersRow: some View {
        HStack(spacing: 12) {
            Picker("", selection: $scope) {
                ForEach(MemoryConsoleScope.allCases) { value in
                    Text(LocalizedStringKey(value.displayName), bundle: .module).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            .onChange(of: scope) { _ in refresh() }

            Picker("", selection: $agentFilter) {
                Text("All agents", bundle: .module).tag(MemoryAgentFilter.all)
                Text(Agent.default.displayName).tag(MemoryAgentFilter.defaultAgent)
                ForEach(agents) { agent in
                    Text(agent.displayName).tag(MemoryAgentFilter.agent(agent.id.uuidString))
                }
            }
            .labelsHidden()
            .frame(width: 200)
            .onChange(of: agentFilter) { _ in refresh() }

            Spacer(minLength: 0)
        }
    }

    private func consoleToggleButton(
        title: String,
        icon: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isActive ? theme.accentColor : theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? theme.accentColor.opacity(0.12) : theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isActive ? theme.accentColor.opacity(0.35) : Color.clear,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var contextPreviewPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text("BOUNDED CONTEXT PREVIEW", bundle: .module)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
                    .tracking(0.3)
                Spacer()
                Text("~\(previewTokenLimit) tokens", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }

            HStack(spacing: 10) {
                Picker("Preview Agent", selection: $previewAgentId) {
                    Text(Agent.default.displayName).tag(Agent.defaultId.uuidString)
                    ForEach(agents) { agent in
                        Text(agent.displayName).tag(agent.id.uuidString)
                    }
                }
                .frame(width: 190)

                Stepper(value: $previewTokenLimit, in: 100...2000, step: 100) {
                    EmptyView()
                }
                .labelsHidden()

                Button {
                    loadContextPreview()
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(isPreviewLoading)
                .help(Text("Preview bounded memory context", bundle: .module))

                Spacer(minLength: 0)
            }

            if isPreviewLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Assembling preview...", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
            } else if let contextPreview {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(
                            contextPreview.wasEmpty
                                ? "No context assembled"
                                : "Preview context",
                            bundle: .module
                        )
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.secondaryText)

                        Spacer()

                        if contextPreview.redactedContext.redactionCount > 0 {
                            let count = contextPreview.redactedContext.redactionCount
                            Text(
                                count == 1 ? L("1 redaction") : L("\(count) redactions")
                            )
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.warningColor)
                        }
                    }

                    Text(contextPreview.redactedContext.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .textSelection(.enabled)
                        .lineLimit(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.inputBackground.opacity(0.55))
                        )
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground.opacity(0.45))
        )
    }

    @ViewBuilder
    private func diagnosticsPanel(_ health: MemoryDiagnosticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(healthColor(health))
                    .frame(width: 8, height: 8)
                Text(healthLabel(health))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Text(formatBytes(health.databaseBytes))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), spacing: 8)], spacing: 8) {
                healthTile("Pinned", "\(health.pinnedFactCount)", footnote: "active")
                healthTile("Episodes", "\(health.episodeCount)", footnote: "active")
                healthTile(
                    "Pending",
                    "\(health.pendingSignals)",
                    footnote:
                        health.deadSignals > 0
                            ? "\(health.deadSignals) dead"
                            : "of \(health.allTimeSignals) all-time"
                )
                healthTile(
                    "Distill",
                    "\(health.distillOK)",
                    footnote: "\(health.distillErrors) err · \(health.distillSkipped) skipped"
                )
                healthTile("Core model", health.coreModel ?? "None", footnote: health.extractionMode)
                healthTile("Buffer", "\(health.bufferAttempts)", footnote: "attempts this run")
            }

            if !health.databaseOpen || health.coreModel == nil || health.distillErrors > 0 || health.deadSignals > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    if !health.databaseOpen {
                        diagnosticRow("Memory database is not open.")
                    }
                    if let detail = health.coreModelDetail, health.coreModel == nil {
                        diagnosticRow(detail)
                    }
                    if health.distillErrors > 0 {
                        diagnosticRow(
                            health.distillErrors == 1
                                ? "Distillation recorded 1 error row."
                                : "Distillation recorded \(health.distillErrors) error rows."
                        )
                    }
                    if health.deadSignals > 0 {
                        diagnosticRow("Some memory signals were dead-lettered after repeated distillation failures.")
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    private func diagnosticRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.warningColor)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
        }
    }

    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("RESULTS", bundle: .module)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
                    .tracking(0.3)
                if let count = snapshot?.items.count {
                    Text("\(count)", bundle: .module)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(theme.tertiaryBackground))
                }
                Spacer()
                if let generatedAt = snapshot?.generatedAt {
                    Text(generatedAt, style: .time)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
            }

            if isLoading && snapshot == nil {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading memories...", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
            } else if let items = snapshot?.items, !items.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider().opacity(0.5)
                        }
                        MemoryConsoleResultRow(
                            item: item,
                            onInspect: { selectedItem = item },
                            onForget: { pendingForget = item }
                        )
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.inputBackground.opacity(0.5))
                )
            } else {
                Text("No memories match this search.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
        }
    }

    private func healthTile(_ label: String, _ value: String, footnote: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
            Text(footnote)
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(theme.cardBackground)
        )
    }

    private func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let query = MemoryConsoleQuery(
            text: searchText,
            scope: scope,
            agentId: agentFilter.agentId,
            limit: 80
        )
        Task {
            do {
                let next = try await service.snapshot(query: query)
                await MainActor.run {
                    snapshot = next
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    let message = L("Failed to load memory console: \(error.localizedDescription)")
                    showToast(message, true)
                }
            }
        }
    }

    private func loadContextPreview() {
        guard !isPreviewLoading else { return }
        isPreviewLoading = true
        Task {
            let preview = await service.contextPreview(
                agentId: previewAgentId,
                maxTokens: previewTokenLimit
            )
            await MainActor.run {
                contextPreview = preview
                isPreviewLoading = false
            }
        }
    }

    private func performForget() {
        guard let item = pendingForget else { return }
        pendingForget = nil
        Task {
            do {
                let result = try await service.forget(itemId: item.id)
                await MainActor.run {
                    showToast(result.message, !result.changed)
                    refresh()
                    onMemoryChanged()
                }
            } catch {
                await MainActor.run {
                    let message = L("Memory action failed: \(error.localizedDescription)")
                    showToast(message, true)
                }
            }
        }
    }

    private func healthColor(_ health: MemoryDiagnosticsSnapshot) -> Color {
        if !health.databaseOpen { return theme.errorColor }
        if health.distillErrors > 0 || health.deadSignals > 0 || health.coreModel == nil {
            return theme.warningColor
        }
        return theme.successColor
    }

    private func healthLabel(_ health: MemoryDiagnosticsSnapshot) -> String {
        if !health.databaseOpen { return L("Unavailable") }
        if health.distillErrors > 0 || health.deadSignals > 0 || health.coreModel == nil {
            return L("Needs attention")
        }
        return L("Healthy")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Agent Filter

private enum MemoryAgentFilter: Hashable {
    case all
    case defaultAgent
    case agent(String)

    var agentId: String? {
        switch self {
        case .all:
            return nil
        case .defaultAgent:
            return Agent.defaultId.uuidString
        case .agent(let id):
            return id
        }
    }
}

// MARK: - Result Row

private struct MemoryConsoleResultRow: View {
    @Environment(\.theme) private var theme

    let item: MemoryConsoleItem
    let onInspect: () -> Void
    let onForget: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(theme.tertiaryBackground)
                )

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(LocalizedStringKey(item.kind.displayName), bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    if item.preview.redactionCount > 0 {
                        Text("Redacted", bundle: .module)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.tertiaryBackground))
                    }
                    Spacer()
                }

                Text(item.preview.text)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(item.relevanceExplanation)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(2)
            }

            HStack(spacing: 4) {
                iconButton("info.circle", help: "Inspect memory", action: onInspect)
                iconButton("trash", help: forgetHelp, action: onForget)
                    .disabled(!item.canForget)
                    .opacity(item.canForget ? 1 : 0.35)
            }
            .fixedSize()
        }
        .padding(12)
    }

    private var icon: String {
        switch item.kind {
        case .pinnedFact: return "pin.fill"
        case .episode: return "doc.text"
        case .transcriptTurn: return "text.bubble"
        }
    }

    private var forgetHelp: LocalizedStringKey {
        item.canForget
            ? "Forget memory"
            : "Single transcript turns can't be forgotten yet — only whole conversations can be cleared"
    }

    private func iconButton(
        _ systemName: String,
        help: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.tertiaryBackground)
                )
        }
        .buttonStyle(.plain)
        .help(Text(help, bundle: .module))
    }
}

// MARK: - Inspect Sheet

private struct MemoryConsoleInspectSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    let item: MemoryConsoleItem

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.kind.displayName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(item.relevanceExplanation)
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground)
                        )
                }
                .buttonStyle(.plain)
                .help(Text("Close", bundle: .module))
            }
            .padding(20)

            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inspectBlock("Privacy-safe detail", item.detail.text, monospaced: false)

                    if item.detail.redactionCount > 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("REDACTIONS", bundle: .module)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(theme.tertiaryText)
                                .tracking(0.3)
                            ForEach(item.detail.redactionCounts.keys.sorted(), id: \.self) { key in
                                Text("\(key): \(item.detail.redactionCounts[key] ?? 0)", bundle: .module)
                                    .font(.system(size: 12))
                                    .foregroundColor(theme.secondaryText)
                            }
                        }
                    }

                    metadataGrid
                }
                .padding(20)
            }
        }
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
    }

    private var metadataGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("METADATA", bundle: .module)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(theme.tertiaryText)
                .tracking(0.3)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                metadataTile("Storage ID", item.storageId)
                metadataTile("Agent", item.agentId)
                if let status = item.metadata.status { metadataTile("Status", status) }
                if let salience = item.metadata.salience { metadataTile("Salience", "\(Int(salience * 100))%") }
                if let useCount = item.metadata.useCount { metadataTile("Use count", "\(useCount)") }
                if let sourceCount = item.metadata.sourceCount { metadataTile("Sources", "\(sourceCount)") }
                if let sourceEpisodeId = item.metadata.sourceEpisodeId {
                    metadataTile("Source episode", "\(sourceEpisodeId)")
                }
                if let tokenCount = item.metadata.tokenCount { metadataTile("Tokens", "\(tokenCount)") }
                if let conversationId = item.metadata.conversationId {
                    metadataTile("Conversation", conversationId)
                }
                if let chunkIndex = item.metadata.chunkIndex { metadataTile("Chunk", "\(chunkIndex)") }
                if let role = item.metadata.role { metadataTile("Role", role) }
                if let model = item.metadata.model, !model.isEmpty { metadataTile("Model", model) }
                if let createdAt = item.metadata.createdAt { metadataTile("Created", createdAt) }
                if let conversationAt = item.metadata.conversationAt {
                    metadataTile("Conversation at", conversationAt)
                }
                if !item.metadata.tags.isEmpty { metadataTile("Tags", item.metadata.tags.joined(separator: ", ")) }
                if !item.metadata.topics.isEmpty {
                    metadataTile("Topics", item.metadata.topics.joined(separator: ", "))
                }
                if !item.metadata.entities.isEmpty {
                    metadataTile("Entities", item.metadata.entities.joined(separator: ", "))
                }
            }
        }
    }

    private func inspectBlock(_ title: String, _ text: String, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(theme.tertiaryText)
                .tracking(0.3)

            Text(text)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .foregroundColor(theme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.inputBackground.opacity(0.7))
                )
        }
    }

    private func metadataTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(theme.inputBackground.opacity(0.6))
        )
    }
}

#endif
