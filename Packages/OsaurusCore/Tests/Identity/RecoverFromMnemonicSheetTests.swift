//
//  RecoverFromMnemonicSheetTests.swift
//  OsaurusCoreTests
//
//  Gating and preview logic for the mnemonic-restore sheet. The sheet is
//  reachable from three entry points — the drift banner, the "no identity
//  yet" setup card (fresh restore) and Danger Zone (replace existing) —
//  and each mode has different enablement rules, so the pure helpers are
//  exercised here without standing up SwiftUI.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("RecoverFromMnemonicSheet")
struct RecoverFromMnemonicSheetTests {

    // MARK: - Fixtures

    private var alicePhrase: [String] {
        get throws { try MasterKeyMnemonic.mnemonic(forKey: TestKeys.alicePrivateKey) }
    }

    private var emptyDrift: IdentityDrift {
        IdentityDrift(mismatchedAgents: [], staleAccessKeys: [])
    }

    // MARK: - canRestore

    @Test
    func incompletePhraseNeverEnablesRestore() throws {
        let short = Array(try alicePhrase.prefix(23))
        #expect(
            !RecoverFromMnemonicSheet.canRestore(
                words: short, mode: .freshRestore, acknowledgedReplace: true))
        #expect(
            !RecoverFromMnemonicSheet.canRestore(
                words: short, mode: .driftRepair(emptyDrift), acknowledgedReplace: true))
        #expect(
            !RecoverFromMnemonicSheet.canRestore(
                words: [], mode: .freshRestore, acknowledgedReplace: true))
    }

    @Test
    func freshRestoreNeedsOnlyTwentyFourWords() throws {
        #expect(
            RecoverFromMnemonicSheet.canRestore(
                words: try alicePhrase, mode: .freshRestore, acknowledgedReplace: false))
    }

    @Test
    func driftRepairNeedsOnlyTwentyFourWords() throws {
        #expect(
            RecoverFromMnemonicSheet.canRestore(
                words: try alicePhrase, mode: .driftRepair(emptyDrift), acknowledgedReplace: false))
    }

    @Test
    func replaceExistingRequiresAcknowledgment() throws {
        let mode = RecoverFromMnemonicMode.replaceExisting(current: TestKeys.bobAddress)
        #expect(
            !RecoverFromMnemonicSheet.canRestore(
                words: try alicePhrase, mode: mode, acknowledgedReplace: false))
        #expect(
            RecoverFromMnemonicSheet.canRestore(
                words: try alicePhrase, mode: mode, acknowledgedReplace: true))
    }

    // MARK: - candidateAddress preview

    @Test
    func candidateAddressMatchesTheSeedThePhraseEncodes() throws {
        let candidate = RecoverFromMnemonicSheet.candidateAddress(for: try alicePhrase)
        #expect(candidate?.lowercased() == TestKeys.aliceAddress.lowercased())
    }

    @Test
    func candidateAddressIsNilForIncompleteOrInvalidPhrases() throws {
        #expect(RecoverFromMnemonicSheet.candidateAddress(for: []) == nil)
        #expect(RecoverFromMnemonicSheet.candidateAddress(for: Array(try alicePhrase.prefix(12))) == nil)

        // 24 words, but the last word breaks the BIP39 checksum.
        var tampered = try alicePhrase
        tampered[23] = tampered[23] == "zoo" ? "abandon" : "zoo"
        #expect(RecoverFromMnemonicSheet.candidateAddress(for: tampered) == nil)
    }

    // MARK: - Drift-repair previous-seed verification

    @Test
    func driftRepairAcceptsThePhraseThatDerivedTheStrandedAgents() throws {
        // Agents were minted under Bob; the user pastes Bob's phrase.
        var agent = Self.makeAgent(name: "Stranded")
        agent.agentIndex = 0
        agent.agentAddress = try AgentKey.deriveAddress(masterKey: TestKeys.bobPrivateKey, index: 0)
        let drift = IdentityDrift(mismatchedAgents: [agent], staleAccessKeys: [])

        let message = RecoverFromMnemonicSheet.previousSeedMismatchMessage(
            drift: drift, seed: TestKeys.bobPrivateKey, candidate: TestKeys.bobAddress)
        #expect(message == nil)
    }

    @Test
    func driftRepairFlagsAnUnrelatedPhrase() throws {
        var agent = Self.makeAgent(name: "Stranded")
        agent.agentIndex = 0
        agent.agentAddress = try AgentKey.deriveAddress(masterKey: TestKeys.bobPrivateKey, index: 0)
        let drift = IdentityDrift(mismatchedAgents: [agent], staleAccessKeys: [])

        // Alice's phrase can't reproduce Bob-derived agent addresses.
        let message = RecoverFromMnemonicSheet.previousSeedMismatchMessage(
            drift: drift, seed: TestKeys.alicePrivateKey, candidate: TestKeys.aliceAddress)
        #expect(message != nil)
    }

    @Test
    func driftRepairWithNothingToCompareAgainstIsAccepted() throws {
        let message = RecoverFromMnemonicSheet.previousSeedMismatchMessage(
            drift: emptyDrift, seed: TestKeys.alicePrivateKey, candidate: TestKeys.aliceAddress)
        #expect(message == nil)
    }

    // MARK: - Helpers

    private static func makeAgent(name: String) -> Agent {
        Agent(
            id: UUID(),
            name: name,
            description: "",
            systemPrompt: "",
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}
