#if !OSAURUS_INTEL
//
//  MemoryDiagnosticsViews.swift
//  osaurus
//
//  All view-builders + helpers used by the Memory > Diagnostics card.
//  Moved out of `MemoryView.swift` so the parent file stays focused on
//  identity / agents / configuration / data-loading concerns. The
//  `@State` variables that drive these views still live on `MemoryView`
//  itself — this file is purely presentation + lightweight orchestration.
//
//  Layout:
//   * `diagnosticsSection`           — card + alert wiring
//   * Backfill banners + `runBackfill`
//   * Probe banner + `runBufferProbe`
//   * Pipeline-state group + headline
//   * Per-agent memory list
//   * Recent processing log list
//   * Shared `diagnosticBanner` + `diagnosticRow` chrome
//

import SwiftUI

extension MemoryView {
    // MARK: - Section

    /// Surfaces the actual write-pipeline state. The fastest way to
    /// localise "memory not building" to one of:
    ///   * `bufferTurn` never called      → pending = 0, log empty
    ///   * buffered but never distilled   → pending > 0, log empty
    ///   * distill running but skipping   → log full of "skipped" rows
    ///   * distill calling an unhealthy model → log full of "error" rows
    var diagnosticsSection: some View {
        MemorySectionCard(title: "Diagnostics", icon: "stethoscope") {
            MemorySectionActionButton(
                backfillButtonTitle,
                icon: "tray.and.arrow.down"
            ) {
                showBackfillConfirm = true
            }
            .disabled(backfillRunning || !config.enabled)

            MemorySectionActionButton(
                probeBufferRunning ? "Probing..." : "Test buffer",
                icon: "syringe"
            ) {
                runBufferProbe()
            }
            .disabled(probeBufferRunning)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    diagnosticsExpanded.toggle()
                }
            } label: {
                Image(systemName: diagnosticsExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.tertiaryBackground))
            }
            .buttonStyle(PlainButtonStyle())
        } content: {
            if diagnosticsExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    pipelineStateGroup
                    if backfillRunning {
                        backfillProgressBanner
                    } else if let backfillSummary {
                        backfillSummaryBanner(backfillSummary)
                    }
                    if let probeBufferResult {
                        bufferProbeResultBanner(probeBufferResult)
                    }
                    Divider().opacity(0.5)
                    perAgentMemoryGroup
                    Divider().opacity(0.5)
                    recentProcessingLogGroup
                }
            } else {
                pipelineStateOneLiner
            }
        }
        .themedAlert(
            L("Backfill chat history?"),
            isPresented: $showBackfillConfirm,
            message:
                L(
                    "This walks every chat session in your history, buffers their turns into pending_signals, then runs distillation. It can take a while if you have hundreds of sessions — each one is a single LLM call against your core model. Already-distilled sessions are skipped."
                ),
            primaryButton: .primary(L("Start backfill")) { runBackfill() },
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    // MARK: - Backfill

    var backfillButtonTitle: String {
        guard backfillRunning else { return "Backfill history" }
        switch backfillProgress.stage {
        case .buffering: return "Buffering..."
        case .distilling: return "Distilling..."
        case .done, .cancelled: return "Backfilling..."
        }
    }

    var backfillProgressBanner: some View {
        let p = backfillProgress
        let stageText: String
        switch p.stage {
        case .buffering:
            stageText =
                "Buffering session \(p.sessionsProcessed + p.sessionsSkipped)/\(p.sessionsTotal)"
        case .distilling:
            stageText =
                "Distilling \(p.sessionsProcessed) buffered session\(p.sessionsProcessed == 1 ? "" : "s")..."
        case .done, .cancelled:
            stageText = "Wrapping up..."
        }
        return HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text(stageText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                if let title = p.lastSessionTitle, !title.isEmpty {
                    Text(localized: "Last: \(title)")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
                Text(
                    "buffered \(p.turnsBuffered) turn\(p.turnsBuffered == 1 ? "" : "s") · skipped \(p.sessionsSkipped) session\(p.sessionsSkipped == 1 ? "" : "s")"
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            }
            Spacer()
            Button {
                backfillTask?.cancel()
            } label: {
                Text("Cancel", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.errorColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.errorColor.opacity(0.12)))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.accentColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.accentColor.opacity(0.25), lineWidth: 1)
                )
        )
    }

    func backfillSummaryBanner(_ message: String) -> some View {
        diagnosticBanner(
            icon: "checkmark.circle.fill",
            iconColor: .green,
            text: message,
            monospaced: false,
            onDismiss: { backfillSummary = nil }
        )
    }

    func runBackfill() {
        guard !backfillRunning else { return }
        backfillRunning = true
        backfillSummary = nil
        backfillProgress = MemoryBackfillProgress()
        backfillTask = Task.detached {
            let final = await MemoryService.shared.backfillFromChatHistory(
                distillAfterBuffering: true
            ) { snapshot in
                backfillProgress = snapshot
            }
            await MainActor.run {
                backfillSummary = Self.summarize(backfill: final)
                backfillRunning = false
                loadData()
            }
        }
    }

    private static func summarize(backfill final: MemoryBackfillProgress) -> String {
        switch final.stage {
        case .cancelled:
            return
                "Backfill cancelled after \(final.sessionsProcessed) session(s) — \(final.turnsBuffered) turns buffered. Run 'Distill pending' to drain them."
        default:
            return
                "Backfill complete: \(final.sessionsProcessed) session(s) buffered (\(final.turnsBuffered) turns), \(final.sessionsSkipped) skipped. Distillation finished."
        }
    }

    // MARK: - Probe

    func bufferProbeResultBanner(_ outcome: BufferProbeOutcome) -> some View {
        diagnosticBanner(
            icon: outcome.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            iconColor: outcome.isSuccess ? .green : .orange,
            text: outcome.displayText,
            monospaced: true,
            onDismiss: { probeBufferResult = nil }
        )
    }

    func runBufferProbe() {
        guard !probeBufferRunning else { return }
        probeBufferRunning = true
        probeBufferResult = nil
        Task.detached {
            let outcome = await MemoryDiagnostics.runBufferProbe()
            await MainActor.run {
                probeBufferResult = outcome
                probeBufferRunning = false
                loadData()
            }
        }
    }

    // MARK: - Pipeline state

    var pipelineStateOneLiner: some View {
        let summary = diagnosticHeadline()
        return HStack(spacing: 8) {
            Circle()
                .fill(summary.color)
                .frame(width: 8, height: 8)
            Text(summary.text)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
    }

    var pipelineStateGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            diagnosticRow(
                label: "Memory enabled",
                value: config.enabled ? "yes" : "no",
                statusColor: config.enabled ? .green : .red
            )
            diagnosticRow(
                label: "Memory DB open",
                value: memoryDBOpen ? "yes" : "no",
                statusColor: memoryDBOpen ? .green : .red,
                detail: memoryDBOpen
                    ? nil
                    : "Memory database failed to open. Check Console for SQLCipher errors and the storage migration logs."
            )
            diagnosticRow(
                label: "Extraction mode",
                value: extractionModeDescription(config.extractionMode),
                statusColor: config.extractionMode == .sessionEnd ? .green : .orange,
                detail: config.extractionMode == .manual
                    ? "Manual mode never auto-distills. Use 'Distill pending' or set to sessionEnd."
                    : nil
            )
            diagnosticRow(
                label: "Core model",
                value: coreModelStatusText(coreModelStatus),
                statusColor: coreModelStatusColor(coreModelStatus),
                detail: coreModelStatusDetail(coreModelStatus)
            )
            diagnosticRow(
                label: "Pending signals",
                value:
                    L("\(pendingSignals.totalSignals) pending · \(pendingSignals.allTimeSignals) all-time"),
                statusColor: pendingSignalsStatusColor,
                detail: pendingSignalsStatusDetail
            )
            diagnosticRow(
                label: "Episodes",
                value: "\(totalEpisodes)",
                statusColor: totalEpisodes == 0 ? .red : .green
            )
            diagnosticRow(
                label: "Pinned facts",
                value: "\(totalPinned)",
                statusColor: totalPinned == 0 ? .gray : .green
            )
            // The two coordinators added in 2026-05 to make
            // distillation safe on heavy MLX core models. "Live chat"
            // shows whether ChatEngine has any in-flight generation;
            // "Distill queue" shows the DistillationCoordinator's
            // single-flight depth + whether a body is executing right
            // now. Together they explain "why is my distillation
            // pausing?" without the user needing to read logs.
            diagnosticRow(
                label: "Live chat",
                value: chatActive ? L("active") : L("idle"),
                statusColor: chatActive ? .orange : .green,
                detail: chatActive
                    ? "Background distillation is paused while a chat generation is streaming — they share GPU/unified memory."
                    : nil
            )
            diagnosticRow(
                label: "Distill queue",
                value: distillQueueValueText,
                statusColor: distillQueueStatusColor
            )
            bufferTelemetryRow
        }
    }

    private var distillQueueValueText: String {
        let q = distillSnapshot.queued
        let activeMarker = distillSnapshot.active ? L("running") : L("idle")
        if q == 0 { return L("0 queued · \(activeMarker)") }
        return L("\(q) queued · \(activeMarker)")
    }

    private var distillQueueStatusColor: Color {
        if distillSnapshot.active { return .blue }
        if distillSnapshot.queued > 0 { return .orange }
        return .gray
    }

    private var pendingSignalsStatusColor: Color {
        if pendingSignals.allTimeSignals == 0 { return .red }
        if pendingSignals.totalSignals == 0 { return .green }
        return .orange
    }

    private var pendingSignalsStatusDetail: String? {
        if pendingSignals.allTimeSignals == 0 {
            return
                "No turns have ever reached the database. The chat code never calls bufferTurn for this install — see Buffer Telemetry below."
        }
        if pendingSignals.totalSignals == 0 {
            return
                "All buffered turns have been distilled (or purged). The pipeline is healthy when episodes are growing."
        }
        return nil
    }

    private var bufferTelemetryRow: some View {
        let t = bufferTelemetry
        let valueText: String
        let detail: String?
        let color: Color
        if t.attempts == 0 {
            valueText = "0 attempts since launch"
            detail =
                "MemoryService.bufferTurn has not been invoked since the app started. The chat finalization path isn't reaching it — likely an upstream gate (per-agent disableMemory, hasContent=false, or a non-default chat path)."
            color = .red
        } else if t.insertSuccesses == 0 {
            let buckets = [
                t.earlyReturnsEmptyMessage > 0 ? "\(t.earlyReturnsEmptyMessage) empty msg" : nil,
                t.earlyReturnsDisabled > 0 ? "\(t.earlyReturnsDisabled) memory off" : nil,
                t.insertFailures > 0 ? "\(t.insertFailures) insert err" : nil,
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
            valueText = "\(t.attempts) attempts, 0 successes"
            detail =
                "bufferTurn ran but every call bailed (\(buckets.isEmpty ? "no breakdown" : buckets))."
                + (t.lastError.map { " Last error: \($0)" } ?? "")
            color = .orange
        } else {
            valueText = "\(t.insertSuccesses)/\(t.attempts) successful"
            detail = nil
            color = .green
        }
        return diagnosticRow(
            label: "Buffer telemetry (this run)",
            value: valueText,
            statusColor: color,
            detail: detail
        )
    }

    // MARK: - Per-agent memory

    var perAgentMemoryGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PER-AGENT MEMORY", bundle: .module)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(theme.tertiaryText)
                .tracking(0.4)
            ForEach(agentManager.agents, id: \.id) { agent in
                perAgentMemoryRow(agent)
            }
        }
    }

    private func perAgentMemoryRow(_ agent: Agent) -> some View {
        let globalDisabled = !config.enabled
        let perAgentDisabled = (agent.disableMemory ?? false)
        let isOff = globalDisabled || perAgentDisabled
        let stateText: String
        let stateColor: Color
        if globalDisabled {
            stateText = "off (global)"
            stateColor = .red
        } else if perAgentDisabled {
            stateText = "off (this agent)"
            stateColor = .orange
        } else {
            stateText = "on"
            stateColor = .green
        }
        let canEnableHere = perAgentDisabled && !agent.isBuiltIn
        return HStack(spacing: 10) {
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)
            Text(agent.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
            Spacer()
            Text(LocalizedStringKey(stateText), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(stateColor)
            if canEnableHere {
                Button {
                    enableMemory(for: agent)
                } label: {
                    Text("Enable", bundle: .module)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                }
                .buttonStyle(PlainButtonStyle())
            } else if globalDisabled, isOff {
                Text("toggle below", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .padding(.vertical, 2)
    }

    func enableMemory(for agent: Agent) {
        guard !agent.isBuiltIn else { return }
        var updated = agent
        updated.disableMemory = false
        agentManager.update(updated)
        showToast(L("Memory enabled for \(agent.displayName)"))
    }

    // MARK: - Recent processing log

    var recentProcessingLogGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RECENT PROCESSING LOG", bundle: .module)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
                    .tracking(0.4)
                Spacer()
                if !recentLogs.isEmpty {
                    Text("\(recentLogs.count) row\(recentLogs.count == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }
            }
            if recentLogs.isEmpty {
                Text(
                    "No processing log entries yet. If you've been chatting, the distill pipeline never reached the model.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .padding(.vertical, 6)
            } else {
                ForEach(recentLogs) { row in
                    processingLogRow(row)
                    if row.id != recentLogs.last?.id {
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    private func processingLogRow(_ row: ProcessingLogRow) -> some View {
        HStack(spacing: 8) {
            Text(processingLogStatusBadge(row.status))
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(processingLogStatusColor(row.status)))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.taskType)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    if let model = row.model, !model.isEmpty {
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                        Text(model)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                if let details = row.details, !details.isEmpty {
                    Text(details)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(MemoryView.formatRelativeDate(row.createdAt))
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                if let ms = row.durationMs, ms > 0 {
                    Text("\(ms)ms")
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Shared chrome

    /// Single shared banner (icon + text + dismiss "x" on a tertiary
    /// background). Used by the buffer-probe outcome AND the backfill
    /// summary; the only knobs are the icon, the icon tint, and whether
    /// to render the body in monospaced text (probe banner attaches a
    /// multi-line schema dump on `SQLITE_CONSTRAINT` failures).
    @ViewBuilder
    func diagnosticBanner(
        icon: String,
        iconColor: Color,
        text: String,
        monospaced: Bool,
        onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(iconColor)
            Text(text)
                .font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground)
        )
    }

    private func diagnosticRow(
        label: String,
        value: String,
        statusColor: Color,
        detail: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(LocalizedStringKey(label), bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Spacer()
                Text(value)
                    .font(.system(size: 12))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.leading, 17)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Status helpers

    private func extractionModeDescription(_ mode: MemoryExtractionMode) -> String {
        switch mode {
        case .sessionEnd: return L("session-end (default)")
        case .manual: return L("manual")
        }
    }

    private func coreModelStatusText(_ status: CoreModelStatus) -> String {
        switch status {
        case .unset: return L("unset")
        case .available(let modelId, _, _): return "\(modelId) (available)"
        case .unavailable(let modelId, _): return "\(modelId) (unavailable)"
        case .breakerOpen(let modelId, _): return "\(modelId ?? "unset") (breaker open)"
        }
    }

    private func coreModelStatusColor(_ status: CoreModelStatus) -> Color {
        switch status {
        case .available: return .green
        case .unset, .unavailable: return .red
        case .breakerOpen: return .orange
        }
    }

    private func coreModelStatusDetail(_ status: CoreModelStatus) -> String? {
        switch status {
        case .unset:
            return L("Distillation is silently disabled. Pick a model in Settings → General.")
        case .unavailable(_, let reason):
            return reason
        case .breakerOpen(_, let until):
            let secs = max(1, Int(until.timeIntervalSinceNow))
            return "Cooling down for ~\(secs)s after consecutive failures. Next call will probe."
        case .available:
            return nil
        }
    }

    private func processingLogStatusBadge(_ status: String) -> String {
        switch status.lowercased() {
        case "success": return L("OK")
        case "error": return L("ERR")
        case "empty": return L("NIL")
        case "skipped": return L("SKP")
        default: return status.uppercased()
        }
    }

    private func processingLogStatusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "success": return .green
        case "error": return .red
        case "empty": return .orange
        case "skipped": return .gray
        default: return .blue
        }
    }

    // MARK: - Headline

    struct DiagnosticHeadline {
        let text: String
        let color: Color
    }

    func diagnosticHeadline() -> DiagnosticHeadline {
        if !config.enabled {
            return DiagnosticHeadline(text: L("Memory disabled globally."), color: .red)
        }
        if case .unavailable = coreModelStatus {
            return DiagnosticHeadline(text: L("Core model unavailable."), color: .red)
        }
        if case .unset = coreModelStatus {
            return DiagnosticHeadline(text: L("Core model not configured."), color: .red)
        }
        if pendingSignals.totalSignals == 0 && totalEpisodes == 0 {
            return DiagnosticHeadline(
                text: L("No buffered turns and no episodes — check per-agent memory."),
                color: .orange
            )
        }
        if pendingSignals.totalSignals > 0 && recentLogs.first?.status != "success" {
            return DiagnosticHeadline(
                text: L("\(pendingSignals.totalSignals) buffered turns waiting on distillation."),
                color: .orange
            )
        }
        return DiagnosticHeadline(text: L("Pipeline healthy."), color: .green)
    }
}
#else
//
//  MemoryDiagnosticsViews.swift (Intel)
//
//  Diagnostics tab content, bound to `MemoryDiagnostics.shared`
//  (`Models/Chat/IntelConformers/IntelMemoryDiagnostics.swift`). Ported from
//  the upstream half of this file above (`#if !OSAURUS_INTEL`): same card
//  grouping, banner/row chrome, phrasing, and status-color rules wherever
//  the data lines up 1:1 (pipeline status rows, per-agent breakdown,
//  recent processing log, headline banner).
//
//  Card grouping now mirrors upstream's three cards exactly: `Pipeline`
//  (headline + Status subsection + Activity subsection, in one card, not
//  two), `Per-Agent Memory`, `Recent Activity` — a prior pass here had
//  Activity as its own separate card and a five-block stat grid instead of
//  upstream's one-line-per-metric rows; both are fixed below.
//
//  Deliberately NOT ported, and why:
//   * Backfill / buffer-probe controls (upstream's Pipeline-card header
//     actions). `runBackfill()` calls `MemoryService.backfillFromChatHistory`
//     and `runBufferProbe()` calls a probe helper — neither has an Intel
//     equivalent, so the header below carries only Refresh.
//   * "Live chat" / "Distill queue" activity rows. Upstream sources these
//     from `InferenceLoadCoordinator.shared.chatActive` and
//     `DistillationCoordinator.shared.snapshot()` — the latter type is in
//     `Package.swift`'s `exclude:` list on this fork, and there is no
//     Intel mirror of either signal (no "is a chat generating right now"
//     nor "distill single-flight depth" telemetry exists here). Omitted
//     rather than faked.
//   * The rich `bufferTelemetryRow` bucket breakdown (empty-msg / disabled
//     / insert-failure counts). The §5 snapshot contract exposes exactly
//     one number for this, `bufferAttempts` — no per-bucket detail exists
//     to show, so the row below states the count and the zero-attempts
//     remediation text only.
//
//  The per-agent "Enable" button now IS wired (a prior pass here left it
//  unported, noting Phase 3 wasn't implemented yet — it has since landed):
//  `AgentManager.updateDistillationEnabled(_:for:)`
//  (`IntelManagerConformers.swift`) is live, and its own doc comment names
//  this exact card as the intended call site. The semantics differ from
//  upstream's `agent.memoryEnabled` (a per-agent recall on/off that
//  doesn't exist on this fork) — the honest Intel equivalent is
//  `MemoryConfiguration.isDistillationEnabled(for:)`, the Phase 3 opt-in
//  distillation gate (`docs/MEMORY_PLAN.md` §2b: opt-in, default OFF, a
//  deliberate divergence from upstream not to be corrected away). Row
//  state below is therefore "off (global)" / "off (this agent)" / "on"
//  against that gate, not against recall. Unlike upstream, Enable is
//  offered for the Default agent too — the opt-in store keys by UUID with
//  no built-in/custom distinction (see that method's doc comment).
//
//  Data source is a single `@Published snapshot: MemoryDiagnosticsSnapshot?`
//  refreshed on demand, rather than the dozen separate `@State` vars
//  upstream's monolithic `MemoryView` threads through `loadData()` — that
//  collapse is the point of the Phase 1 service boundary, not a taste
//  deviation from upstream's structure.
//
//  macOS 13: the per-agent Enable button changes local `@State`, not a
//  binding read by `onChange`, so there is still no two- vs
//  one-parameter `onChange` concern to resolve in this file.
//
//  SF Symbols, each verified live+ungated in this fork's `Views/` tree
//  (grep + `#if` boundary check, not just "it compiles somewhere"):
//   * `waveform.path.ecg` — upstream's own Pipeline-card icon. Confirmed
//     unconditional in `Views/Settings/ServerSettings/ServerSettingsSection.swift`
//     and `Views/Agent/AgentsView.swift` (neither file has an `#if` split).
//     Replaces this file's prior substitute (`waveform`) now that the
//     upstream icon itself checks out — no need to keep substituting.
//   * `person.fill` — kept from the prior pass (`Views/Identity/IdentityView.swift`,
//     unconditional) rather than upstream's own `person.2`, which
//     `docs/MEMORY_PLAN.md` §4 lists by name as unverified on this fork.
//   * `list.bullet.rectangle` — upstream's Recent-Activity icon. Confirmed
//     unconditional in `Views/Agent/AgentCapabilityManagerView.swift`.
//

import SwiftUI

// Internal (not `private`/`fileprivate`), unlike its sibling tab-content
// structs (`MemoryIdentityTabContent` etc.) which live inside
// `MemoryView.swift` itself and can afford `private`: this type is
// referenced from `MemoryView.swift`'s tab switch across a file boundary,
// so it needs at least `internal` visibility.
struct MemoryDiagnosticsTabContent: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }
    @ObservedObject private var diagnostics = MemoryDiagnostics.shared

    @State private var isRefreshing = false
    /// Backs the per-agent Enable button's instant re-render: mutating
    /// `MemoryConfigurationStore` (plain JSON-on-disk storage, not an
    /// `ObservableObject`) doesn't itself trigger a SwiftUI update, so the
    /// row's "off (this agent)" / "on" text re-reads from this cached copy
    /// rather than re-fetching on every body evaluation.
    @State private var memoryConfig = MemoryConfigurationStore.load()

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
                if let snapshot = diagnostics.snapshot {
                    pipelineCard(snapshot)
                    perAgentCard(snapshot)
                    recentLogCard(snapshot)
                } else {
                    loadingCard
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .onAppear { refresh() }
    }

    // MARK: - Loading

    private var loadingCard: some View {
        MemorySectionCard(title: "Diagnostics", icon: "waveform") {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading diagnostics...", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: - Pipeline card

    /// Mirrors upstream's `pipelineStateGroup` + headline: the fastest way
    /// to localise "memory not building" to one of bufferTurn never
    /// called / buffered-but-never-distilled / distilling-but-skipping /
    /// calling an unhealthy model.
    private func pipelineCard(_ s: MemoryDiagnosticsSnapshot) -> some View {
        MemorySectionCard(title: "Pipeline", icon: "waveform.path.ecg") {
            MemorySectionActionButton(isRefreshing ? "Refreshing..." : "Refresh", icon: "arrow.clockwise") {
                refresh()
            }
            .disabled(isRefreshing)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                headlineBanner(s)
                bufferAttemptsRow(s)

                Divider().opacity(0.4)

                diagnosticSubsection("Status") {
                    diagnosticRow(
                        label: "Memory enabled",
                        value: s.memoryEnabled ? L("yes") : L("no"),
                        statusColor: s.memoryEnabled ? .green : .red
                    )
                    diagnosticRow(
                        label: "Memory DB open",
                        value: s.databaseOpen ? L("yes") : L("no"),
                        statusColor: s.databaseOpen ? .green : .red,
                        detail: s.databaseOpen
                            ? nil
                            : L(
                                "Memory database failed to open. Check Console for SQLCipher errors and the storage migration logs."
                            )
                    )
                    diagnosticRow(
                        label: "Extraction mode",
                        value: extractionModeDescription(s.extractionMode),
                        statusColor: s.extractionMode == "sessionEnd" ? .green : .orange,
                        detail: extractionModeDetail(s.extractionMode)
                    )
                    diagnosticRow(
                        label: "Core model",
                        value: s.coreModel ?? L("unavailable"),
                        statusColor: s.coreModel == nil ? .red : .green,
                        detail: s.coreModelDetail
                    )
                }

                Divider().opacity(0.4)

                diagnosticSubsection("Activity") {
                    activityRows(s)
                }
            }
        }
    }

    private func diagnosticSubsection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(theme.tertiaryText)
                .tracking(0.4)
            content()
        }
    }

    private func headlineBanner(_ s: MemoryDiagnosticsSnapshot) -> some View {
        let h = headline(for: s)
        return HStack(spacing: 8) {
            Circle().fill(h.color).frame(width: 8, height: 8)
            Text(h.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.secondaryText)
        }
    }

    private func headline(for s: MemoryDiagnosticsSnapshot) -> (text: String, color: Color) {
        if !s.memoryEnabled {
            return (L("Memory disabled globally."), .red)
        }
        if !s.databaseOpen {
            return (L("Memory database is not open."), .red)
        }
        if s.coreModel == nil {
            return (L("Core model unavailable — distillation cannot run."), .red)
        }
        if s.bufferAttempts == 0 {
            return (L("bufferTurn has never been called — the chat path never reached the distiller."), .red)
        }
        if s.pendingSignals == 0 && s.episodeCount == 0 {
            return (L("No buffered turns and no episodes yet."), .orange)
        }
        if s.pendingSignals > 0 && s.distillOK == 0 {
            return (L("\(s.pendingSignals) buffered turns waiting on distillation."), .orange)
        }
        return (L("Pipeline healthy."), .green)
    }

    /// The single most diagnostic number in the panel per
    /// docs/MEMORY_PLAN.md §5: 0 means `MemoryService.bufferTurn` was
    /// never invoked this process — the chat finalization path never
    /// reached the distiller at all. Called out as its own row, not
    /// folded into the generic status list, so it can't be scrolled past.
    private func bufferAttemptsRow(_ s: MemoryDiagnosticsSnapshot) -> some View {
        let isZero = s.bufferAttempts == 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Circle().fill(isZero ? Color.red : Color.green).frame(width: 8, height: 8)
                Text("bufferTurn attempts (this run)", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Text("\(s.bufferAttempts)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(isZero ? theme.errorColor : theme.primaryText)
            }
            if isZero {
                Text(
                    "0 means the chat path never reached the distiller this run — check per-agent memory and the extraction mode above.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .padding(.leading, 18)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isZero ? theme.errorColor.opacity(0.08) : theme.tertiaryBackground)
        )
    }

    private func extractionModeDescription(_ mode: String) -> String {
        switch mode {
        case "sessionEnd": return L("session-end (default)")
        case "manual": return L("manual")
        default: return mode
        }
    }

    private func extractionModeDetail(_ mode: String) -> String? {
        guard mode == "manual" else { return nil }
        return L("Manual mode never auto-distills. Distillation only runs from an explicit trigger.")
    }

    // MARK: - Activity subsection (inside the Pipeline card)

    /// One line per metric, matching upstream's `activityRows` text and
    /// ordering exactly (`"N pending · N processed · N dead · N all-time"`,
    /// `"N ok · N skipped · N err · N empty · N dead"`) — a prior pass here
    /// laid the five distillation-result counts out as a stat-block grid
    /// instead; every number below comes straight off
    /// `MemoryDiagnosticsSnapshot`, no grid needed.
    @ViewBuilder
    private func activityRows(_ s: MemoryDiagnosticsSnapshot) -> some View {
        diagnosticRow(
            label: "Pending signals",
            value: L(
                "\(s.pendingSignals) pending · \(s.processedSignals) processed · \(s.deadSignals) dead · \(s.allTimeSignals) all-time"
            ),
            statusColor: pendingSignalsColor(s),
            detail: pendingSignalsDetail(s)
        )
        diagnosticRow(
            label: "Distillation results",
            value: L(
                "\(s.distillOK) ok · \(s.distillSkipped) skipped · \(s.distillErrors) err · \(s.distillEmpty) empty · \(s.distillDead) dead"
            ),
            statusColor: s.distillErrors > 0 || s.distillDead > 0
                ? .red : (s.distillOK > 0 ? .green : .gray)
        )
        diagnosticRow(
            label: "Episodes",
            value: "\(s.episodeCount)",
            statusColor: s.episodeCount == 0 ? .red : .green
        )
        diagnosticRow(
            label: "Pinned facts",
            value: "\(s.pinnedFactCount)",
            statusColor: s.pinnedFactCount == 0 ? .gray : .green
        )
        // "Live chat" / "Distill queue" omitted — see this file's header
        // comment (no `InferenceLoadCoordinator` / `DistillationCoordinator`
        // equivalent exists on Intel to back them honestly).
        diagnosticRow(
            label: "Database size",
            value: formatBytes(s.databaseBytes),
            statusColor: .gray
        )
    }

    private func pendingSignalsColor(_ s: MemoryDiagnosticsSnapshot) -> Color {
        if s.deadSignals > 0 { return .red }
        if s.allTimeSignals == 0 { return .red }
        if s.pendingSignals == 0 { return .green }
        return .orange
    }

    private func pendingSignalsDetail(_ s: MemoryDiagnosticsSnapshot) -> String? {
        if s.allTimeSignals == 0 {
            return L(
                "No turns have ever reached the database. See the bufferTurn attempts row above."
            )
        }
        if s.pendingSignals == 0 {
            return L("All buffered turns have been distilled (or purged).")
        }
        return nil
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Recent processing log

    private func recentLogCard(_ s: MemoryDiagnosticsSnapshot) -> some View {
        MemorySectionCard(
            title: "Recent Activity", icon: "list.bullet.rectangle",
            count: s.recentLog.isEmpty ? nil : s.recentLog.count
        ) {
            if s.recentLog.isEmpty {
                Text(
                    "No processing log entries yet. If you've been chatting, the distill pipeline never reached the model.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(s.recentLog) { row in
                        processingLogRow(row)
                        if row.id != s.recentLog.last?.id {
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
    }

    private func processingLogRow(_ row: MemoryProcessingLogEntry) -> some View {
        HStack(spacing: 8) {
            Text(processingLogStatusBadge(row.status))
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(processingLogStatusColor(row.status)))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.taskType)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    if let model = row.model, !model.isEmpty {
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                        Text(model)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                if let details = row.details, !details.isEmpty {
                    Text(details)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(Self.formatRelativeDate(row.createdAt))
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                if let ms = row.durationMs, ms > 0 {
                    Text("\(ms)ms")
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func processingLogStatusBadge(_ status: String) -> String {
        switch status.lowercased() {
        case "success": return L("OK")
        case "error": return L("ERR")
        case "empty": return L("NIL")
        case "skipped": return L("SKP")
        default: return status.uppercased()
        }
    }

    private func processingLogStatusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "success": return .green
        case "error": return .red
        case "empty": return .orange
        case "skipped": return .gray
        default: return .blue
        }
    }

    // MARK: - Per-agent breakdown

    private func perAgentCard(_ s: MemoryDiagnosticsSnapshot) -> some View {
        MemorySectionCard(
            title: "Per-Agent Memory", icon: "person.fill",
            count: s.perAgent.isEmpty ? nil : s.perAgent.count
        ) {
            if s.perAgent.isEmpty {
                Text("No agents found.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(s.perAgent) { agent in
                        perAgentRow(agent)
                        if agent.id != s.perAgent.last?.id {
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
    }

    /// Mirrors upstream's per-agent row: a status dot, the agent's name, and
    /// a trailing `on` / `off (this agent)` state with an Enable button.
    ///
    /// The state shown is DISTILLATION, not memory. Memory is a single global
    /// switch here, so a per-agent memory column would show the same value on
    /// every row and tell you nothing; distillation is the real per-agent,
    /// default-off axis, and it is what the button toggles. An orphaned
    /// namespace (memory rows whose agent no longer exists) reports `nil` and
    /// gets no button, since there is nothing live to turn on.
    private func perAgentRow(_ agent: MemoryAgentDiagnostic) -> some View {
        let isOn = agent.distillationEnabled ?? false
        return HStack(spacing: 10) {
            Circle()
                .fill(isOn ? Color.green : Color.orange.opacity(0.8))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.agentName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text(
                    verbatim:
                        "\(agent.episodeCount) ep · \(agent.pinnedFactCount) pinned · \(agent.pendingSignalCount) pending"
                )
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
            }
            Spacer()
            if agent.distillationEnabled == nil {
                Text("no live agent", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            } else if isOn {
                Text("on", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(.green)
            } else {
                Text("off (this agent)", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Button {
                    guard let id = UUID(uuidString: agent.agentId) else { return }
                    AgentManager.shared.updateDistillationEnabled(true, for: id)
                    Task { await MemoryDiagnostics.shared.refresh() }
                } label: {
                    Text("Enable", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(theme.accentColor.opacity(theme.isDark ? 0.18 : 0.12)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Shared row chrome

    private func diagnosticRow(
        label: String,
        value: String,
        statusColor: Color,
        detail: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(LocalizedStringKey(label), bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Spacer()
                Text(value)
                    .font(.system(size: 12))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.leading, 17)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Refresh

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await MemoryDiagnostics.shared.refresh()
            await MainActor.run { isRefreshing = false }
        }
    }
}
#endif
