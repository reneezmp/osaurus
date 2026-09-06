//
//  MemoryNamespacesView.swift
//  osaurus
//
//  The Memory tab's Agents view: what each agent and each project has
//  actually accumulated, and a way to forget a namespace wholesale.
//
//  Mirrors upstream's Agents tab: a Default-agent summary row (subtitle +
//  memory pill + eye preview + "Browse in Memories", no drill-in — upstream
//  never lets you open the Default agent's detail pane from here either),
//  then one `MemoryAgentRow` per custom agent that actually has memory
//  (dot + description + pill + eye + chevron), then a Projects section of
//  `MemoryProjectRow`s (folder + subtitle + pill + eye + trash). Both row
//  types and the shared preview helper live in `MemoryComponents.swift`.
//
//  Memory has no project column: a project's rows live under the same
//  `agent_id` column keyed `project-<uuid>` (see `MemoryNamespace`). That is
//  why one delete path serves both lists, and why the same
//  `memoryPreview(forNamespaceKey:)` helper previews both an agent and a
//  project row.
//
//  Drill-in: `AgentDetailView` (`Views/Agent/AgentsView.swift`) is a real,
//  live destination on this fork (not excluded, not gated behind anything
//  amputated — it already compiles and is reachable from the actual Agents
//  management tab). Upstream replaces its whole Memory tab body with it
//  inline; here it's presented as a sheet instead, so this file doesn't
//  have to lift `selectedAgent` state into `MemoryView.swift` (which I also
//  own, but a full inline swap would mean restructuring its body and
//  threading onDelete/onSwitchAgent reload semantics through a second
//  file). The destination is real either way — this is a presentation
//  simplification, not a stub.
//

