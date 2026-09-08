//
//  AgentDecodeToleranceTests.swift
//  OsaurusCoreTests
//
//  `AutonomousExecConfig` had four non-optional fields and a synthesized
//  decoder, so an agent JSON missing any one of them failed to decode
//  entirely. `AgentManager.reload()` loads agents with `try?`, so the agent
//  just wasn't there — no error, no log line, no clue. An Osaurus on another
//  Mac that predates `commandTimeout` writes exactly that shape, and every
//  agent copied from it vanished.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Agent decode tolerance")
struct AgentDecodeToleranceTests {

    private func decode(_ json: String) throws -> AutonomousExecConfig {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(AutonomousExecConfig.self, from: Data(json.utf8))
    }

    @Test
    func missingCommandTimeoutFallsBackToTheDefault() throws {
        let cfg = try decode(#"{"enabled":true,"maxCommandsPerTurn":4,"pluginCreate":false}"#)
        #expect(cfg.enabled)
        #expect(cfg.maxCommandsPerTurn == 4)
        #expect(cfg.pluginCreate == false)
        #expect(cfg.commandTimeout == AutonomousExecConfig.default.commandTimeout)
    }

    @Test
    func anEmptyObjectDecodesToTheDefaults() throws {
        #expect(try decode("{}") == AutonomousExecConfig.default)
    }

    @Test
    func presentFieldsStillWin() throws {
        let cfg = try decode(
            #"{"enabled":true,"maxCommandsPerTurn":99,"commandTimeout":7,"pluginCreate":false}"#)
        #expect(cfg == AutonomousExecConfig(
            enabled: true, maxCommandsPerTurn: 99, commandTimeout: 7, pluginCreate: false))
    }

    @Test
    func unknownFieldsFromANewerBuildAreIgnored() throws {
        let cfg = try decode(#"{"enabled":true,"someFutureKnob":"whatever"}"#)
        #expect(cfg.enabled)
    }

    @Test
    func aFullAgentMissingCommandTimeoutStillLoads() throws {
        // The exact shape written by an Osaurus that predates the field.
        let json = """
            {"id":"445248FB-198A-41AD-998E-0F291A9DB1B2","name":"Imported",
             "description":"","systemPrompt":"","isBuiltIn":false,
             "createdAt":"2026-06-06T14:39:48Z","updatedAt":"2026-06-06T14:39:48Z",
             "bonjourEnabled":false,
             "autonomousExec":{"enabled":false,"maxCommandsPerTurn":10,"pluginCreate":true},
             "settings":{}}
            """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let agent = try dec.decode(Agent.self, from: Data(json.utf8))
        #expect(agent.name == "Imported")
        #expect(agent.autonomousExec?.commandTimeout == AutonomousExecConfig.default.commandTimeout)
    }
}
