//
//  MemoryNamespacesView.swift
//  osaurus
//
//  The Memory tab's Agents view: what each agent and each project has
//  actually accumulated, and a way to forget a namespace wholesale.
//
//  Mirrors upstream's Agents tab (AGENTS list + PROJECTS section). Upstream
//  additionally drills into a per-agent detail pane; on this fork those
//  panels are still placeholders, so the rows are counts plus a forget
//  control rather than navigation into an empty screen.
//
//  Memory has no project column: a project's rows live under the same
//  `agent_id` column keyed `project-<uuid>` (see `MemoryNamespace`). That is
//  why one delete path serves both lists.
//

#if OSAURUS_INTEL

    import SwiftUI

    struct MemoryAgentsTabContent: View {
        @ObservedObject private var themeManager = ThemeManager.shared
        private var theme: ThemeProtocol { themeManager.currentTheme }
        @ObservedObject private var agentManager = AgentManager.shared
        @ObservedObject private var projectManager = ProjectManager.shared
        @Environment(\.themedAlertScope) private var alertScope

        @State private var agentRows: [NamespaceRow] = []
        @State private var projectRows: [NamespaceRow] = []
        @State private var loadError: String?

        /// One namespace and how much it holds. `key` is what the database
        /// stores; `name` is resolved for display and falls back to the raw
        /// key so a namespace whose agent or project was deleted is still
        /// visible and still forgettable rather than becoming invisible junk.
        struct NamespaceRow: Identifiable {
            let key: String
            let name: String
            let count: Int
            var id: String { key }
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let loadError {
                        Text(verbatim: loadError)
                            .font(.system(size: 12))
                            .foregroundColor(theme.errorColor)
                    }
                    section(
                        title: "Agents",
                        subtitle: "What each agent has remembered on its own.",
                        rows: agentRows,
                        emptyText: "No agent has stored anything yet."
                    )
                    section(
                        title: "Projects",
                        subtitle: "Shared by every chat in the project.",
                        rows: projectRows,
                        emptyText: "No project has stored anything yet."
                    )
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.primaryBackground)
            .onAppear { reload() }
        }

        // MARK: - Sections

        private func section(
            title: String.LocalizationValue,
            subtitle: String.LocalizationValue,
            rows: [NamespaceRow],
            emptyText: String.LocalizationValue
        ) -> some View {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: String(localized: title, bundle: .module))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(verbatim: String(localized: subtitle, bundle: .module))
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)

                    if rows.isEmpty {
                        Text(verbatim: String(localized: emptyText, bundle: .module))
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText.opacity(0.8))
                            .padding(.vertical, 8)
                    } else {
                        ForEach(rows) { row in
                            Divider().opacity(0.35)
                            namespaceRow(row)
                        }
                    }
                }
            }
        }

        private func namespaceRow(_ row: NamespaceRow) -> some View {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                Text(verbatim: row.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Spacer()
                Text(verbatim: "\(row.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.primaryBackground.opacity(0.6)))
                Button {
                    confirmForget(row)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .localizedHelp("Forget this memory")
            }
            .padding(.vertical, 4)
        }

        // MARK: - Actions

        /// Forgetting a namespace deletes rows permanently, so it confirms
        /// first and names what is going, matching the Danger Zone's shape.
        private func confirmForget(_ row: NamespaceRow) {
            let requestId = UUID()
            let scope = alertScope
            ThemedAlertCenter.shared.present(
                ThemedAlertRequest(
                    id: requestId,
                    title: L("Forget These Memories?"),
                    message: L(
                        "\(row.count) stored memories for \"\(row.name)\" will be deleted. Chats themselves are not affected."
                    ),
                    buttons: [
                        .cancel(L("Cancel")),
                        .destructive(L("Forget")) {
                            forget(row)
                        },
                    ],
                    onDismiss: { ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId) }
                ),
                scope: scope
            )
        }

        private func forget(_ row: NamespaceRow) {
            do {
                try MemoryDatabase.shared.deleteNamespaceData(agentId: row.key)
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
                let agents = try db.agentNamespaceCounts()
                let projects = try db.projectNamespaceCounts()
                agentRows = agents.map { entry in
                    NamespaceRow(
                        key: entry.agentId,
                        name: displayName(forAgentKey: entry.agentId),
                        count: entry.count
                    )
                }
                .sorted { $0.count > $1.count }
                projectRows = projects.map { entry in
                    NamespaceRow(
                        key: entry.namespaceKey,
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
        }

        private func displayName(forAgentKey key: String) -> String {
            guard let id = UUID(uuidString: key),
                let agent = agentManager.agents.first(where: { $0.id == id })
            else { return key }
            return agent.displayName
        }

        private func displayName(forProjectKey key: String) -> String {
            guard case .project(let id)? = MemoryNamespace(key: key),
                let project = projectManager.project(for: id)
            else { return key }
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
