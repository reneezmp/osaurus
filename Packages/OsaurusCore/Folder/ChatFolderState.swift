//
//  ChatFolderState.swift
//  OsaurusCore
//
//  Session-scoped working-folder state for the Intel build. The app is not
//  App-Sandboxed, so a standardized path is the durable authority; bookmark
//  data is retained only for backup compatibility with upstream.
//

#if OSAURUS_INTEL

import AppKit
import Foundation

@MainActor
public final class ChatFolderState: ObservableObject {
    @Published public private(set) var context: FolderContext?
    public private(set) var bookmark: Data?
    public private(set) var lastKnownPath: String?
    public var onFolderMutated: (() -> Void)?

    private var generation = 0
    public private(set) var pendingRestore: Task<FolderContext?, Never>?

    public init() {}

    public var hasActiveFolder: Bool { context != nil }
    public var rootPath: URL? { context?.rootPath }
    public var persistedBookmark: Data? { bookmark }
    public var persistedPath: String? {
        lastKnownPath ?? context?.rootPath.standardizedFileURL.path
    }

    @discardableResult
    public func selectFolder(from window: NSWindow? = nil) async -> FolderContext? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = L("Select Working Directory")
        panel.message = L("Choose a folder for the AI to work with")
        panel.prompt = L("Select")

        let response: NSApplication.ModalResponse
        if let window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return nil }
        return await setFolder(url)
    }

    @discardableResult
    public func setFolder(_ url: URL) async -> FolderContext? {
        generation += 1
        let claimed = generation
        let standardized = url.standardizedFileURL
        let built = await FolderContextService.shared.buildContext(from: standardized)
        guard generation == claimed else { return nil }
        bookmark = nil
        lastKnownPath = standardized.path
        FolderToolManager.shared.ensureFolderToolsRegistered()
        context = built
        onFolderMutated?()
        return built
    }

    public func clearFolder() {
        generation += 1
        pendingRestore?.cancel()
        pendingRestore = nil
        let hadFolder = context != nil || bookmark != nil || lastKnownPath != nil
        context = nil
        bookmark = nil
        lastKnownPath = nil
        if hadFolder { onFolderMutated?() }
    }

    public func refreshContext() async {
        guard let rootPath else { return }
        let claimed = generation
        let built = await FolderContextService.shared.buildContext(from: rootPath)
        guard generation == claimed else { return }
        context = built
    }

    public func restore(bookmark: Data?, path: String?) {
        generation += 1
        let claimed = generation
        self.bookmark = bookmark
        lastKnownPath = path
        context = nil
        pendingRestore = Task {
            await self.performPathRestore(path: path, generation: claimed)
        }
    }

    @discardableResult
    public func restoreAndWait(bookmark: Data?, path: String?) async -> FolderContext? {
        restore(bookmark: bookmark, path: path)
        return await pendingRestore?.value
    }

    public func contextWaitingForRestore() async -> FolderContext? {
        if let context { return context }
        return await pendingRestore?.value
    }

    private func performPathRestore(path: String?, generation claimed: Int) async -> FolderContext? {
        guard generation == claimed, let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            FileManager.default.isReadableFile(atPath: url.path)
        else {
            bookmark = nil
            return nil
        }
        let built = await FolderContextService.shared.buildContext(from: url)
        guard generation == claimed else { return nil }
        bookmark = nil
        lastKnownPath = url.path
        FolderToolManager.shared.ensureFolderToolsRegistered()
        context = built
        return built
    }
}

#endif
