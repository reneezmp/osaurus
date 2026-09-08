import Foundation
import Testing

@testable import OsaurusCore

struct SystemPermissionProbeTests {
    static let testResources: [SystemPermissionProbe.FullDiskResource] = [
        .init(location: .home, path: "Library/Application Support/com.apple.TCC/TCC.db"),
        .init(location: .home, path: "Library/Messages/chat.db"),
    ]
    static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)

    @Test func defaultResourcesAnchorOnSystemTCCDatabase() {
        let system = SystemPermissionProbe.defaultFullDiskResources.first { $0.location == .system }
        #expect(system?.path == "/Library/Application Support/com.apple.TCC/TCC.db")
        #expect(!SystemPermissionProbe.defaultFullDiskResources.contains {
            $0.location == .home && $0.path.contains("com.apple.TCC")
        })
    }

    @Test func fullDiskAccessProbeDoesNotTreatReadableSafariDirectoryAsGrant() throws {
        let root = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library/Safari"), withIntermediateDirectories: true)
        #expect(!SystemPermissionProbe.fullDiskAccessGranted(homeDirectory: root, resources: Self.testResources))
    }

    @Test func fullDiskAccessProbeRequiresSQLiteHeader() throws {
        let root = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(Self.sqliteHeader, at: "Library/Application Support/com.apple.TCC/TCC.db", root: root)
        #expect(SystemPermissionProbe.fullDiskAccessGranted(homeDirectory: root, resources: Self.testResources))
    }

    @Test func fullDiskAccessProbeRejectsEmptyAndGarbageFiles() throws {
        let root = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(Data(), at: "Library/Application Support/com.apple.TCC/TCC.db", root: root)
        #expect(!SystemPermissionProbe.fullDiskAccessGranted(homeDirectory: root, resources: Self.testResources))
        try write(Data("garbage".utf8), at: "Library/Messages/chat.db", root: root)
        #expect(!SystemPermissionProbe.fullDiskAccessGranted(homeDirectory: root, resources: Self.testResources))
    }

    @Test func fullDiskAccessProbeReturnsFalseWhenProtectedFilesAreAbsent() throws {
        let root = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!SystemPermissionProbe.fullDiskAccessGranted(homeDirectory: root, resources: Self.testResources))
    }

    @Test func screenRecordingProbeUsesCoreGraphicsPreflightResult() {
        #expect(SystemPermissionProbe.screenRecordingGranted(preflight: { true }))
        #expect(!SystemPermissionProbe.screenRecordingGranted(preflight: { false }))
    }

    private func makeTemporaryHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("osaurus-permission-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ data: Data, at relative: String, root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
