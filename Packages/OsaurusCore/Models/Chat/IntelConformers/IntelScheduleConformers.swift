//
//  IntelScheduleConformers.swift
//  OsaurusCore (Intel fork)
//
//  Stubs for the Schedules subsystem restore (M13, Renée 2026-06-03).
//
//  The schedule EXECUTION chain (ScheduleManager → TaskDispatcher →
//  BackgroundTaskManager → SchedulerDatabase) is un-excluded on Intel:
//  it is pure Foundation/Combine/SQLCipher and the agent fires headless
//  through the existing cloud pipeline. The only thing it reaches into
//  that stays amputated is the plugin host. `PluginHostContext` lives in
//  the excluded `Services/Plugin/PluginHostAPI.swift` (MLX/Sandbox host),
//  and `PluginManager` is entirely `#if !OSAURUS_INTEL`-gated. Plugins are
//  amputated on Intel, so nothing consumes task events — these serializers
//  return empty JSON, and cache-invalidation forwards to the real
//  `SessionToolStateStore` (which IS compiled on Intel).
//

import Combine
import Foundation
import os

#if OSAURUS_INTEL

/// Intel stub for the amputated plugin host's static event surface.
///
/// On Apple Silicon `PluginHostContext` is a `final class` instantiated per
/// loaded plugin; on Intel no plugin ever loads (PluginManager is gated out),
/// so only `BackgroundTaskManager`'s static serialize/invalidate calls remain.
/// Modeled as an `enum` (no instances) returning empty payloads.
enum PluginHostContext {
    static func invalidatePreflightCache(sessionId: String) {
        Task { await SessionToolStateStore.shared.invalidate(sessionId) }
    }

    static func serializeStartedEvent(state: BackgroundTaskState) -> String { "{}" }

    static func serializeActivityEvent(
        kind: BackgroundTaskActivityItem.Kind,
        title: String,
        detail: String?,
        metadata: [String: Any]? = nil
    ) -> String { "{}" }

    static func serializeClarificationEvent(payload: ClarifyPayload) -> String { "{}" }

    static func serializeCompletedEvent(
        success: Bool,
        summary: String,
        sessionId: UUID?,
        taskTitle: String,
        artifacts: [SharedArtifact] = [],
        outputText: String? = nil
    ) -> String { "{}" }

    static func serializeCancelledEvent(taskTitle: String) -> String { "{}" }

    static func serializeDraftEvent(draftJSON: String, taskTitle: String) -> String { "{}" }
}

/// Intel stub for the plugin task-event enum (real one lives in the fully
/// `#if !OSAURUS_INTEL` `Models/Plugin/ExternalPlugin.swift`). Raw values
/// mirror upstream so any persisted/serialized ints stay compatible. Only
/// `BackgroundTaskManager`'s now-gated plugin-notify path references the
/// cases on Intel; no plugin ever consumes them.
enum TaskEventType: Int32 {
    case started = 0
    case activity = 1
    case progress = 2
    case clarification = 3
    case completed = 4
    case failed = 5
    case cancelled = 6
    case output = 7
    case draft = 8
}

/// Intel stand-in for the storage-migration gate (real one lives in the
/// `#if !OSAURUS_INTEL` `Views/Storage/StorageMigrationOverlay.swift`, a
/// `@MainActor` `ObservableObject` driving the "Securing your data" panel).
///
/// Intel has no overlay UI and no SwiftUI window server guarantee — the
/// gate has to be a plain, actor-isolation-free latch that any background
/// `Task` can block on without hopping to the main actor. It is
/// deliberately dumb: unlike the Apple Silicon coordinator, this one does
/// NOT lazily kick off `StorageMigrator.runIfNeeded()` itself. On Intel
/// `AppDelegate.applicationDidFinishLaunching` is the single place that
/// starts the headless migration runner (see the `#if OSAURUS_INTEL`
/// block appended to `Storage/StorageMigrator.swift`); this type only
/// blocks callers until that runner calls `markReady()`. Two call sites
/// gate on it today, both already off the main actor:
/// `MemoryDatabase.open()` and `SchedulerDatabase.open()`.
enum StorageMigrationCoordinator {
    /// Lock-free fast path so a caller that arrives after migration has
    /// already completed never touches the semaphore/group machinery.
    /// Mirrors `AtomicBool`'s doc-comment rationale: an
    /// `OSAllocatedUnfairLock`-backed Bool costs the same as a bare
    /// atomic load on Apple platforms, and there are effectively zero
    /// writers (one, ever, per process).
    private static let ready = AtomicBool(false)

