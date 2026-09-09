import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel project workspace")
struct IntelProjectWorkspaceTests {
    @Test("older project files decode without workspace fields")
    func legacyProjectDecode() throws {
        let id = UUID()
        let data = Data(
            """
            {
              "id": "\(id.uuidString)",
              "name": "Rosy",
              "instructions": "Keep it local."
            }
            """.utf8)

        let project = try JSONDecoder().decode(Project.self, from: data)
        #expect(project.id == id)
        #expect(project.knowledgeCollectionIds.isEmpty)
        #expect(project.defaultAgentId == nil)
        #expect(project.folderBookmark == nil)
        #expect(project.folderPath == nil)
    }

    @Test("project and chat workspace paths round trip")
    func workspaceRoundTrip() throws {
        let folder = "/Users/renee/Documents/Meeting Notes"
        let project = Project(name: "Meetings", folderPath: folder)

        let encoder = JSONEncoder()
        let decodedProject = try JSONDecoder().decode(
            Project.self, from: encoder.encode(project))
        #expect(decodedProject.folderPath == folder)

        let session = ChatSessionData(
            title: "Cabinet",
            agentId: Agent.defaultId,
            folderPath: folder,
            projectId: project.id
        )
        let decodedSession = try JSONDecoder().decode(
            ChatSessionData.self, from: encoder.encode(session))
        #expect(decodedSession.folderPath == folder)
        #expect(decodedSession.projectId == project.id)
    }

    @Test("rootless folder tools stay isolated across concurrent chats")
    func concurrentWorkspaceIsolation() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            "osaurus-project-workspace-\(UUID().uuidString)", isDirectory: true)
        let first = base.appendingPathComponent("first", isDirectory: true)
        let second = base.appendingPathComponent("second", isDirectory: true)
        try fm.createDirectory(at: first, withIntermediateDirectories: true)
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("alpha-window".utf8).write(to: first.appendingPathComponent("note.txt"))
        try Data("beta-window".utf8).write(to: second.appendingPathComponent("note.txt"))
        defer { try? fm.removeItem(at: base) }

        let tool = FileReadTool()
        async let firstRead = ChatExecutionContext.$currentFolderRoot.withValue(first) {
            try await tool.execute(argumentsJSON: #"{"path":"note.txt"}"#)
        }
        async let secondRead = ChatExecutionContext.$currentFolderRoot.withValue(second) {
            try await tool.execute(argumentsJSON: #"{"path":"note.txt"}"#)
        }

        let (firstResult, secondResult) = try await (firstRead, secondRead)
        #expect(firstResult.contains("alpha-window"))
        #expect(!firstResult.contains("beta-window"))
        #expect(secondResult.contains("beta-window"))
        #expect(!secondResult.contains("alpha-window"))
    }

    @Test("folder tools appear only for the active folder and git state")
    func folderToolVisibility() {
        let registered: Set<String> = ["file_read", "git_status"]
        #expect(
            !SystemPromptComposer.folderToolIsVisible(
                "file_read", folder: nil, registeredFolderToolNames: registered))
        let folder = FolderContext(
            rootPath: URL(fileURLWithPath: "/tmp/plain-project"),
            projectType: .unknown,
            tree: "./",
            manifest: nil,
            gitStatus: nil,
            isGitRepo: false,
            contextFiles: nil
        )
        #expect(
            SystemPromptComposer.folderToolIsVisible(
                "file_read", folder: folder, registeredFolderToolNames: registered)
        )
        #expect(
            !SystemPromptComposer.folderToolIsVisible(
                "git_status", folder: folder, registeredFolderToolNames: registered))
        #expect(
            SystemPromptComposer.folderToolIsVisible(
                "search_knowledge", folder: nil, registeredFolderToolNames: registered))
    }
}
