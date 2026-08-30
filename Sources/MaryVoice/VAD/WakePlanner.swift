//
//  WakePlanner.swift
//  MaryVoice
//
//  WHAT: Pure wake / stop-listening matchers for standby and session exit.
//  IN:   WakeWordListener / VoicePipeline.interceptStopListening
//  OUT:  Wake.bare | Wake.request | isStopListening
//
//  Sibling of IntakePlanner. PIN: positional (name must lead), not namesHer.
//

import Foundation

public enum WakePlanner {

    public struct Tuning: Sendable, Equatable {
        /// Name plus STT homophones. Duplicated from MaryBrain — MaryVoice cannot import it.
        public var wakeNames: Set<String> = ["mary", "bonny", "bonni", "bonne"]
        /// Words allowed before the name. Position-strict everywhere else.
        public var preambleWords: Set<String> = ["hey", "ok", "okay", "hi"]
        /// Address + politeness stripped from both ends when matching stop.
        public var commandAddressWords: Set<String> =
            ["mary", "bonny", "bonni", "bonne", "hey", "ok", "okay", "please", "now"]

        public init() {}
        public static let standard = Tuning()
    }

    public enum Wake: Sendable, Equatable {
        /// "Hey Mary." — greet and listen.
        case bare
        /// "Hey Mary, open mail" — remainder is the first turn.
        case request(String)
    }

    /// nil when not a wake phrase. Name must be first or after preamble only.
    /// Per-token letters-and-digits so "Mary," counts and "summary" never does.
    public static func wake(in text: String, tuning: Tuning = .standard) -> Wake? {
        let rawTokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var wakeIndex: Int?
        for (index, raw) in rawTokens.enumerated() {
            let token = normalize(raw)
            // Bare punctuation decides nothing.
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

    /// Early-abort for live partials: can this still become a wake phrase?
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
        // Final token of a live partial may still be mid-word.
        guard index == tokens.count - 1 else { return false }
        return tuning.wakeNames.contains { $0.hasPrefix(head) }
            || tuning.preambleWords.contains { $0.hasPrefix(head) }
    }

    /// Deterministic session exit: after stripping address words, must equal
    /// the command. Bare "stop" stays with routine-cancel downstream.
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

    /// `IntakePlanner.namesHer` normalization, per token.
    private static func normalize(_ token: String) -> String {
        String(token.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Punctuation a remainder may start with after the name token is dropped.
    private static let remainderLeadTrim = CharacterSet.whitespaces
        .union(CharacterSet(charactersIn: ",;:—–-…."))
}
