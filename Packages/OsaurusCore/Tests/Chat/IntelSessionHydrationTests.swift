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
}
