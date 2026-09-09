//
//  FolderToolManager.swift
//  osaurus
//
//  Registers one rootless set of folder tools. Each execution resolves its
//  root from ChatExecutionContext.currentFolderRoot, so simultaneous chats
//  cannot overwrite one another's working directory.
//

import Foundation

@MainActor
public final class FolderToolManager {
    public static let shared = FolderToolManager()

    private var folderTools: [OsaurusTool] = []
    private var registeredNames: [String] = []

    private init() {}

    public var folderToolNames: [String] { registeredNames }
    public var hasFolderTools: Bool { !registeredNames.isEmpty }

    /// Installs the canonical rootless tools once. Availability is still
    /// filtered per request by the caller's FolderContext.
    public func ensureFolderToolsRegistered() {
        guard registeredNames.isEmpty else { return }
        folderTools = FolderToolFactory.buildCoreTools()
            + FolderToolFactory.buildGitTools()
        registeredNames = folderTools.map(\.name)
        for tool in folderTools {
            ToolRegistry.shared.register(tool)
        }
    }

    /// Compatibility entry point for legacy callers. The context belongs to
    /// the chat/session now, rather than to this process-wide registry.
    public func registerFolderTools(for context: FolderContext) {
        _ = context
        ensureFolderToolsRegistered()
    }

    /// Clearing one legacy/global context must not remove tools that another
    /// chat window may still be using.
    public func unregisterFolderTools() {
        if RuntimeEnvironment.isUnderTests {
            unregisterAllForTesting()
        }
    }

    private func unregisterAllForTesting() {
        guard !registeredNames.isEmpty else { return }
        ToolRegistry.shared.unregister(names: registeredNames)
        folderTools = []
        registeredNames = []
    }
}