    /// Gates every waiter that arrives before `markReady()` fires.
    /// `DispatchGroup` (rather than a single `DispatchSemaphore`) is used
    /// because more than one thread can call `blockingAwaitReady()`
    /// concurrently (memory DB open + scheduler DB open can race on
    /// separate `Task.detached` background queues) and a semaphore's
    /// single permit would only release one of them.
    private static let group: DispatchGroup = {
        let g = DispatchGroup()
        g.enter()
        return g
    }()

    /// Serializes `markReady()`. Two `AtomicBool`s checked and set
    /// independently are each atomic but not atomic *together*: two
    /// concurrent callers can both observe "not yet left" and both call
    /// `group.leave()`, which traps on an already-balanced group. Only the
    /// headless runner calls `markReady()` today, from a single `defer`,
    /// but the method is documented as safe to call from anywhere — so it
    /// has to actually be safe, not safe-by-current-call-graph.
    private static let readyLock = NSLock()

    /// Blocks the calling thread until the headless migration runner has
    /// finished (successfully or not — see the divergence note below),
    /// or until 30 seconds elapse.
    ///
    /// Order of checks matters:
    ///  1. Test bypass — under `swift test` / XCTest there is no
    ///     `AppDelegate.applicationDidFinishLaunching`, so nothing ever
    ///     calls `markReady()`. Without this bypass every gated test
    ///     (and every test that transitively opens a database) would
    ///     block for the full 30-second timeout, or forever if this
    ///     method is ever called from a context that already holds a
    ///     lock the timeout path needs. See `RuntimeEnvironment.isUnderTests`.
    ///  2. Lock-free fast path — the common case once launch has
    ///     finished migrating.
    ///  3. Bounded wait — 30 seconds is generous relative to a SQLCipher
    ///     re-encryption pass over a handful of local SQLite files, but
    ///     finite: a bug in the runner (a deadlock, a thrown error before
    ///     the `defer` registers, whatever) must never permanently wedge
    ///     every caller of a gated `*Database.open()` for the rest of the
    ///     process's life. On timeout we log loudly and proceed anyway —
    ///     the same "fail open" choice `runMigration()` makes below.
    nonisolated static func blockingAwaitReady() {
        if RuntimeEnvironment.isUnderTests { return }
        if ready.load() { return }

        let waitResult = group.wait(timeout: .now() + 30)
        if waitResult == .timedOut {
            Logger(subsystem: "ai.osaurus", category: "storage.migrator")
                .error(
                    "StorageMigrationCoordinator: blockingAwaitReady() timed out after 30s waiting for the headless migration runner; proceeding without the guarantee that storage is migrated"
                )
        }
    }

    /// Marks the gate ready and releases every thread currently parked in
    /// `blockingAwaitReady()`. Idempotent — safe to call from a `defer` on
    /// every exit path of the headless runner (including thrown/failed
    /// ones) without worrying about a double `group.leave()` trapping the
    /// process.
    nonisolated static func markReady() {
        readyLock.lock()
        defer { readyLock.unlock() }
        guard !ready.load() else { return }
        ready.store(true)
        group.leave()
    }
}

/// Drives the menu-bar status card's "task running / finished" row on Intel.
///
/// The upstream NotchView (the floating task indicator) is amputated, so this
/// is the Intel surface for surfacing a background/scheduled run. A start
/// replaces any prior entry; a finish flips its status in place; the entry
/// persists until the user dismisses it or a new task starts. `BackgroundTaskManager`
/// updates it (Intel-gated) and `IntelStatusPanelView` observes it.
@MainActor
final class IntelTaskBanner: ObservableObject {
    static let shared = IntelTaskBanner()

    enum Status: Equatable { case running, completed, failed }

    struct Entry: Identifiable, Equatable {
        let id: UUID
        var title: String
        var status: Status
        let startedAt: Date
    }

    @Published var entry: Entry?

    private init() {}

    func started(id: UUID, title: String) {
        entry = Entry(
            id: id,
            title: title.isEmpty ? "Task" : title,
            status: .running,
            startedAt: Date()
        )
    }

    func finished(id: UUID, success: Bool) {
        guard entry?.id == id else { return }
        entry?.status = success ? .completed : .failed
    }

    func dismiss() { entry = nil }
}

#endif
