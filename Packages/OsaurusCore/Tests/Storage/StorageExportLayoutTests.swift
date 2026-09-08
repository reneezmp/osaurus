//
//  StorageExportLayoutTests.swift
//  OsaurusCoreTests
//
//  The plaintext backup used to name every database by its bare filename
//  under `databases/`. Per-agent databases are all called `db.sqlite` and
//  every plugin database is called `data.db`, so with more than one agent or
//  plugin the export wrote them all to the same path and silently kept only
//  the last one. The layout now mirrors the path relative to `~/.osaurus`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("StorageExport layout")
struct StorageExportLayoutTests {

    private let root = URL(fileURLWithPath: "/Users/test/.osaurus")
    private let dest = URL(fileURLWithPath: "/Volumes/Backup/osaurus-backup")

    private func exportPath(_ relative: String) -> String {
        StorageExportService.databaseExportURL(
            for: root.appendingPathComponent(relative).path, root: root, destination: dest
        ).path
    }

    @Test
    func perAgentDatabasesNoLongerCollide() {
        let a = exportPath("agents/1B4E28BA-2FA1-11D2-883F-0016D3CCA427/db.sqlite")
        let b = exportPath("agents/6BA7B810-9DAD-11D1-80B4-00C04FD430C8/db.sqlite")
        #expect(a != b)
        #expect(a.hasSuffix("agents/1B4E28BA-2FA1-11D2-883F-0016D3CCA427/db.sqlite.plaintext"))
    }

    @Test
    func pluginDatabasesNoLongerCollide() {
        let a = exportPath("Tools/com.example.alpha/data/data.db")
        let b = exportPath("Tools/com.example.beta/data/data.db")
        #expect(a != b)
    }

    @Test
    func topLevelDatabasesKeepTheirFlatName() {
        #expect(exportPath("chat-history/history.sqlite")
            .hasSuffix("databases/chat-history/history.sqlite.plaintext"))
    }

    @Test
    func everythingLandsUnderTheDatabasesSubdirectory() {
        #expect(exportPath("agents/x/db.sqlite").hasPrefix(dest.appendingPathComponent("databases").path))
    }

    // MARK: - Database/artifact split

    @Test
    func databaseFilesAndTheirSidecarsAreLeftToTheDatabaseExporter() {
        for name in ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm",
                     "db.sqlite", "data.db", "data.db-wal", "history.sqlite-journal"] {
            #expect(StorageExportService.isDatabaseArtifact(URL(fileURLWithPath: "/x/\(name)")), "\(name)")
        }
    }

    @Test
    func ordinaryArtifactsAreNotTreatedAsDatabases() {
        for name in ["agent.json", "theme.json", "notes.md", "sqlite.json", "db.json", "avatar.png"] {
            #expect(!StorageExportService.isDatabaseArtifact(URL(fileURLWithPath: "/x/\(name)")), "\(name)")
        }
    }

    @Test
    func aPathOutsideTheRootFallsBackToItsFilename() {
        let outside = StorageExportService.databaseExportURL(
            for: "/somewhere/else/stray.sqlite", root: root, destination: dest)
        #expect(outside.path == dest.appendingPathComponent("databases/stray.sqlite.plaintext").path)
    }
}
