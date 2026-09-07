#if !OSAURUS_INTEL
//
//  MemoryView.swift
//  osaurus
//
//  v2 memory management UI: identity, pinned facts, episodes,
//  consolidation, statistics, and danger zone.
//

import SwiftUI

struct MemoryView: View {
    @ObservedObject var themeManager = ThemeManager.shared
    @ObservedObject var agentManager = AgentManager.shared
    @ObservedObject private var appConfig = AppConfiguration.shared

    var theme: ThemeProtocol { themeManager.currentTheme }

    private static let iso8601Formatter = ISO8601DateFormatter()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func formatRelativeDate(_ iso8601: String) -> String {
        guard let date = iso8601Formatter.date(from: iso8601) else { return iso8601 }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Data State

    // The diagnostics-related state below is internal (not private) so
    // `MemoryView+Diagnostics` (sibling extension file) can read & write
    // it. Swift extensions in another file see `internal` members but
    // not `private` ones — adopting internal here is the simplest way
    // to keep the diagnostics view-builders out of this file without
    // resorting to a view-model wrapper.
    @State var config = MemoryConfiguration.default
    @State private var identity: Identity?
    @State private var processingStats = ProcessingStats()
    @State private var dbSizeBytes: Int64 = 0
    @State private var agentMemoryCounts: [(agent: Agent, count: Int)] = []
    @State private var defaultAgentPinned: [PinnedFact] = []
    @State private var defaultAgentEpisodes: [Episode] = []
    @State var pendingSignals = PendingSignalsSummary()
    @State var totalEpisodes: Int = 0
    @State var totalPinned: Int = 0
    @State var coreModelStatus: CoreModelStatus = .unset
    @State var recentLogs: [ProcessingLogRow] = []
    @State var diagnosticsExpanded: Bool = false
    @State var bufferTelemetry = BufferTurnTelemetry()
    @State var memoryDBOpen: Bool = false
    @State var chatActive: Bool = false
    @State var distillSnapshot = DistillationCoordinator.Snapshot(queued: 0, active: false)
    @State var probeBufferRunning: Bool = false
    @State var probeBufferResult: BufferProbeOutcome?
    @State var backfillRunning: Bool = false
    @State var backfillProgress = MemoryBackfillProgress()
    @State var backfillTask: Task<Void, Never>?
    @State var backfillSummary: String?
    @State var showBackfillConfirm: Bool = false

    /// Wall-clock timestamp of the last `loadData()` that landed values
    /// on MainActor. Used by the on-appear path to short-circuit when
    /// the user re-enters the Memory tab and our cached state is still
    /// fresh — the in-view mutation sites (`saveIdentityEdit`, override
    /// add/remove, distill, consolidate, clear, etc.) still pass
    /// `forceReload: true` so they always re-fetch.
    @State var lastLoadedAt: Date?

    /// Default freshness window for `.onAppear` refreshes. The Memory
    /// tab opens many SQLite cursors per load; a 10 s window means a
    /// quick tab-toggle round trip (Settings → Memory → Settings →
    /// Memory) no longer re-hits the database.
    static let memoryDataFreshWindow: TimeInterval = 10

    // MARK: UI State

    @State private var selectedAgent: Agent?
    @State private var hasAppeared = false
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var isSyncing = false
    @State private var isDistilling = false
    @State private var isConsolidating = false
    @State private var showIdentityEditor = false
    @State private var showAddOverride = false
    @State private var contextPreviewItem: ContextPreviewItem?
    @State private var showClearConfirmation = false
    @State private var toastMessage: (text: String, isError: Bool)?

    var body: some View {
        ZStack {
            if selectedAgent == nil {
                memoryContent
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            if let agent = selectedAgent {
                AgentDetailView(
                    agent: agent,
                    onBack: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            selectedAgent = nil
                        }
                    },
                    onDelete: { _ in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            selectedAgent = nil
                        }
                        loadData()
                    },
                    onSwitchAgent: { newAgent in
                        // Same id-based reload pattern as `AgentsView`. Memory's
                        // entry point is read-only context (no Agents grid), so we
                        // just swap the in-memory selection.
                        selectedAgent = newAgent
                    },
                    showSuccess: { msg in
                        showToast(msg)
                    }
                )
                .id(agent.id)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
    }

    private var memoryContent: some View {
        ZStack {
            VStack(spacing: 0) {
                headerView
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : -10)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

                Group {
                    if isLoading {
                        VStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                                .padding(.bottom, 4)
                            Text("Loading memory...", bundle: .module)
                                .font(.system(size: 12))
                                .foregroundColor(theme.tertiaryText)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if !config.enabled {
                                    disabledBanner
                                }

                                identitySection
                                overridesSection
                                agentsSection
                                statsSection
                                configurationSection
                                dangerZoneSection
                                diagnosticsSection
                            }
                            .padding(24)
                        }
                    }
                }
                .opacity(hasAppeared ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let toast = toastMessage {
                VStack {
                    Spacer()
                    ThemedToastView(toast.text, type: toast.isError ? .error : .success)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 20)
                }
                .zIndex(100)
            }
        }
        .onAppear {
            loadData(staleAfter: Self.memoryDataFreshWindow)
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .sheet(isPresented: $showIdentityEditor) {
            IdentityEditSheet(
                identity: identity,
                onSave: { newContent in
                    saveIdentityEdit(newContent)
                    showToast(L("Identity saved"))
                }
            )
            .frame(minWidth: 500, minHeight: 400)
        }
        .sheet(isPresented: $showAddOverride) {
            AddOverrideSheet(
                onAdd: { text in
                    addOverride(text)
                    showToast(L("Override added"))
                }
            )
            .frame(minWidth: 440, minHeight: 220)
        }
        .sheet(item: $contextPreviewItem) { item in
            ContextPreviewSheet(context: item.text)
                .frame(minWidth: 560, minHeight: 420)
        }
        .themedAlert(
            "Clear All Memory",
            isPresented: $showClearConfirmation,
            message:
                "This will permanently delete your identity, all pinned facts, episodes, and conversation history. This cannot be undone.",
            primaryButton: .destructive("Clear Everything") {
                clearAllMemory()
            },
            secondaryButton: .cancel("Cancel")
        )
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Memory"),
            subtitle: L("Manage your identity, overrides, and memory configuration")
        ) {
            HeaderIconButton("arrow.clockwise", isLoading: isRefreshing, help: "Refresh") {
                refreshData()
            }
            .accessibilityLabel(Text("Refresh memory data", bundle: .module))
        }
    }

    // MARK: - Disabled Banner

    private var disabledBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(theme.warningColor)

            Text("Memory system is disabled. Enable it below to start building memory.", bundle: .module)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)

            Spacer()

            Button {
                config.enabled = true
                MemoryConfigurationStore.save(config)
                loadData()
                showToast(L("Memory enabled"))
            } label: {
                Text("Enable", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.warningColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.warningColor.opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: - Identity Section

    private var identitySection: some View {
        MemorySectionCard(title: "Identity", icon: "person.text.rectangle") {
            // "Distill pending" goes through `syncNow()` directly. The
            // important difference vs `recoverOrphanedSignals()` (which
            // runs at app launch) is that this path skips the
            // `canDistillCheaply` guard, so it works for users who picked
            // a large local MLX model that isn't resident yet.
            MemorySectionActionButton(
                isDistilling ? "Distilling..." : "Distill pending",
                icon: "wand.and.stars"
            ) {
                guard !isDistilling else { return }
                isDistilling = true
                Task.detached {
                    // `force: true` — user explicitly asked, so the
                    // coordinator's residency gate is bypassed. Chat-
                    // idle wait still applies per-distill so a live
                    // chat doesn't get its tok/sec halved.
                    await MemoryService.shared.syncNow(force: true)
                    await MainActor.run {
                        isDistilling = false
                        loadData()
                        showToast(L("Pending distillation complete"))
                    }
                }
            }
            .disabled(isDistilling || !config.enabled)

            MemorySectionActionButton(isSyncing ? "Syncing..." : "Sync", icon: "arrow.triangle.2.circlepath") {
                guard !isSyncing else { return }
                isSyncing = true
                Task.detached {
                    await MemoryService.shared.syncNow(force: true)
                    await MainActor.run {
                        isSyncing = false
                        loadData()
                        showToast(L("Sync complete"))
                    }
                }
            }
            .disabled(isSyncing || !config.enabled)

            MemorySectionActionButton("Edit", icon: "pencil") {
                showIdentityEditor = true
            }
        } content: {
            if let identity, !identity.content.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(identity.content)
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.inputBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )

                    HStack(spacing: 12) {
                        if identity.version > 0 {
                            metadataTag("v\(identity.version)")
                        }
                        metadataTag(pluralizedMemory(identity.tokenCount, "token"))
                        if !identity.model.isEmpty {
                            metadataTag(identity.model)
                        }

                        Spacer()

                        if !identity.generatedAt.isEmpty {
                            Text(Self.formatRelativeDate(identity.generatedAt))
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .help(identity.generatedAt)
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundColor(theme.tertiaryText)
                    Text(
                        "No identity yet. Chat with Osaurus and the memory system will build your identity from session distillations.",
                        bundle: .module
                    )
                    .font(.system(size: 13))
                    .foregroundColor(theme.tertiaryText)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
            }
        }
    }

    // MARK: - Overrides Section

    private var overridesSection: some View {
        let overrides = identity?.overrides ?? []
        return MemorySectionCard(
            title: "Your Overrides",
            icon: "pin.fill",
            count: overrides.isEmpty ? nil : overrides.count
        ) {
            MemorySectionActionButton("Add", icon: "plus") {
                showAddOverride = true
            }
        } content: {
            if overrides.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundColor(theme.tertiaryText)
                    Text(
                        "No overrides set. Add explicit facts that should always be in your identity.",
                        bundle: .module
                    )
                    .font(.system(size: 13))
                    .foregroundColor(theme.tertiaryText)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(overrides.enumerated()), id: \.offset) { index, content in
                        if index > 0 {
                            Divider().opacity(0.5)
                        }
                        MemoryOverrideRow(
                            content: content,
                            onDelete: {
                                removeOverride(index: index)
                                showToast(L("Override removed"))
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Default Agent Memory Group

    private var defaultAgentMemoryGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Default Agent", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    Text("Uses your global chat settings", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }

                Spacer()

                let totalCount = defaultAgentPinned.count + defaultAgentEpisodes.count
                if totalCount > 0 {
                    Text(pluralizedMemory(totalCount, "memory", "memories"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(theme.tertiaryBackground)
                        )
                }

                Button {
                    Task {
                        let cfg = MemoryConfigurationStore.load()
                        let ctx = await MemoryContextAssembler.assembleContext(
                            agentId: Agent.defaultId.uuidString,
                            config: cfg
                        )
                        let trimmed = ctx.trimmingCharacters(in: .whitespacesAndNewlines)
                        let text =
                            trimmed.isEmpty
                            ? "(No memory context assembled — memory may be empty or disabled)"
                            : trimmed
                        contextPreviewItem = ContextPreviewItem(text: text)
                    }
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.tertiaryBackground)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .localizedHelp("Preview memory context")
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)

            if !defaultAgentPinned.isEmpty || !defaultAgentEpisodes.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    if !defaultAgentPinned.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(theme.tertiaryText)
                                Text("PINNED FACTS", bundle: .module)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(theme.tertiaryText)
                                    .tracking(0.3)
                                Text("\(defaultAgentPinned.count)", bundle: .module)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(theme.tertiaryText)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(theme.tertiaryBackground))
                            }

                            PinnedFactsPanel(
                                facts: defaultAgentPinned,
                                onDelete: { factId in
                                    try? MemoryDatabase.shared.deletePinnedFact(id: factId)
                                    defaultAgentPinned.removeAll { $0.id == factId }
                                }
                            )
                            .frame(maxHeight: 400)
                        }
                    }

                    if !defaultAgentEpisodes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(theme.tertiaryText)
                                Text("EPISODES", bundle: .module)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(theme.tertiaryText)
                                    .tracking(0.3)
                                Text("\(defaultAgentEpisodes.count)", bundle: .module)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(theme.tertiaryText)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(theme.tertiaryBackground))
                            }

                            ScrollView {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(defaultAgentEpisodes.enumerated()), id: \.element.id) {
                                        index,
                                        episode in
                                        if index > 0 {
                                            Divider().opacity(0.5)
                                        }
                                        EpisodeRow(episode: episode)
                                    }
                                }
                            }
                            .frame(maxHeight: 300)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.inputBackground.opacity(0.5))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(theme.inputBorder, lineWidth: 1)
                                    )
                            )
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: - Agents Section

    private var agentsSection: some View {
        MemorySectionCard(title: "Agents", icon: "person.2") {
            VStack(spacing: 0) {
                defaultAgentMemoryGroup

                if !agentMemoryCounts.isEmpty {
                    Divider()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)

                    ForEach(Array(agentMemoryCounts.enumerated()), id: \.element.agent.id) { index, pair in
                        if index > 0 {
                            Divider().opacity(0.5)
                        }
                        MemoryAgentRow(
                            agent: pair.agent,
                            count: pair.count,
                            onSelect: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    selectedAgent = pair.agent
                                }
                            },
                            onPreviewContext: {
                                Task {
                                    let cfg = MemoryConfigurationStore.load()
                                    let ctx = await MemoryContextAssembler.assembleContext(
                                        agentId: pair.agent.id.uuidString,
                                        config: cfg
                                    )
                                    let trimmed = ctx.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let text =
                                        trimmed.isEmpty
                                        ? "(No memory context assembled — memory may be empty or disabled)"
                                        : trimmed
                                    contextPreviewItem = ContextPreviewItem(text: text)
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Diagnostics Section
    //
    // The diagnostics card is large enough to live in its own file —
    // see `MemoryDiagnosticsViews.swift` for `diagnosticsSection`,
    // `runBackfill`, `runBufferProbe`, and all of the row / banner /
    // headline helpers. The state those views read & write is declared
    // above (intentionally non-private so a sibling extension file can
    // see it).

    // MARK: - Statistics Section

    private var statsSection: some View {
        MemorySectionCard(title: "Statistics", icon: "chart.bar") {
            HStack(spacing: 0) {
                statBlock(label: "Total Calls", value: "\(processingStats.totalCalls)")
                Divider().frame(height: 36).opacity(0.5)
                statBlock(label: "Avg Latency", value: "\(processingStats.avgDurationMs)ms")
                Divider().frame(height: 36).opacity(0.5)
                statBlock(label: "Success", value: "\(processingStats.successCount)")
                Divider().frame(height: 36).opacity(0.5)
                statBlock(label: "Errors", value: "\(processingStats.errorCount)")
                Divider().frame(height: 36).opacity(0.5)
                statBlock(label: "Database", value: formatBytes(dbSizeBytes))
            }
        }
    }

    // MARK: - Configuration Section

    private var configurationSection: some View {
        MemorySectionCard(title: "Configuration", icon: "gearshape") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text("Core Model", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 140, alignment: .leading)

                    Text(appConfig.chatConfig.coreModelIdentifier ?? "None")
                        .font(.system(size: 13))
                        .foregroundColor(theme.primaryText)

                    Spacer()

                    Text("Change in Settings → General", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }

                Divider().opacity(0.5)

                HStack(spacing: 12) {
                    Text("Memory Budget", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 140, alignment: .leading)

                    HStack(spacing: 8) {
                        Stepper("", value: $config.memoryBudgetTokens, in: 100 ... 4000, step: 100)
                            .labelsHidden()
                        Text(pluralizedMemory(config.memoryBudgetTokens, "token"))
                            .font(.system(size: 13))
                            .foregroundColor(theme.primaryText)
                    }
                    .onChange(of: config.memoryBudgetTokens) { _ in
                        MemoryConfigurationStore.save(config)
                    }
                }

                Divider().opacity(0.5)

                HStack(spacing: 12) {
                    Text("Episode Retention", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 140, alignment: .leading)

                    HStack(spacing: 8) {
                        Stepper("", value: $config.episodeRetentionDays, in: 0 ... 3650, step: 30)
                            .labelsHidden()
                        Text(
                            config.episodeRetentionDays == 0
                                ? "forever" : pluralizedMemory(config.episodeRetentionDays, "day")
                        )
                        .font(.system(size: 13))
                        .foregroundColor(theme.primaryText)
                    }
                    .onChange(of: config.episodeRetentionDays) { _ in
                        MemoryConfigurationStore.save(config)
                    }
                }

                Divider().opacity(0.5)

                HStack(spacing: 12) {
                    Text("Consolidation", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 140, alignment: .leading)

                    HStack(spacing: 8) {
                        Stepper("", value: $config.consolidationIntervalHours, in: 1 ... 168)
                            .labelsHidden()
                        Text("every \(pluralizedMemory(config.consolidationIntervalHours, "hour"))", bundle: .module)
                            .font(.system(size: 13))
                            .foregroundColor(theme.primaryText)
                    }
                    .onChange(of: config.consolidationIntervalHours) { _ in
                        MemoryConfigurationStore.save(config)
                    }

                    Spacer()

                    Button {
                        guard !isConsolidating else { return }
                        isConsolidating = true
                        Task.detached {
                            await MemoryConsolidator.shared.runOnce()
                            await MainActor.run {
                                isConsolidating = false
                                loadData()
                                showToast(L("Consolidation complete"))
                            }
                        }
                    } label: {
                        Text(isConsolidating ? "Running..." : "Run Now", bundle: .module)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.tertiaryBackground)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isConsolidating || !config.enabled)
                }

                Divider().opacity(0.5)

                HStack(spacing: 12) {
                    Text("Status", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 140, alignment: .leading)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(config.enabled ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(config.enabled ? "Active" : "Disabled")
                            .font(.system(size: 13))
                            .foregroundColor(theme.primaryText)
                    }

                    Spacer()

                    Toggle("", isOn: $config.enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: config.enabled) { _ in
                            MemoryConfigurationStore.save(config)
                        }
                }
            }
        }
    }

    // MARK: - Danger Zone

    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.errorColor)
                    .frame(width: 20)

                Text("DANGER ZONE", bundle: .module)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.errorColor)
                    .tracking(0.5)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clear All Memory", bundle: .module)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Text(
                            "Permanently delete identity, pinned facts, episodes, and conversation history.",
                            bundle: .module
                        )
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                    }

                    Spacer()

                    Button {
                        showClearConfirmation = true
                    } label: {
                        Text("Clear All", bundle: .module)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.errorColor)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.errorColor.opacity(0.1))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(theme.errorColor.opacity(0.3), lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.errorColor.opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: - Helpers

    private func metadataTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(theme.tertiaryBackground)
            )
    }

    private func statBlock(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(theme.primaryText)
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringKey(label), bundle: .module) + Text(": \(value)"))
    }

    // MARK: - Data Loading

    private func refreshData() {
        guard !isRefreshing else { return }
        isRefreshing = true
        loadData {
            isRefreshing = false
        }
    }

    func loadData(
        onComplete: (@Sendable @MainActor () -> Void)? = nil,
        staleAfter: TimeInterval = 0
    ) {
        // Skip if the previous load is still within the freshness
        // window. Setting `staleAfter` to 0 (the default) preserves the
        // existing always-reload behavior for in-view mutation
        // callsites; `.onAppear` passes `memoryDataFreshWindow` to
        // avoid the redundant SQLite walk on quick tab revisits.
        if staleAfter > 0,
            let last = lastLoadedAt,
            Date().timeIntervalSince(last) < staleAfter,
            !isLoading
        {
            onComplete?()
            return
        }

        config = MemoryConfigurationStore.load()
        Task.detached(priority: .userInitiated) {
            let db = MemoryDatabase.shared
            if !db.isOpen {
                do { try db.open() } catch {
                    MemoryLogger.database.error("Failed to open database from MemoryView: \(error)")
                    await MainActor.run {
                        isLoading = false
                        onComplete?()
                        showToast(L("Failed to open memory database"), isError: true)
                    }
                    return
                }
            }
            var loadError: String?
            let loadedIdentity: Identity?
            let loadedStats: ProcessingStats
            let loadedSize: Int64
            do {
                loadedIdentity = try db.loadIdentity()
            } catch {
                MemoryLogger.database.error("Failed to load identity: \(error)")
                loadedIdentity = nil
                loadError = "Failed to load identity"
            }
            do {
                loadedStats = try db.processingStats()
            } catch {
                MemoryLogger.database.error("Failed to load stats: \(error)")
                loadedStats = ProcessingStats()
            }
            loadedSize = db.databaseSizeBytes()

            let agentEntries = (try? db.agentIdsWithPinnedFacts()) ?? []

            let agents = await MainActor.run { agentManager.agents }
            let agentLookup = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
            let resolvedCounts: [(agent: Agent, count: Int)] = agentEntries.compactMap { pair in
                guard let uuid = UUID(uuidString: pair.agentId),
                    !Agent.isDefaultAgentId(pair.agentId),
                    let agent = agentLookup[uuid]
                else { return nil }
                return (agent: agent, count: pair.count)
            }

            let defaultId = Agent.defaultId.uuidString
            let loadedDefaultPinned = (try? db.loadPinnedFacts(agentId: defaultId, limit: 100)) ?? []
            let loadedDefaultEpisodes = (try? db.loadEpisodes(agentId: defaultId, limit: 50)) ?? []

            // Diagnostics panel data — kept in the same Task so we don't
            // re-open the database three times per refresh.
            let loadedPending = (try? db.pendingSignalsSummary()) ?? PendingSignalsSummary()
            let loadedTotalEpisodes = (try? db.episodeCount()) ?? 0
            let loadedTotalPinned = (try? db.pinnedFactCount()) ?? 0
            let loadedRecentLogs = (try? db.recentProcessingLog(limit: 20)) ?? []
            let loadedCoreModelStatus = await CoreModelService.shared.resolveStatus()
            let loadedTelemetry = await MemoryService.shared.bufferTelemetry()
            let loadedDBOpen = MemoryDatabase.shared.isOpen
            let loadedChatActive = await InferenceLoadCoordinator.shared.chatActive
            let loadedDistillSnapshot = await DistillationCoordinator.shared.snapshot()

            await MainActor.run {
                identity = loadedIdentity
                processingStats = loadedStats
                dbSizeBytes = loadedSize
                agentMemoryCounts = resolvedCounts
                defaultAgentPinned = loadedDefaultPinned
                defaultAgentEpisodes = loadedDefaultEpisodes
                pendingSignals = loadedPending
                totalEpisodes = loadedTotalEpisodes
                totalPinned = loadedTotalPinned
                recentLogs = loadedRecentLogs
                coreModelStatus = loadedCoreModelStatus
                bufferTelemetry = loadedTelemetry
                memoryDBOpen = loadedDBOpen
                chatActive = loadedChatActive
                distillSnapshot = loadedDistillSnapshot
                isLoading = false
                lastLoadedAt = Date()
                onComplete?()
                if let loadError {
                    showToast(loadError, isError: true)
                }
            }
        }
    }

    // MARK: - Actions

    private func removeOverride(index: Int) {
        do {
            try MemoryDatabase.shared.removeIdentityOverride(at: index)
        } catch {
            MemoryLogger.database.error("Failed to remove override: \(error)")
            showToast(L("Failed to remove override"), isError: true)
        }
        loadData()
    }

    private func addOverride(_ text: String) {
        do {
            try MemoryDatabase.shared.appendIdentityOverride(text)
        } catch {
            MemoryLogger.database.error("Failed to add override: \(error)")
            showToast(L("Failed to add override"), isError: true)
        }
        loadData()
    }

    private func saveIdentityEdit(_ content: String) {
        let tokenCount = max(1, content.count / MemoryConfiguration.charsPerToken)
        var updated = identity ?? Identity()
        updated.content = content
        updated.tokenCount = tokenCount
        updated.model = "user"
        updated.generatedAt = Self.iso8601Formatter.string(from: Date())
        if updated.version == 0 { updated.version = 1 }

        do {
            try MemoryDatabase.shared.saveIdentity(updated)
        } catch {
            MemoryLogger.database.error("Failed to save identity: \(error)")
            showToast(L("Failed to save identity"), isError: true)
        }
        loadData()
    }

    private func clearAllMemory() {
        let db = MemoryDatabase.shared
        db.close()
        let dbFile = OsaurusPaths.memoryDatabaseFile()
        try? FileManager.default.removeItem(at: dbFile)
        try? db.open()
        Task { await MemorySearchService.shared.clearIndex() }
        loadData()
        showToast(L("All memory cleared"))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    func showToast(_ message: String, isError: Bool = false) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            toastMessage = (message, isError)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeOut(duration: 0.3)) {
                toastMessage = nil
            }
        }
    }
}
#else
import SwiftUI

