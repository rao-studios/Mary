//
//  IntakePlanner.swift
//  MaryVoice
//
//  WHAT: Pure decision — addressed turn vs room memory vs hold.
//  IN:   VoicePipeline+ContinuousHearing / TranscriptSegment
//  OUT:  admit (Brain turn) | remember (.heardSpeech) | hold
//
//  Sibling of AmendPlanner. PIN: never competes with the VAD path.
//

import Foundation

public enum IntakePlanner {

    /// One finalized (or volatile) span from the continuous recognizer.
    public struct Segment: Sendable, Equatable {
        public var text: String
        /// Recognizer will not revise these words. Not the same as "speaker finished".
        public var isFinalized: Bool
        /// Quiet since the span ended.
        public var silenceAfter: TimeInterval

        public init(text: String, isFinalized: Bool, silenceAfter: TimeInterval) {
            self.text = text
            self.isFinalized = isFinalized
            self.silenceAfter = silenceAfter
        }
    }

    public struct Situation: Sendable {
        public var segment: Segment
        /// Her own speech coming back through the microphone.
        public var selfSpeaking: Bool
        /// Acoustic path already owns this speech (utterance / transcribing / answering).
        public var acousticPathBusy: Bool
        /// She answered recently enough that a follow-on needs no wake word.
        public var recentlyAddressed: Bool

        public init(
            segment: Segment,
            selfSpeaking: Bool = false,
            acousticPathBusy: Bool = false,
            recentlyAddressed: Bool = false
        ) {
            self.segment = segment
            self.selfSpeaking = selfSpeaking
            self.acousticPathBusy = acousticPathBusy
            self.recentlyAddressed = recentlyAddressed
        }
    }

    /// Why nothing happened. Named so "did nothing" vs "never fed" stay distinct.
    public enum Reason: String, Sendable, Equatable, CaseIterable {
        case empty
        /// Her own voice. Transcribing it back would let her answer herself.
        case selfSpeech
        /// Volatile — the recognizer may still rewrite these words.
        case volatile
        /// Finalized, but the speaker has not stopped.
        case midThought
        /// A fragment, not an utterance.
        case tooBrief
    }

    public enum Verdict: Sendable, Equatable {
        /// Meant for her — hand it to the turn pipeline unchanged.
        case admit(String)
        /// Said in the room — deposit as short-term memory. Consumer: .heardSpeech.
        case remember(String)
        case hold(Reason)
    }

    public struct Tuning: Sendable, Equatable {
        /// Word-boundary match against lowercased, punctuation-free form.
        /// PIN: "Mary" sits inside "summary"/"primary" — `contains` would false-positive.
        public var wakeWords: [String] = ["mary"]
        /// Quiet after a finalized span before the thought counts as finished.
        /// PIN: longer than the acoustic hangover (850 ms) — this path is not the turn loop.
        public var completionSilence: TimeInterval = 1.2
        /// Below this a span is a fragment.
        public var minimumWords: Int = 2

        public init() {}
        public static let standard = Tuning()
    }

    /// Ladder — cheapest and most absolute first.
    public static func verdict(
        _ situation: Situation, tuning: Tuning = .standard
    ) -> Verdict {
        let raw = situation.segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .hold(.empty) }

        // First, unconditionally — her own TTS must never become a turn.
        guard !situation.selfSpeaking else { return .hold(.selfSpeech) }

        guard situation.segment.isFinalized else { return .hold(.volatile) }

        let words = raw.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= tuning.minimumWords else { return .hold(.tooBrief) }

        guard situation.segment.silenceAfter >= tuning.completionSilence else {
            return .hold(.midThought)
        }

        // Addressed? Wake word or live follow-on. Else remember.
        let addressed = situation.recentlyAddressed || namesHer(raw, tuning: tuning)
        guard addressed else { return .remember(raw) }

        // Acoustic path gets first refusal — do not submit the same speech twice.
        guard !situation.acousticPathBusy else { return .remember(raw) }

        return .admit(raw)
    }

    /// Word-boundary match over letters-and-spaces. Same normalization as `bareDecision`.
    public static func namesHer(_ text: String, tuning: Tuning = .standard) -> Bool {
        let normalized = text.lowercased()
            .filter { $0.isLetter || $0.isWhitespace || $0.isNumber }
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !normalized.isEmpty else { return false }
        let joined = " " + normalized.joined(separator: " ") + " "
        return tuning.wakeWords.contains { wake in
            let needle = " " + wake.lowercased() + " "
            return joined.contains(needle)
        }
    }
}
