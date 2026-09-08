//
//  osaurusApp.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//  Intel fork — minimal app entry point. M2 milestone.
//

import AppKit
import OsaurusCore
import SwiftUI

@main
struct osaurusApp: SwiftUI.App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    /// Chat settings toggle: ⌘N starts a new chat in the frontmost chat
    /// window instead of opening a new window (see `NewChatShortcutSetting`).
    /// Upstream e0eeba12.
    @AppStorage(NewChatShortcutSetting.defaultsKey)
    private var cmdNStartsNewChatInCurrentWindow: Bool = false
    /// Drives the View menu's zoom item enabled state (`canZoomFontIn` /
    /// `canZoomFontOut` / `isDefaultFontScale`). Upstream e0eeba12 pairs
    /// these with an existing "Theme" picker menu item that this fork's
    /// App target doesn't have; the zoom items stand alone in their own
    /// View menu here. Upstream 1b955c2b.
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some SwiftUI.Scene {
        // The SwiftUI `Settings { EmptyView() }` scene is kept as a
        // placeholder so SwiftUI doesn't synthesize its own default
        // Settings menu item. The real "Settings…" entry is provided
        // by `settingsCommand` below, which routes Cmd+, into
        // `AppDelegate.showManagementWindow()` — our hand-rolled
        // NSWindow hosting the real `ManagementView`. This was the
        // root cause of M11 Phase 11.0's empty-black-window
        // regression: Cmd+, was firing the SwiftUI Settings scene
        // (an `EmptyView`), and the window's title coincidentally
        // matched the one we set on the hand-rolled window, so we
        // spent three sub-phases "fixing" a window that was never
        // even being shown.
        Settings {
            EmptyView()
        }
        .commands {
            aboutCommand
            fileMenuCommands
            chatShortcutCommands
            viewMenuCommands
            settingsCommand
        }
    }
}

// MARK: - Menu Commands

private extension osaurusApp {

    var aboutCommand: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button {
                let shortVersion =
                    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                let versionLine =
                    OsaurusBuildInfo.upstreamShortLabel.map { "\(shortVersion) · \($0)" } ?? shortVersion
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationName: "Osaurus (Intel)",
                    .applicationVersion: versionLine,
                    .version: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
                ])
            } label: {
                Text(verbatim: "About Osaurus (Intel)")
            }
        }
    }

    /// ⌘N: opens a new chat window by default (matching the historical
    /// behavior — there was no File-menu "New Window" command to replace
    /// here before this port). When the Chat setting is on, ⌘N instead
    /// starts a new chat in the frontmost chat window (the sidebar "New
    /// Chat" action), and gains a second ⇧⌘N item for opening a genuinely
    /// new window — matching most chat apps. Upstream e0eeba12.
    var fileMenuCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            if cmdNStartsNewChatInCurrentWindow {
                Button {
                    Task { @MainActor in
                        if !ChatWindowManager.shared.startNewChatInLastFocusedWindow() {
                            _ = ChatWindowManager.shared.createWindow()
                        }
                    }
                } label: {
                    Text(verbatim: L("New Chat"))
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            Button {
                Task { @MainActor in
                    _ = ChatWindowManager.shared.createWindow()
                }
            } label: {
                Text(verbatim: L("New Window"))
            }
            .keyboardShortcut(
                "n",
                modifiers: cmdNStartsNewChatInCurrentWindow ? [.command, .shift] : .command
            )
        }
    }

    var chatShortcutCommands: some Commands {
        CommandGroup(after: .sidebar) {
            Button {
                Task { @MainActor in ChatWindowManager.shared.toggleSidebarInFocusedWindow() }
            } label: {
                Text(verbatim: L("Toggle Sidebar"))
            }
            .keyboardShortcut("b", modifiers: .command)

            Button {
                Task { @MainActor in ChatWindowManager.shared.cycleAgentInFocusedWindow() }
            } label: {
                Text(verbatim: L("Next Agent"))
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
        }
    }

    /// Global UI font zoom, matching browsers' ⌘+/⌘-/⌘0. Upstream 1b955c2b
    /// hangs these off an existing View menu (the "Theme" picker); this
    /// fork has none, so they get their own `CommandMenu`.
    var viewMenuCommands: some Commands {
        CommandMenu(L("View")) {
            Button {
                themeManager.zoomFontIn()
            } label: {
                Text(verbatim: L("Zoom In"))
            }
            // "=" is the unshifted key under "+", matching how ⌘+ zoom is
            // reached without holding Shift in browsers.
            .keyboardShortcut("=", modifiers: .command)
            .disabled(!themeManager.canZoomFontIn)

            Button {
                themeManager.zoomFontOut()
            } label: {
                Text(verbatim: L("Zoom Out"))
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(!themeManager.canZoomFontOut)

            Button {
                themeManager.resetFontScale()
            } label: {
                Text(verbatim: L("Actual Size"))
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(themeManager.isDefaultFontScale)
        }
    }

    var settingsCommand: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button {
                AppDelegate.shared?.showManagementWindow()
            } label: {
                Text(verbatim: "Settings…")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
