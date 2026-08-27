//
//  WakePlanner.swift
//  MaryVoice
//
//  WHAT WAKES HER, AND WHAT MERELY MENTIONS HER — the pure decisions in front
//  of standby listening and the "stop listening" exit. A direct sibling of
//  `IntakePlanner` in this directory, and the same shape: a caseless enum, an
//  `Equatable` verdict, no clock, no actor.
//
//  DELIBERATELY NOT `IntakePlanner.namesHer`. That matcher answers "is she
//  named ANYWHERE in this line?" for continuous hearing, where the cost of a
//  match is a turn the user was already speaking toward her. Standby is the
//  opposite economy: a false positive here does not produce a bad reply — it
//  OPENS THE MICROPHONE and ACTS. So wake matching is positional (the name
//  must lead, at most behind a greeting word), and "I told Mary about it"
//  wakes nothing.
//

import Foundation

public enum WakePlanner {

    public struct Tuning: Sendable, Equatable {
        /// The name plus the STT homophones a wake phrase actually arrives as.
        /// Precedent: MaryBrain's `dictationAddressWords` — duplicated here
        /// because MaryVoice cannot import MaryBrain.
        public var wakeNames: Set<String> = ["mary", "bonny", "bonni", "bonne"]
        /// Words allowed BEFORE the name: "hey mary", "okay mary".
        /// Position-strict everywhere else.
        public var preambleWords: Set<String> = ["hey", "ok", "okay", "hi"]
        /// Address + politeness words stripped from both ends when matching
        /// the stop command, so "Mary, please stop listening now" lands.
        public var commandAddressWords: Set<String> =
            ["mary", "bonny", "bonni", "bonne", "hey", "ok", "okay", "please", "now"]

        public init() {}
        public static let standard = Tuning()
    }

    public enum Wake: Sendable, Equatable {
        /// "Hey Mary." — greet and listen.
        case bare
        /// "Hey Mary, open mail" — the request rides along as the first
        /// turn, original casing and punctuation preserved.
        case request(String)
    }

    /// nil when the utterance is not addressed as a wake phrase. The name
    /// must be the first word or preceded only by preamble words. Matching is
    /// per-token over a lowercased letters-and-digits form, so "Mary," and
    /// "mary?" count and "summary"/"primary" never do — see
    /// `IntakePlanner.Tuning.wakeWords` on why this name needs the boundary
    /// more than the last one did.
    public static func wake(in text: String, tuning: Tuning = .standard) -> Wake? {
        let rawTokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var wakeIndex: Int?
        for (index, raw) in rawTokens.enumerated() {
            let token = normalize(raw)
            // Bare punctuation the recognizer coughed up decides nothing.
            if token.isEmpty { continue }
            if tuning.wakeNames.contains(token) {
                wakeIndex = index
                break
            }
            guard tuning.preambleWords.contains(token) else { return nil }
        }
        guard let wakeIndex else { return nil }

        let remainder = rawTokens[(wakeIndex + 1)...]
            .joined(separator: " ")
            .trimmingCharacters(in: Self.remainderLeadTrim)
        return remainder.isEmpty ? .bare : .request(remainder)
    }

    /// Early-abort gate for live partials: can this utterance still become a
    /// wake phrase? False the moment the leading words rule the name out —
    /// which is what bounds standby transcription to the first breath of every
    /// non-wake utterance in the room.
    public static func couldStillWake(partial: String, tuning: Tuning = .standard) -> Bool {
        let tokens = partial.split(whereSeparator: { $0.isWhitespace })
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
        var index = 0
        while index < tokens.count, tuning.preambleWords.contains(tokens[index]) {
            index += 1
        }
        // Nothing decisive yet — silence, or preamble still unfolding.
        guard index < tokens.count else { return true }
        let head = tokens[index]
        if tuning.wakeNames.contains(head) { return true }
        // The final token of a live partial may still be mid-word ("bonn").
        guard index == tokens.count - 1 else { return false }
        return tuning.wakeNames.contains { $0.hasPrefix(head) }
            || tuning.preambleWords.contains { $0.hasPrefix(head) }
    }

    /// Deterministic session exit: with address words stripped from both
    /// ends, the utterance must EQUAL the command — whole and exact, the
    /// dictation-control rule. "stop listening to the album" is prose, and
    /// bare "stop" stays with the routine-cancel vocabulary downstream.
    public static func isStopListening(_ text: String, tuning: Tuning = .standard) -> Bool {
        var tokens = text.split(whereSeparator: { $0.isWhitespace })
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
        while let first = tokens.first, tuning.commandAddressWords.contains(first) {
            tokens.removeFirst()
        }
        while let last = tokens.last, tuning.commandAddressWords.contains(last) {
            tokens.removeLast()
        }
        let phrase = tokens.joined(separator: " ")
        return phrase == "stop listening" || phrase == "quit listening"
    }

    /// The `IntakePlanner.namesHer` normalization, applied per token.
    private static func normalize(_ token: String) -> String {
        String(token.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Punctuation a remainder may start with after the name's own token is
    /// dropped: "Hey Mary — what's up" → "what's up".
    private static let remainderLeadTrim = CharacterSet.whitespaces
        .union(CharacterSet(charactersIn: ",;:—–-…."))
}
