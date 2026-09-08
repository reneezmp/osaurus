//
//  IntelStorageMigrationCoordinatorTests.swift
//  osaurusTests
//
//  Coverage for the Intel `StorageMigrationCoordinator` latch (defined in
//  `Models/Chat/IntelConformers/IntelScheduleConformers.swift`). This is
//  a different type from the Apple Silicon `StorageMigrationCoordinator`
//  (`@MainActor` `ObservableObject` in `Views/Storage/StorageMigrationOverlay.swift`,
//  covered by `StorageCoordinatorTests.swift` — which is excluded on this
//  fork because it doesn't compile against the Intel stub; see
//  `Package.swift`'s exclude list).
//
//  What we care about here:
//   - `markReady()` is idempotent: calling it more than once must not
//     trap (a naive `DispatchGroup.leave()` on every call would, once
//     the group's count hits zero).
//   - `blockingAwaitReady()` returns immediately once the gate is ready
//     (the lock-free fast path — no semaphore/group wait at all).
//   - The test bypass (`RuntimeEnvironment.isUnderTests`) makes
//     `blockingAwaitReady()` return immediately even when nothing has
//     called `markReady()` — without it, every gated test process would
//     block for up to 30s (or every test that transitively opens a
//     database would, under `swift test`).
//
//  We do NOT test the real 30-second timeout path with a live sleep —
//  that would make this suite slow for no benefit. Instead we assert the
//  bypass takes effect well under the timeout window, which is the
//  behavior that actually protects `swift test` from hanging.
//
//  NOTE: deliberately NOT wrapped in `#if OSAURUS_INTEL`. The
//  `OsaurusCoreTests` target (see `Package.swift`'s `.testTarget`) has no
//  `swiftSettings` of its own — only the `OsaurusCore` library target
//  defines `OSAURUS_INTEL` — so an `#if OSAURUS_INTEL` guard *inside a
//  test file* is always false and silently compiles away the whole
//  suite, without a build error and without a skipped-test notice.
//  `Tests/Model/IntelClaudeCodeTests.swift` has this exact bug today
//  (verified: `swift test --filter IntelClaudeCodeTests` reports "No
//  matching test cases were run"). The production types this suite
//  exercises (`StorageMigrationCoordinator`, `AtomicBool`,
//  `RuntimeEnvironment.isUnderTests`) are compiled into `OsaurusCore`
//  unconditionally on this fork regardless of the test target's own
//  flags, so no guard is needed here for the suite to actually run.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct IntelStorageMigrationCoordinatorTests {

    @Test
    func markReadyIsIdempotent() {
        // Calling markReady() repeatedly must never trap. The production
        // caller does this exactly once (from the headless runner's
        // `defer`), but the contract itself — "safe to call more than
        // once" — is what protects against a future bug where some other
        // exit path also calls it.
        StorageMigrationCoordinator.markReady()
        StorageMigrationCoordinator.markReady()
        StorageMigrationCoordinator.markReady()
        // No trap reaching here is the assertion.
    }

    @Test
    func blockingAwaitReadyReturnsImmediatelyOnceReady() {
        StorageMigrationCoordinator.markReady()

        let start = Date()
        StorageMigrationCoordinator.blockingAwaitReady()
        let elapsed = Date().timeIntervalSince(start)

        // Lock-free fast path: this should be effectively instant, nowhere
        // near the 30s timeout.
        #expect(elapsed < 1.0)
    }

    @Test
    func testBypassPreventsHangingWhenNeverMarkedReady() {
        // This test intentionally never calls markReady() first. Under
        // `swift test` / XCTest, `RuntimeEnvironment.isUnderTests` is
        // true, so `blockingAwaitReady()` must return immediately rather
        // than waiting up to 30s for a `markReady()` that will never come
        // (nothing in this process plays the role of
        // `AppDelegate.applicationDidFinishLaunching`).
        #expect(RuntimeEnvironment.isUnderTests)

        let start = Date()
        StorageMigrationCoordinator.blockingAwaitReady()
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 1.0)
    }

    @Test
    func blockingAwaitReadyUnblocksConcurrentWaiters() async {
        // Simulates the real shape of contention: MemoryDatabase.open()
        // and SchedulerDatabase.open() can both call blockingAwaitReady()
        // concurrently from separate Task.detached background queues.
        // Because the test bypass short-circuits under `swift test`, this
        // mainly pins that multiple concurrent callers all return without
        // deadlocking each other or the group.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    StorageMigrationCoordinator.blockingAwaitReady()
                }
            }
        }
        // Reaching here without hanging is the assertion.
    }
}
