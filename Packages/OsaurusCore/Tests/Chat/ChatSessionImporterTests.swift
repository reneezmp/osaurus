import Foundation
import Testing

@testable import OsaurusCore

@Suite("Chat session importer")
struct ChatSessionImporterTests {
    @Test func claudeExportIndexNamesTheBatchFiles() {
        let data = Data(
            """
            {
              "data_files": [
                {"export_url": "https://example.test/a?sig=1", "filename": "batch-0000.zip"},
                {"export_url": "https://example.test/batch-0001.zip?sig=2"}
              ]
            }
            """.utf8
        )

        #expect {
            _ = try ChatSessionImporter.parse(data: data)
        } throws: { error in
            guard case .claudeExportIndex(let files) = error as? ChatSessionImporter.ImportError
            else { return false }
            return files == ["batch-0000.zip", "batch-0001.zip"]
        }
    }

    @Test func claudeIndexIsReportedOnlyWhenNoBatchConversationImported() {
        #expect(ChatSessionImportCoordinator.shouldReportClaudeExportIndexes(
            importedConversationCount: 0
        ))
        #expect(!ChatSessionImportCoordinator.shouldReportClaudeExportIndexes(
            importedConversationCount: 1
        ))
    }
}