/// Intel memory tab. The upstream `MemoryView` (the `#if !OSAURUS_INTEL` half)
/// drives the MLX/VecturaKit distillation+episode subsystem; on Intel we expose
/// the Phase-1 transcript-recall MVP, mirroring upstream's tab order
/// (Identity, Memories, Agents, Settings, Diagnostics — no separate
/// Statistics tab, see below):
///  - **Identity**: the auto-derived identity narrative (written by
///    `IntelMemoryService.applyIdentityDelta`) plus user overrides, and the
///    "Distill pending" / "Sync" actions (both `MemoryService.syncNow(force:)`).
///  - **Settings**: statistics section, master toggle, embedding-backend
///    picker (off / on-device static model2vec / cloud), recall budget,
///    consolidation interval, and clear-memory. Statistics lives here, at
///    the top, rather than as its own tab — matching upstream, which has no
///    Statistics tab at all.
///  - **Diagnostics**: pipeline health, bound to `MemoryDiagnostics.shared`
///    (`Models/Chat/IntelConformers/IntelMemoryDiagnostics.swift`) — see
///    `MemoryDiagnosticsViews.swift`'s `#else` branch for the view content.
/// Storage is the SQLCipher-encrypted memory DB; embeddings are the pure-Swift
/// `StaticEmbedder` or an OpenAI-compatible cloud API.
enum MemoryTab: String, CaseIterable, AnimatedTabItem {
    case identity = "Identity"
    case memories = "Memories"
    case agents = "Agents"
    case settings = "Settings"
    case diagnostics = "Diagnostics"

