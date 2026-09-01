//
//  EmbeddingIntentEngineTests.swift
//  MaryAmbientTests
//
//  WHAT: Embedding operate/perceive/converse is the route when supplied.
//  OUT:  AmbientEngine.classify
//  PIN:  Halt / confirm / edit still win. Nil embeddingIntent keeps the lexical ladder.
//

import Testing
@testable import MaryAmbient

@Suite struct EmbeddingIntentEngineTests {

    @Test func anEmbeddingIntentSettlesOperateWithoutTheLexicalLadder() {
        let route = AmbientEngine.resolve(.init(
            utterance: "look at this",
            embeddingIntent: .operate))
        #expect(route.intent == .operate)
        #expect(route.decidedBy == .embedding)
    }

    @Test func anEmbeddingIntentFailsClosedToConverse() {
        let route = AmbientEngine.resolve(.init(
            utterance: "look at this",
            embeddingIntent: .converse))
        #expect(route.intent == .converse)
        #expect(route.decidedBy == .embedding)
    }

    @Test func editStillWinsOverAnEmbeddingIntent() {
        let route = AmbientEngine.resolve(.init(
            utterance: "replace this paragraph",
            embeddingIntent: .operate,
            editIntent: EditIntent(shape: .replace, target: ["this paragraph"])))
        #expect(route.intent == .revise)
        #expect(route.decidedBy == .editIntent)
    }

}