#if OSAURUS_INTEL

    import SwiftUI

    struct MemoryAgentsTabContent: View {
        @ObservedObject private var themeManager = ThemeManager.shared
        private var theme: ThemeProtocol { themeManager.currentTheme }
        @ObservedObject private var agentManager = AgentManager.shared
        @ObservedObject private var projectManager = ProjectManager.shared
        @Environment(\.themedAlertScope) private var alertScope

        /// Reported upward so the Memory tab's header badge
        /// ("Agents (n)") can count every row this tab actually shows —
        /// see `MemoryView.swift`'s `HeaderTabsRow` call.
        var onRowCountChanged: ((Int) -> Void)? = nil

        @State private var defaultAgentCount: Int = 0
        @State private var agentRows: [(agent: Agent, count: Int)] = []
        @State private var projectRows: [ProjectRow] = []
        @State private var loadError: String?
        @State private var contextPreviewItem: ContextPreviewItem?
        @State private var detailAgent: Agent?

        /// One shared-project namespace and how much it holds. `name` is
        /// nil for an orphan (project deleted but its purge never
        /// completed) so the row can offer cleanup instead of hiding rows
        /// the user can't otherwise account for — same shape as upstream's
        /// `projectMemoryCounts`.
        struct ProjectRow: Identifiable {
            let namespaceKey: String
            let name: String?
            let count: Int
            var id: String { namespaceKey }
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let loadError {
                        Text(verbatim: loadError)
                            .font(.system(size: 12))
                            .foregroundColor(theme.errorColor)
                    }
                    agentsSection
                    if !projectRows.isEmpty {
                        projectsSection
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.primaryBackground)
            .onAppear { reload() }
            .sheet(item: $contextPreviewItem) { item in
                ContextPreviewSheet(context: item.text)
                    .frame(minWidth: 560, minHeight: 420)
            }
            .sheet(item: $detailAgent) { agent in
                AgentDetailView(
                    agent: agent,
                    onBack: { detailAgent = nil },
                    onDelete: { _ in
                        detailAgent = nil
                        reload()
                    },
                    onSwitchAgent: { newAgent in
                        detailAgent = newAgent
                    },
                    showSuccess: { message in
                        ToastManager.shared.success(message)
                    }
                )
                .frame(minWidth: 720, minHeight: 600)
            }
        }

        // MARK: - Agents Section

        private var agentsSection: some View {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Agents", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text("What each agent has remembered on its own.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)

                    Divider().opacity(0.35)
                    defaultAgentSummaryRow

                    if !agentRows.isEmpty {
                        ForEach(Array(agentRows.enumerated()), id: \.element.agent.id) { index, pair in
                            Divider().opacity(0.35)
                            MemoryAgentRow(
                                agent: pair.agent,
                                count: pair.count,
                                onSelect: { detailAgent = pair.agent },
                                onPreviewContext: { presentPreview(forKey: pair.agent.id.uuidString) }
                            )
                        }
                    }
                }
            }
        }

        /// Compact, always-shown Default-agent row. No chevron/onSelect —
        /// upstream never lets you drill into the Default agent's detail
        /// pane from the Memory tab either (`AgentDetailView`'s own editing
        /// surface is reached through Settings, not here).
        private var defaultAgentSummaryRow: some View {
            let defaultAgent = agentManager.agents.first(where: { $0.id == Agent.defaultId }) ?? Agent.default
            return HStack(spacing: 10) {
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(defaultAgent.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Text("Uses your global memory settings", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }

                Spacer()

                if defaultAgentCount > 0 {
                    Text(pluralizedMemory(defaultAgentCount, "memory", "memories"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(theme.tertiaryBackground))
                }

                Button {
                    presentPreview(forKey: Agent.defaultId.uuidString)
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground))
                }
                .buttonStyle(PlainButtonStyle())
                .localizedHelp("Preview memory context")

                Button {
                    ManagementStateManager.shared.memorySubTabRequest = MemoryTab.memories.rawValue
                } label: {
                    HStack(spacing: 5) {
                        // Upstream uses `rectangle.and.text.magnifyingglass`
                        // here — flagged in docs/MEMORY_PLAN.md §4 as the
                        // highest blank-render risk on macOS 13 (right at
                        // the cutoff). Substituted with `magnifyingglass`,
                        // confirmed live/ungated elsewhere in this fork's
                        // Views/ tree (e.g. `Views/Skill/SkillsView.swift`).
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10, weight: .medium))
                        Text("Browse in Memories", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground))
                }
                .buttonStyle(PlainButtonStyle())
                .localizedHelp("Browse the default agent's memories")
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
        }

        // MARK: - Projects Section

        private var projectsSection: some View {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Projects", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Shared by every chat in the project.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)

                    ForEach(projectRows) { row in
                        Divider().opacity(0.35)
                        MemoryProjectRow(
                            name: row.name,
                            count: row.count,
                            onPreviewContext: { presentPreview(forKey: row.namespaceKey) },
                            onForget: { confirmForget(key: row.namespaceKey, label: row.name ?? row.namespaceKey, count: row.count) }
                        )
                    }
                }
            }
        }

        // MARK: - Actions

        private func presentPreview(forKey key: String) {
            Task.detached {
                let text = memoryPreview(forNamespaceKey: key)
                await MainActor.run { contextPreviewItem = ContextPreviewItem(text: text) }
            }
        }

        /// Forgetting a namespace deletes rows permanently, so it confirms
        /// first and names what is going, matching the Danger Zone's shape.
        private func confirmForget(key: String, label: String, count: Int) {
            let requestId = UUID()
            let scope = alertScope
            ThemedAlertCenter.shared.present(
                ThemedAlertRequest(
                    id: requestId,
                    title: L("Forget These Memories?"),
                    message: L(
                        "\(count) stored memories for \"\(label)\" will be deleted. Chats themselves are not affected."
                    ),
                    buttons: [
                        .cancel(L("Cancel")),
                        .destructive(L("Forget")) {
                            forget(key: key)
                        },
                    ],
                    onDismiss: { ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId) }
                ),
                scope: scope
            )
        }

        private func forget(key: String) {
            do {
                try MemoryDatabase.shared.deleteNamespaceData(agentId: key)
                // Embeddings are BLOB columns on the same rows, so deleting
                // the rows is the whole purge — there is no separate vector
                // store to clean up on this build.
                loadError = nil
            } catch {
                loadError = String(
                    localized: "Could not forget those memories: \(error.localizedDescription)",
                    bundle: .module
                )
            }
            reload()
        }

        private func reload() {
            let db = MemoryDatabase.shared
            do {
                let agentEntries = try db.agentNamespaceCounts()
                let countsByAgentId = Dictionary(uniqueKeysWithValues: agentEntries)

                defaultAgentCount = countsByAgentId[Agent.defaultId.uuidString] ?? 0

                let lookup = Dictionary(
                    agentManager.agents.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                agentRows = agentEntries.compactMap { entry -> (agent: Agent, count: Int)? in
                    guard let uuid = UUID(uuidString: entry.agentId),
                        uuid != Agent.defaultId,
                        let agent = lookup[uuid]
                    else { return nil }
                    return (agent: agent, count: entry.count)
                }
                .sorted { $0.count > $1.count }

                let projectEntries = try db.projectNamespaceCounts()
                projectRows = projectEntries.map { entry in
                    ProjectRow(
                        namespaceKey: entry.namespaceKey,
                        name: displayName(forProjectKey: entry.namespaceKey),
                        count: entry.count
                    )
                }
                .sorted { $0.count > $1.count }

                loadError = nil
            } catch {
                loadError = String(
                    localized: "Could not read memory namespaces: \(error.localizedDescription)",
                    bundle: .module
                )
            }
            onRowCountChanged?(agentRows.count + projectRows.count)
        }

        private func displayName(forProjectKey key: String) -> String? {
            guard case .project(let id)? = MemoryNamespace(key: key),
                let project = projectManager.project(for: id)
            else { return nil }
            return project.name
        }

        // MARK: - Helpers

        @ViewBuilder private func card<Content: View>(@ViewBuilder _ content: () -> Content)
            -> some View
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
    }

#endif
