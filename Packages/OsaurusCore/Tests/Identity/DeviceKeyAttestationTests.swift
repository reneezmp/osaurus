//
//  DeviceKeyAttestationTests.swift
//  OsaurusCoreTests
//
//  Regression cover for the restore-onto-an-unattested-Mac bug: only
//  `OsaurusIdentity.setup()` ever called `DeviceKey.attest()`, so a Mac that
//  received its master by mnemonic restore (or iCloud Keychain sync) had a
//  valid master and no device ID. `currentDeviceId()` threw, every caller read
//  that as "no identity", and the Identity screen bounced back to the setup
//  card with no error shown. `ensureDeviceId()` closes that gap.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct DeviceKeyAttestationTests {

    private static let deviceIdKey = "com.osaurus.device.deviceId"
    private static let keyIdKey = "com.osaurus.device.keyId"
    private static let softwareMarker = "com.osaurus.device.software"

    /// Snapshot/restore the three defaults these tests mutate so a run can't
    /// strand the developer's own machine without a device ID.
    private func withCleanDeviceDefaults(_ body: () async throws -> Void) async rethrows {
        let d = UserDefaults.standard
        let savedDeviceId = d.string(forKey: Self.deviceIdKey)
        let savedKeyId = d.string(forKey: Self.keyIdKey)
        let savedMarker = d.object(forKey: Self.softwareMarker)
        d.removeObject(forKey: Self.deviceIdKey)
        d.removeObject(forKey: Self.keyIdKey)
        d.removeObject(forKey: Self.softwareMarker)
        defer {
            if let savedDeviceId { d.set(savedDeviceId, forKey: Self.deviceIdKey) } else { d.removeObject(forKey: Self.deviceIdKey) }
            if let savedKeyId { d.set(savedKeyId, forKey: Self.keyIdKey) } else { d.removeObject(forKey: Self.keyIdKey) }
            if let savedMarker { d.set(savedMarker, forKey: Self.softwareMarker) } else { d.removeObject(forKey: Self.softwareMarker) }
        }
        try await body()
    }

    @Test
    func currentDeviceIdThrowsWhenNothingHasAttested() async throws {
        await withCleanDeviceDefaults {
            #expect(!DeviceKey.isAttested)
            #expect(throws: (any Error).self) {
                _ = try DeviceKey.currentDeviceId()
            }
        }
    }

    @Test
    func ensureDeviceIdAttestsOnFirstUse() async throws {
        try await withCleanDeviceDefaults {
            let id = try await DeviceKey.ensureDeviceId()
            #expect(!id.isEmpty)
            // The whole point: the read path that used to throw now works.
            #expect((try? DeviceKey.currentDeviceId()) == id)
            #expect(DeviceKey.isAttested)
        }
    }

    @Test
    func ensureDeviceIdIsStableAcrossCalls() async throws {
        try await withCleanDeviceDefaults {
            let first = try await DeviceKey.ensureDeviceId()
            let second = try await DeviceKey.ensureDeviceId()
            #expect(first == second)
        }
    }

    @Test
    func ensureDeviceIdKeepsAnAlreadyAttestedId() async throws {
        try await withCleanDeviceDefaults {
            UserDefaults.standard.set("cafebabe", forKey: Self.deviceIdKey)
            let id = try await DeviceKey.ensureDeviceId()
            #expect(id == "cafebabe")
        }
    }
}