    var title: String {
        switch self {
        case .identity: return L("Identity")
        case .memories: return L("Memories")
        case .agents: return L("Agents")
        case .settings: return L("Settings")
        case .diagnostics: return L("Diagnostics")
        }
    }
}

struct MemoryView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }
    // Backs the tab-label counts/badge (Bug 1 — ported from upstream's
    // `HeaderTabsRow(counts:badges:)` call). `MemoryDiagnostics.shared` is
    // the single already-live source for episode/pinned counts and the
    // pending-signal badge — see `Models/Chat/IntelConformers/IntelMemoryDiagnostics.swift`.
    @ObservedObject private var diagnostics = MemoryDiagnostics.shared
    @ObservedObject private var managementState = ManagementStateManager.shared

    @State private var selectedTab: MemoryTab = .identity
    @State private var hasAppeared = false
    // Row count reported by `MemoryAgentsTabContent` (Default row + every
    // agent/project row it actually renders) so the "Agents (n)" label
    // counts what the tab shows, not a number this view would otherwise
    // have to re-derive from a database read of its own.
    @State private var agentsTabRowCount: Int = 0

    private var tabCounts: [MemoryTab: Int] {
        [
            .memories: (diagnostics.snapshot?.pinnedFactCount ?? 0) + (diagnostics.snapshot?.episodeCount ?? 0),
            .agents: agentsTabRowCount,
        ]
    }

    private var tabBadges: [MemoryTab: Int] {
        [.diagnostics: diagnostics.snapshot?.pendingSignals ?? 0]
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            Group {
                switch selectedTab {
                case .identity:
                    MemoryIdentityTabContent()
                case .memories:
                    MemoryConsoleTabContent()
                case .agents:
                    MemoryAgentsTabContent(onRowCountChanged: { agentsTabRowCount = $0 })
                case .settings:
                    MemorySettingsTabContent()
                case .diagnostics:
                    MemoryDiagnosticsTabContent()
                }
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
            consumePendingSubTabRequest()
            Task { await diagnostics.refresh() }
        }
        // Single-parameter `onChange` — macOS 13 target (the two-parameter
        // `{ old, new in }` form upstream uses is macOS 14+ and would not
        // compile here). Lets "Browse in Memories" jump tabs even when this
        // view is already on screen (`onAppear` alone only fires once).
        .onChange(of: managementState.memorySubTabRequest) { _ in
            consumePendingSubTabRequest()
        }
    }

    /// Honors a cross-view sub-tab request — currently just the Agents
    /// tab's "Browse in Memories" button — the same
    /// `ManagementStateManager.memorySubTabRequest` mechanism upstream
    /// uses for its own settings-search deep links.
    private func consumePendingSubTabRequest() {
        guard let requested = managementState.memorySubTabRequest,
            let tab = MemoryTab(rawValue: requested)
        else { return }
        selectedTab = tab
        managementState.memorySubTabRequest = nil
    }

    private var headerView: some View {
        ManagerHeaderWithTabs(
            title: L("Memory"),
            subtitle: L(
                "On-device semantic memory — your chats are embedded locally and recalled when relevant.")
        ) {
            EmptyView()
        } tabsRow: {
            HeaderTabsRow(selection: $selectedTab, counts: tabCounts, badges: tabBadges)
        }
    }
}

