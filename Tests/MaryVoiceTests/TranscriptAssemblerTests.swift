//
//  TranscriptAssemblerTests.swift
//  MaryVoiceTests
//
//  WHAT: A recognizer's finals and partials fold into one transcript that
//        keeps the head and the tail of a paused phrase.
//  OUT:  TranscriptAssembler
//

import Testing
@testable import MaryVoice

@Suite struct TranscriptAssemblerTests {

    @Test func partialsReplaceTheLiveText() {
        var assembler = TranscriptAssembler()
        assembler.update(text: "open", isFinal: false)
        assembler.update(text: "open the Saf", isFinal: false)
        assembler.update(text: "open the Safari window", isFinal: false)
        #expect(assembler.transcript == "open the Safari window")
    }

    /// The tail bug: a final mid-phrase used to BE the answer, dropping the rest.
    @Test func speechAfterAnEarlyFinalIsKept() {
        var assembler = TranscriptAssembler()
        assembler.update(text: "open the", isFinal: true)
        assembler.update(text: "Safari", isFinal: false)
        assembler.update(text: "Safari window", isFinal: true)
        #expect(assembler.transcript == "open the Safari window")
    }

    /// The head bug: a recognizer that restarts its text after a pause must
    /// not erase what came before it.
    @Test func aRestartedSegmentDoesNotEraseTheHead() {
        var assembler = TranscriptAssembler()
        assembler.update(text: "Hey Mary", isFinal: false)
        assembler.update(text: "Hey Mary find the", isFinal: true)
        assembler.update(text: "notes from Tuesday", isFinal: false)
        #expect(assembler.transcript == "Hey Mary find the notes from Tuesday")
    }

    @Test func anEmptyFinalKeepsThePartialItClosedOn() {
        var assembler = TranscriptAssembler()
        assembler.update(text: "turn it up", isFinal: false)
        assembler.update(text: "", isFinal: true)
        #expect(assembler.transcript == "turn it up")
        #expect(assembler.live.isEmpty)
    }

    @Test func nothingHeardIsEmpty() {
        var assembler = TranscriptAssembler()
        assembler.update(text: "   ", isFinal: false)
        assembler.update(text: "", isFinal: true)
        #expect(assembler.transcript.isEmpty)
    }
}
