//
//  RoutingSchemaSeedTests.swift
//  MaryFoundationTests
//
//  WHAT: `intentSeeds` reads the spelling it replaced.
//  PIN:  `AbilityTriggerSchema` does NOT reject unknown keys, so if the retired
//        `intentExemplars` case were dropped, a package sealed before the
//        rename would decode to an EMPTY intent corpus with no error at all —
//        intent classification would quietly stop working for it. This test is
//        the only thing standing between that and a silent regression.
//
import Foundation
import Testing
@testable import MaryFoundation

@Suite struct RoutingSchemaSeedTests {

    private func decode(_ json: String) throws -> AbilityTriggerSchema {
        try JSONDecoder().decode(AbilityTriggerSchema.self, from: Data(json.utf8))
    }

    @Test func theRetiredSpellingStillLoads() throws {
        let schema = try decode("""
        {"intentExemplars": {"operate": ["pause the music"]}}
        """)
        #expect(schema.intentSeeds == ["operate": ["pause the music"]])
    }

    @Test func theCurrentSpellingLoads() throws {
        let schema = try decode("""
        {"intentSeeds": {"operate": ["pause the music"]}}
        """)
        #expect(schema.intentSeeds == ["operate": ["pause the music"]])
    }

    /// Both present is an authoring mistake, not a merge — the current
    /// spelling is the one that counts.
    @Test func theCurrentSpellingWins() throws {
        let schema = try decode("""
        {"intentSeeds": {"operate": ["new"]},
         "intentExemplars": {"operate": ["old"]}}
        """)
        #expect(schema.intentSeeds == ["operate": ["new"]])
    }

    /// Resealing migrates: read either spelling, write only the new one.
    @Test func encodingWritesOnlyTheNewSpelling() throws {
        let schema = try decode("""
        {"intentExemplars": {"operate": ["pause the music"]}}
        """)
        let data = try JSONEncoder().encode(schema)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("intentSeeds"))
        #expect(!text.contains("intentExemplars"), "resealing must not write the retired key back")
    }
}