// MARK: - Identity Tab

/// Displays the auto-derived identity narrative and user overrides, both
/// read straight from `MemoryDatabase` — there is no separate Intel
/// "identity service" to bind to. `identity.content` is written by
/// `IntelMemoryService.applyIdentityDelta` after session-end distillation,
/// so a fresh install (or one where no session has been distilled yet)
/// legitimately has nothing here; that's rendered as an explicit empty
/// state below, never a blank panel.
private struct MemoryIdentityTabContent: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var identity: Identity?
    @State private var databaseOpen = false
    @State private var showEditSheet = false
    @State private var showAddOverride = false
    @State private var errorMessage: String?

    // "Distill pending" / "Sync" (Bug 2 — ported from upstream, which wires
    // both to `MemoryService.syncNow(force: true)`; on Intel there's no MLX
    // residency gate to bypass, so the two behave the same, same as
    // `MemoryService`'s own doc comment on `syncNow` notes).
    @State private var config = MemoryConfigurationStore.load()
    @State private var isDistilling = false
    @State private var isSyncing = false
    @State private var actionStatus: String?

    private static let iso8601Formatter = ISO8601DateFormatter()
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static func formatRelativeDate(_ iso8601: String) -> String {
        guard let date = iso8601Formatter.date(from: iso8601) else { return iso8601 }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor)
                }
                identityCard
                overridesCard
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .onAppear(perform: reload)
        .sheet(isPresented: $showEditSheet) {
            IdentityEditSheet(identity: identity, onSave: saveIdentityEdit)
                .frame(minWidth: 500, minHeight: 400)
        }
        .sheet(isPresented: $showAddOverride) {
            AddOverrideSheet(onAdd: addOverride)
                .frame(minWidth: 440, minHeight: 220)
        }
    }

    private var identityCard: some View {
        MemorySectionCard(title: "Identity", icon: "person.fill") {
            // Ported from upstream's Identity card header (the
            // `#if !OSAURUS_INTEL` half of this file, `identitySection`):
            // "Distill pending", "Sync", "Edit". Both distill actions go
            // through `MemoryService.syncNow(force: true)` — see that
            // method's doc comment for why both behave the same on Intel.
            MemorySectionActionButton(
                isDistilling ? "Distilling..." : "Distill pending",
                icon: "wand.and.stars"
            ) {
                runDistillPending()
            }
            .disabled(isDistilling || !config.enabled)

            MemorySectionActionButton(
                isSyncing ? "Syncing..." : "Sync",
                icon: "arrow.triangle.2.circlepath"
            ) {
                runSync()
            }
            .disabled(isSyncing || !config.enabled)

            MemorySectionActionButton("Edit", icon: "pencil") {
                showEditSheet = true
            }
        } content: {
            if let actionStatus {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(theme.successColor)
                    Text(actionStatus)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
                .transition(.opacity)
            }
            if let identity, !identity.content.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(identity.content)
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.inputBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )

                    HStack(spacing: 12) {
                        if identity.version > 0 {
                            metadataTag("v\(identity.version)")
                        }
                        metadataTag(pluralizedMemory(identity.tokenCount, "token"))
                        if !identity.model.isEmpty {
                            metadataTag(identity.model)
                        }

                        Spacer()

                        if !identity.generatedAt.isEmpty {
                            Text(Self.formatRelativeDate(identity.generatedAt))
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .help(identity.generatedAt)
                        }
                    }
                }
            } else if databaseOpen {
                emptyState(
                    "No identity yet. Chat with Osaurus and the memory system will build your identity from session distillations."
                )
            } else {
                emptyState("Memory database is not open yet — identity will appear here once it is.")
            }
        }
    }

    private var overridesCard: some View {
        let overrides = identity?.overrides ?? []
        return MemorySectionCard(
            title: "Your Overrides",
            icon: "pin.fill",
            count: overrides.isEmpty ? nil : overrides.count
        ) {
            MemorySectionActionButton("Add", icon: "plus") {
                showAddOverride = true
            }
        } content: {
            if overrides.isEmpty {
                emptyState("No overrides set. Add explicit facts that should always be in your identity.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(overrides.enumerated()), id: \.offset) { index, content in
                        if index > 0 {
                            Divider().opacity(0.5)
                        }
                        MemoryOverrideRow(content: content) {
                            removeOverride(index: index, expectedText: content)
                        }
                    }
                }
            }
        }
    }

    private func metadataTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.tertiaryBackground))
    }

    private func emptyState(_ key: String.LocalizationValue) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundColor(theme.tertiaryText)
            Text(L(key))
                .font(.system(size: 13))
                .foregroundColor(theme.tertiaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Data

    private func reload() {
        config = MemoryConfigurationStore.load()
        let db = MemoryDatabase.shared
        databaseOpen = db.isOpen
        guard databaseOpen else {
            identity = nil
            return
        }
        do {
            identity = try db.loadIdentity()
            errorMessage = nil
        } catch {
            MemoryLogger.database.error("Failed to load identity: \(error)")
            errorMessage = L("Failed to load identity")
        }
    }

    /// "Distill pending" — mirrors upstream's `runDistillPending()`
    /// (identical body: `syncNow(force: true)`, reload, toast/status).
    private func runDistillPending() {
        guard !isDistilling else { return }
        isDistilling = true
        Task {
            await MemoryService.shared.syncNow(force: true)
            await MainActor.run {
                reload()
                isDistilling = false
                withAnimation(.easeInOut(duration: 0.2)) {
                    actionStatus = L("Pending distillation complete")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation(.easeInOut(duration: 0.2)) { actionStatus = nil }
                }
            }
        }
    }

    /// "Sync" — mirrors upstream's inline `syncNow(force: true)` call.
    private func runSync() {
        guard !isSyncing else { return }
        isSyncing = true
        Task {
            await MemoryService.shared.syncNow(force: true)
            await MainActor.run {
                reload()
                isSyncing = false
                withAnimation(.easeInOut(duration: 0.2)) {
                    actionStatus = L("Sync complete")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation(.easeInOut(duration: 0.2)) { actionStatus = nil }
                }
            }
        }
    }

    private func saveIdentityEdit(_ content: String) {
        let tokenCount = max(1, content.count / MemoryConfiguration.charsPerToken)
        var updated = identity ?? Identity()
        updated.content = content
        updated.tokenCount = tokenCount
        updated.model = "user"
        updated.generatedAt = Self.iso8601Formatter.string(from: Date())
        if updated.version == 0 { updated.version = 1 }

        do {
            try MemoryDatabase.shared.saveIdentity(updated)
            errorMessage = nil
        } catch {
            MemoryLogger.database.error("Failed to save identity: \(error)")
            errorMessage = L("Failed to save identity")
        }
        reload()
    }

    private func addOverride(_ text: String) {
        do {
            try MemoryDatabase.shared.appendIdentityOverride(text)
            errorMessage = nil
        } catch {
            MemoryLogger.database.error("Failed to add override: \(error)")
            errorMessage = L("Failed to add override")
        }
        reload()
    }

    private func removeOverride(index: Int, expectedText: String) {
        do {
            try MemoryDatabase.shared.removeIdentityOverride(at: index, expectedText: expectedText)
            errorMessage = nil
        } catch {
            MemoryLogger.database.error("Failed to remove override: \(error)")
            errorMessage = L("Failed to remove override")
        }
        reload()
    }
}

