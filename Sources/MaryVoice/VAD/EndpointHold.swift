//
//  EndpointHold.swift
//  MaryVoice
//
//  WHAT: Extra trailing silence while the phrase so far looks unfinished.
//  IN:   VoicePipeline.emitPartial (latest partial)
//  OUT:  EnergyVAD.hangoverExtension
//  PIN:  Only lengthens a pause the VAD would otherwise end on. A finished
//        phrase still closes at the configured hangover.
//

import Foundation

enum EndpointHold {

    /// Added to the hangover when the partial ends on a dangling word.
    static let danglingExtension: TimeInterval = 0.7

    /// Words a spoken request does not end on: articles, possessives,
    /// prepositions that need an object, conjunctions, fillers. Particles that
    /// DO end commands ("turn it on", "log in", "turn it up") stay out.
    static let danglingWords: Set<String> = [
        "a", "an", "the",
        "my", "your", "our", "their",
        "to", "of", "for", "with", "from", "into", "onto", "at", "by", "via",
        "and", "or", "but", "then", "because", "if", "than",
        "um", "uh", "uhm", "er", "erm", "hmm",
    ]

    static func extraSilence(forPartial text: String) -> TimeInterval {
        guard let last = text.split(whereSeparator: \.isWhitespace).last else { return 0 }
        let word = String(last.lowercased().filter { $0.isLetter || $0.isNumber })
        return danglingWords.contains(word) ? danglingExtension : 0
    }
}
