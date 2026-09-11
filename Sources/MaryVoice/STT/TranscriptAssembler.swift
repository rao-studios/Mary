//
//  TranscriptAssembler.swift
//  MaryVoice
//
//  WHAT: A recognizer's result stream → one transcript that keeps every segment.
//  IN:   AppleSpeechTranscriber / AnalyzerSpeechTranscriber result handlers
//  OUT:  transcript (partials + finish)
//  PIN:  A final commits its segment; the next text starts a new one. A
//        mid-phrase final must never become the whole answer.
//

import Foundation

struct TranscriptAssembler: Sendable, Equatable {
    /// Segments the recognizer finalized, in order.
    private(set) var committed: [String] = []
    /// Latest unfinalized text — replaced by each partial, never appended.
    private(set) var live = ""

    var transcript: String {
        (committed + [live]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    mutating func update(text: String, isFinal: Bool) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFinal else {
            live = text
            return
        }
        // An empty final (an error-shaped close) keeps the partial it ended on.
        let segment = text.isEmpty ? live : text
        if !segment.isEmpty { committed.append(segment) }
        live = ""
    }
}