// Statistics is no longer its own tab (Bug 3) — upstream has no Statistics
// tab; it's a section at the top of Settings. See `MemorySettingsTabContent`
// (statsCard, above statusCard) for the ported content. The former
// `MemoryStatisticsTabContent` struct was deleted rather than left orphaned.

// MARK: - Settings Tab

/// The original four-card Intel settings panel (status / embedding / budget
/// / danger zone), unchanged in content — only moved under its own tab and,
/// in `dangerCard`, gated behind a confirmation dialog before it existed.
private struct MemorySettingsTabContent: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }
    @Environment(\.themedAlertScope) private var alertScope

    @State private var config = MemoryConfigurationStore.load()
    @State private var modelReady = false
    @State private var isDownloading = false
    @State private var downloadError: String?
    @State private var isConsolidating = false
    @State private var consolidationJustRan = false
    @ObservedObject private var agentManager = AgentManager.shared

    // Statistics (Bug 3 — no longer its own tab; upstream keeps this as a
    // section at the top of Settings, above Configuration/Danger Zone).
    @State private var stats = ProcessingStats()
    @State private var dbSizeBytes: Int64 = 0

    // Distillation model resolution (Bug 1) — populated by
    // `reloadDistillModelStatus()`, never re-derived inline in the view.
    @State private var distillModelName: String?
    @State private var distillModelConfiguredButUnservable: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statsCard
                statusCard
                distillationCard
                embeddingCard
                budgetCard
                dangerCard
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .onAppear {
            reload()
            reloadDistillModelStatus()
        }
    }

    // MARK: - Statistics Card
    //
    // Ported from the now-deleted `MemoryStatisticsTabContent` (see Bug 3):
    // upstream has no separate Statistics tab — statistics is a section at
    // the top of Settings. "tablecells" (not upstream's "chart.bar") is kept
    // deliberately: it is already compiled, ungated, and proven safe
    // elsewhere in this fork's Views/ tree (this exact card, pre-move);
    // "chart.bar" is flagged as unproven macOS-13 risk in
    // docs/MEMORY_PLAN.md's standing constraints.

    private var statsCard: some View {
        MemorySectionCard(title: "Statistics", icon: "tablecells") {
            HStack(spacing: 0) {
                statBlock(label: "Total Calls", value: "\(stats.totalCalls)")
                Divider().frame(height: 36).opacity(0.5)
                statBlock(label: "Avg Latency", value: "\(stats.avgDurationMs)ms")
                Divider().frame(height: 36).opacity(0.5)
                statBlock(label: "Success", value: "\(stats.successCount)")
                Divider().frame(height: 36).opacity(0.5)
                statBlock(label: "Errors", value: "\(stats.errorCount)")
                Divider().frame(height: 36).opacity(0.5)
                statBlock(label: "Database", value: formatBytes(dbSizeBytes))
            }
        }
    }

    private func statBlock(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(theme.primaryText)
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringKey(label), bundle: .module) + Text(": \(value)"))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Cards

    private var statusCard: some View {
        card {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    cardTitle("Status")
                    Text(
                        config.enabled
                            ? L("Your chats are remembered and recalled when relevant.")
                            : L("Memory is off — nothing is stored or recalled.")
                    )
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { config.enabled },
                        set: { v in
                            mutate { $0.enabled = v }
                            if v { Task { await MemorySearchService.shared.initialize() } }
                        })
                )
                .labelsHidden()
                .toggleStyle(.switch)
            }
        }
    }

    private var embeddingCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle("Embeddings")
                Picker(
                    "",
                    selection: Binding(
                        get: { config.embeddingProvider },
                        set: { v in
                            mutate { $0.embeddingProvider = v }
                            modelReady = StaticEmbeddingModel.isAvailable
                        })
                ) {
                    Text("Off", bundle: .module).tag("none")
                    Text("On-device", bundle: .module).tag("staticLocal")
                    Text("Cloud", bundle: .module).tag("cloud")
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch config.embeddingProvider {
                case "staticLocal": localDetail
                case "cloud": cloudDetail
                default:
                    Text(
                        "Recall uses encrypted full-text search — no model, no download, keyword-based.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                }
            }
        }
    }

    private var localDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isDownloading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Downloading model (~30 MB)…", bundle: .module)
                        .font(.system(size: 12)).foregroundColor(theme.secondaryText)
                }
            } else if modelReady {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(theme.successColor)
                    Text("Model ready — potion-base-8M, on-device", bundle: .module)
                        .font(.system(size: 12)).foregroundColor(theme.secondaryText)
                }
            } else {
                Button { downloadModel() } label: {
                    Label(localized: "Download model (~30 MB)", systemImage: "arrow.down.circle")
                }
                .controlSize(.small)
            }
            if let downloadError {
                Text(downloadError).font(.system(size: 11)).foregroundColor(theme.errorColor)
            }
            Text(
                "Runs entirely on this Mac — no cloud, no Apple Silicon required. Downloaded once.",
                bundle: .module
            )
            .font(.system(size: 11)).foregroundColor(theme.tertiaryText)
        }
    }

    private var cloudDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            field(
                "Endpoint", "https://api.openai.com/v1",
                Binding(
                    get: { config.cloudEmbeddingEndpoint ?? "" },
                    set: { v in mutate { $0.cloudEmbeddingEndpoint = v.isEmpty ? nil : v } }))
            field(
                "Model", "text-embedding-3-small",
                Binding(
                    get: { config.cloudEmbeddingModel ?? "" },
                    set: { v in mutate { $0.cloudEmbeddingModel = v.isEmpty ? nil : v } }))
            Text(
                "Uses a configured provider's API key for /v1/embeddings.", bundle: .module
            )
            .font(.system(size: 11)).foregroundColor(theme.tertiaryText)
        }
    }

    private var budgetCard: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        cardTitle("Memory budget")
                        Text("Max tokens of recalled context added per message.", bundle: .module)
                            .font(.system(size: 11)).foregroundColor(theme.secondaryText)
                    }
                    Spacer()
                    Stepper(
                        value: Binding(
                            get: { config.memoryBudgetTokens },
                            set: { v in mutate { $0.memoryBudgetTokens = v } }), in: 100...4000, step: 100
                    ) {
                        Text(verbatim: "\(config.memoryBudgetTokens)")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(theme.primaryText)
                    }
                    .fixedSize()
                }

                Divider().opacity(0.5)

                // Upstream places its manual "Run Now" trigger for
                // `MemoryConsolidator` directly beside the consolidation
                // interval stepper (`MemoryView.swift`'s `#if !OSAURUS_INTEL`
                // half, "Consolidation" row). Mirrored here: the interval
                // config already existed on `MemoryConfiguration`
                // (`consolidationIntervalHours`), it just had no UI and no
                // call site — `MemoryConsolidator.runNow()` only ever ran on
                // its internal schedule before this.
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        cardTitle("Consolidation")
                        Text(
                            "How often decay, dedup, promotion, and eviction run in the background.",
                            bundle: .module
                        )
                        .font(.system(size: 11)).foregroundColor(theme.secondaryText)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Stepper(
                            value: Binding(
                                get: { config.consolidationIntervalHours },
                                set: { v in mutate { $0.consolidationIntervalHours = v } }), in: 1...168
                        ) {
                            Text(
                                verbatim: "every \(pluralizedMemory(config.consolidationIntervalHours, "hour"))"
                            )
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(theme.primaryText)
                        }
                        .fixedSize()
                    }

                    if consolidationJustRan {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(theme.successColor)
                            .transition(.opacity)
                    }

                    Button {
                        runConsolidationNow()
                    } label: {
                        Text(isConsolidating ? "Running..." : "Run Now", bundle: .module)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.tertiaryBackground)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isConsolidating || !config.enabled)
                }

                Divider().opacity(0.5)

                // Episode-merge similarity threshold — user-configurable as of
                // 2026-09-07. It used to be the internal constant
                // `MemoryConfiguration.episodeMergeCosineThreshold` (0.9); a
                // Rosy test round found 0.9 too strict — near-duplicate
                // episodes survived consolidation. The consolidators now read
                // `config.episodeMergeCosineThreshold`; this is the control
                // that writes it. Default stays 0.9, so untouched installs
                // behave exactly as before.
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        cardTitle("Merge threshold")
                        Text(
                            "How similar two episode summaries must be before consolidation merges them. Drag left to merge more eagerly.",
                            bundle: .module
                        )
                        .font(.system(size: 11)).foregroundColor(theme.secondaryText)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Slider(
                            value: Binding(
                                get: { config.episodeMergeCosineThreshold },
                                set: { v in mutate { $0.episodeMergeCosineThreshold = v } }
                            ),
                            in: 0.50 ... 1.0,
                            step: 0.01
                        )
                        .frame(width: 140)
                        Text(String(format: "%.2f", config.episodeMergeCosineThreshold))
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(theme.primaryText)
                            .monospacedDigit()
                    }
                    .fixedSize()
                }
            }
        }
    }

    private var dangerCard: some View {
        card {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    cardTitle("Clear memory")
                    Text("Delete all stored conversation turns and embeddings.", bundle: .module)
                        .font(.system(size: 11)).foregroundColor(theme.secondaryText)
                }
                Spacer()
                Button(role: .destructive) { presentClearConfirmation() } label: {
                    Text("Clear", bundle: .module)
                }
                .controlSize(.small)
            }
        }
    }

    /// Per-agent opt-in for distillation.
    ///
    /// A deliberate divergence from upstream, which distills by default.
    /// Distillation is the ONE part of memory that leaves the machine:
    /// embedding and recall run on-device, but summarising a session into
    /// an episode sends its content to a remote provider. So it is off
    /// until asked for, per agent.
    ///
    /// The switches live here rather than buried in agent settings because
    /// a default-off feature with no visible control is indistinguishable
    /// from a broken one, and this fork has shipped several of those.
    private var distillationCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("Distillation")
                Text(
                    "Summarising a conversation into long-term memory sends its content to the model below. Embedding and recall stay on this Mac; only this step leaves it.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                if let model = distillModelName {
                    Text(verbatim: model)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText.opacity(0.9))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.primaryBackground.opacity(0.6)))
                } else if let unservable = distillModelConfiguredButUnservable {
                    // The user picked something real — say so plainly rather
                    // than silently falling through to "no model configured".
                    // Most common cause on this fork: the Core Model picker is
                    // the amputated MLX/local picker, so its value (an MLX
                    // repo id) can never be servable by a remote provider.
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(theme.warningColor)
                            Text(verbatim: unservable)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(theme.warningColor)
                        }
                        Text(
                            "That model isn't reachable by any connected provider, so distillation can't run. Pick a model a connected provider actually serves, or connect the provider that serves this one.",
                            bundle: .module
                        )
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText.opacity(0.8))
                    }
                } else {
                    Text(
                        "No model is configured, so nothing can be distilled yet.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText.opacity(0.8))
                }

                if !config.enabled {
                    Text(
                        "Memory is off, so distillation stays off regardless of these switches.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText.opacity(0.8))
                }

                Divider().opacity(0.4)

                ForEach(agentManager.agents) { agent in
                    HStack(spacing: 10) {
                        Text(verbatim: agent.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Spacer()
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { config.isDistillationEnabled(for: agent.id) },
                                set: { on in
                                    agentManager.updateDistillationEnabled(on, for: agent.id)
                                    // The writer persists through the store; re-read so
                                    // this view's copy matches disk instead of drifting.
                                    config = MemoryConfigurationStore.load()
                                }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!config.enabled)
                    }
                }
            }
        }
    }

    /// Refreshes `distillModelName` / `distillModelConfiguredButUnservable`
    /// by asking `MemoryService.resolveDistillModel()` directly — the same
    /// validated chain distillation itself uses — rather than re-deriving
    /// config lookups here. That used to be duplicated (an unvalidated
    /// `cfg.coreModelIdentifier ?? cfg.defaultModel` chain that could name a
    /// model the pipeline would actually reject), which is exactly how the
    /// panel and the pipeline disagreed. `unresolvedConfiguredModel()` only
    /// runs after a nil result, purely to name what was rejected — it does
    /// not re-validate anything.
    private func reloadDistillModelStatus() {
        Task {
            let resolved = await MemoryService.shared.resolveDistillModel()
            let unservable =
                resolved == nil
                ? await MemoryService.shared.unresolvedConfiguredModel()
                : nil
            await MainActor.run {
                distillModelName = resolved
                distillModelConfiguredButUnservable = unservable
            }
        }
    }

    // MARK: - Danger Zone Confirmation

    private func presentClearConfirmation() {
        let requestId = UUID()
        let scope = alertScope
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: L("Clear All Memory?"),
                message: L(
                    "This will permanently delete all stored conversation turns and embeddings. This cannot be undone."
                ),
                buttons: [
                    .cancel(L("Cancel")),
                    .destructive(L("Clear")) {
                        clearMemory()
                    },
                ],
                onDismiss: { ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId) }
            ),
            scope: scope
        )
    }

    // MARK: - Helpers

    @ViewBuilder private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View
    {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.secondaryBackground.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.primaryBorder.opacity(0.15), lineWidth: 1)
            )
    }

    private func cardTitle(_ key: String.LocalizationValue) -> some View {
        Text(String(localized: key, bundle: .module))
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(theme.primaryText)
    }

    private func field(_ label: String.LocalizationValue, _ placeholder: String, _ text: Binding<String>)
        -> some View
    {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: label, bundle: .module))
                .font(.system(size: 11, weight: .medium)).foregroundColor(theme.secondaryText)
            TextField("", text: text, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
        }
    }

    private func mutate(_ change: (inout MemoryConfiguration) -> Void) {
        var c = config
        change(&c)
        config = c.validated()
        MemoryConfigurationStore.save(config)
    }

    private func reload() {
        config = MemoryConfigurationStore.load()
        modelReady = StaticEmbeddingModel.isAvailable
        let db = MemoryDatabase.shared
        stats = db.isOpen ? ((try? db.processingStats()) ?? ProcessingStats()) : ProcessingStats()
        dbSizeBytes = db.databaseSizeBytes()
    }

    private func downloadModel() {
        isDownloading = true
        downloadError = nil
        Task {
            do {
                try await EmbeddingClient.shared.downloadStaticModel()
                await MainActor.run { modelReady = true }
            } catch {
                await MainActor.run { downloadError = error.localizedDescription }
            }
            await MainActor.run { isDownloading = false }
        }
    }

    private func runConsolidationNow() {
        guard !isConsolidating else { return }
        isConsolidating = true
        consolidationJustRan = false
        Task {
            await MemoryConsolidator.shared.runNow()
            await MainActor.run {
                isConsolidating = false
                withAnimation(.easeInOut(duration: 0.2)) {
                    consolidationJustRan = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        consolidationJustRan = false
                    }
                }
            }
        }
    }

    private func clearMemory() {
        let db = MemoryDatabase.shared
        db.close()
        try? FileManager.default.removeItem(at: OsaurusPaths.memoryDatabaseFile())
        try? db.open()
    }
}
#endif
