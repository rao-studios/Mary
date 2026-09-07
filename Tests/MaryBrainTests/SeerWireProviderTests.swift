//
//  SeerWireProviderTests.swift
//  MaryBrainTests
//
//  WHAT: The `provider` field on every request that carries one, and its
//        absence when no backend was chosen.
//  PIN:  Seer reads these exact strings. Mary sends nothing when the lane has
//        no explicit choice, and Seer then applies its own default.
//

import Foundation
import Testing
@testable import MaryBrain

@Suite struct SeerWireProviderTests {

    private func object(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func theChatRequestCarriesTheChosenBackend() throws {
        let json = try object(SeerWire.ChatRequest(
            messages: [SeerChatMessage(role: "user", content: "hello")],
            model: nil,
            provider: .tinker,
            seer: SeerWire.SeerScope(ownerID: "owner", requestID: "r1")))
        #expect(json["provider"] as? String == "tinker")
    }

    /// NO FIELD, NOT A GUESS. An unset lane must leave the key off so Seer's
    /// own default applies — sending "mistral" would override a server
    /// configured for something else.
    @Test func anUnsetBackendSendsNoProviderKey() throws {
        let json = try object(SeerWire.ChatRequest(
            messages: [SeerChatMessage(role: "user", content: "hello")],
            model: nil,
            seer: SeerWire.SeerScope(ownerID: "owner", requestID: "r1")))
        #expect(json["provider"] == nil)
    }

    @Test func theSkillsRequestCarriesTheChosenBackend() throws {
        let json = try object(SeerWire.SkillsCompleteRequest(
            instructions: "act",
            messages: [SeerChatMessage(role: "user", content: "open Calendar")],
            tools: nil,
            maxTokens: 800,
            temperature: 0,
            provider: .local))
        #expect(json["provider"] as? String == "local")
    }

    @Test func theCompleteRequestCarriesTheChosenBackend() throws {
        let json = try object(SeerWire.CompleteRequest(
            instructions: "describe",
            messages: [SeerChatMessage(role: "user", content: "a file")],
            maxTokens: 256,
            temperature: 0,
            provider: .mistral))
        #expect(json["provider"] as? String == "mistral")
    }

    @Test func everyBackendRoundTripsThroughItsRawValue() throws {
        for choice in LLMEngineChoice.allCases {
            let json = try object(SeerWire.CompleteRequest(
                instructions: nil,
                messages: [],
                maxTokens: nil,
                temperature: nil,
                provider: choice))
            #expect(json["provider"] as? String == choice.rawValue)
        }
    }
}
