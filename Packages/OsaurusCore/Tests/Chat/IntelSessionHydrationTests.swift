import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel reopened-session hydration")
@MainActor
struct IntelSessionHydrationTests {
    @Test func metadataRowResolvesToStoredTranscript() {
        let id = UUID()
        let agentID = UUID()
        let turn = ChatTurnData(
            id: UUID(), role: .user, content: "keep me", createdAt: Date())
        let stored = ChatSessionData(id: id, turns: [turn], agentId: agentID)
        let metadata = ChatSessionData(id: id, turns: [], agentId: agentID)

        let resolved = ChatWindowState.resolvedSessionData(metadata, stored: stored)
        #expect(resolved.turns == [turn])
    }

    @Test func populatedCandidateDoesNotGetReplaced() {
        let id = UUID()
        let agentID = UUID()
        let current = ChatTurnData(
            id: UUID(), role: .user, content: "current", createdAt: Date())
        let stale = ChatTurnData(
            id: UUID(), role: .user, content: "stale", createdAt: Date())

        let resolved = ChatWindowState.resolvedSessionData(
            ChatSessionData(id: id, turns: [current], agentId: agentID),
            stored: ChatSessionData(id: id, turns: [stale], agentId: agentID)
        )
        #expect(resolved.turns == [current])
    }

    @Test func loadingStoredSessionAdoptsItsAgentInWindowHeader() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-session-hydration-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            AgentManager.shared.refresh()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                try? FileManager.default.removeItem(at: root)
            }

            let agent = Agent(
                name: "Hydration agent",
                systemPrompt: "Keep the restored header honest.",
                agentAddress: "test-hydration-\(UUID().uuidString)"
            )
            AgentManager.shared.add(agent)

            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            let session = ChatSessionData(
                id: UUID(),
                title: "Stored under another agent",
                turns: [ChatTurnData(
                    id: UUID(), role: .user, content: "Hello", createdAt: Date()
                )],
                agentId: agent.id
            )

            window.loadSession(session)

            #expect(window.agentId == agent.id)
            #expect(window.cachedActiveAgent.id == agent.id)
            #expect(window.cachedAgentDisplayName == agent.name)
            #expect(window.session.agentId == agent.id)
        }
    }
}
