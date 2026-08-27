//
//  IntakePlanner.swift
//  MaryVoice
//
//  WHAT BECOMES A TURN, AND WHAT MERELY BECOMES A MEMORY — the pure decision
//  in front of continuous hearing. The direct sibling of `AmendPlanner` in this
//  directory, and the same shape: a caseless enum, an `Equatable` verdict, no
//  clock, no actor.
//
//  NOT NAMED "ADMISSION". That word is already load-bearing in this tree and
//  means WHICH REALMS ENTER PERCEPTION — the PINNABLE ⟺ OBSERVABLE rule,
//  `AmbientRanker.admittedRealmMentions`, `route.admitsHeldFact`. A second,
//  unrelated meaning of it is precisely the drift the codebase argues against.
//  `.admit` survives as a verdict verb, where it cannot be mistaken.
//
//  IT SEPARATES THREE QUESTIONS THE CURRENT VAD CONFLATES INTO ONE SILENCE
//  THRESHOLD:
//
//  1. IS THIS ADDRESSED TO ME? The gate that makes always-on tolerable. A
//     false positive here does not produce a bad reply — it ACTS. So it is
//     conservative by construction and everything unmatched falls through to
//     `.remember`, which costs nothing and is never wrong.
//  2. IS THIS COMPLETE? A finalized segment plus a silence tail, rather than
//     the flat 850 ms hangover that cuts "add a reminder to… call mom" in
//     half. Note these are different claims: the recognizer finalizing a range
//     means it will not REVISE those words, not that the speaker has finished
//     the thought.
//  3. IS IT WORTH COGNITION? Deliberately NOT answered here. `bareDecision`
//     and `bareCorrection` already answer it downstream, without the model,
//     over a closed vocabulary — and they run inside the turn where the
//     pending-confirmation and routine state they depend on actually exists.
//     Re-asking here would be a second spelling of a decision that is already
//     made well.
//
//  AND IT NEVER COMPETES WITH THE VAD PATH. The existing acoustic loop remains
//  the only thing that opens an utterance and submits a turn in the ordinary
//  case. This planner rides ALONGSIDE it: its `.remember` arm is pure gain,
//  and its `.admit` arm is offered only when the acoustic path is not already
//  handling the same speech. Continuous hearing is additive or it is a
//  regression.
//

import Foundation

public enum IntakePlanner {

    /// One finalized (or volatile) span from the continuous recognizer.
    public struct Segment: Sendable, Equatable {
        public var text: String
        /// The recognizer will not revise these words. NOT the same as the
        /// speaker having finished — see the header.
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
        /// The acoustic path already owns this speech — it has an utterance
        /// open, is transcribing one, or is answering one.
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

    /// WHY NOTHING HAPPENED. Named, like every other silence in AmbientVoice —
    /// "the transcript did nothing" and "the transcript was never fed" look
    /// identical from outside, and they are opposite bugs.
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
        /// Said in the room — deposit it as short-term memory and say nothing.
        case remember(String)
        case hold(Reason)
    }

    public struct Tuning: Sendable, Equatable {
        /// Matched at a WORD BOUNDARY against a lowercased, punctuation-free
        /// form, so "Mary," and "mary?" both count and "summary" does not.
        ///
        /// THE BOUNDARY IS LOAD-BEARING FOR THIS PARTICULAR NAME. "Mary" sits
        /// inside a pile of ordinary English — summary, primary, customary,
        /// rosemary, infirmary — and two of those are words people say TO an
        /// assistant. "Give me a summary" must never read as her name, so a
        /// `contains` here would be a bug with a daily false positive rather
        /// than a rare one.
        public var wakeWords: [String] = ["mary"]
        /// How long a finalized span must be followed by quiet before the
        /// thought counts as finished.
        ///
        /// LONGER THAN THE ACOUSTIC HANGOVER (850 ms) on purpose: that number
        /// has to be short because it gates the whole turn loop's
        /// responsiveness, and this one does not — a remembered line is in no
        /// hurry, and an admitted one is better complete than fast.
        public var completionSilence: TimeInterval = 1.2
        /// Below this a span is a fragment — a cough transcribed as "uh", a
        /// half word clipped by a pause.
        public var minimumWords: Int = 2

        public init() {}
        public static let standard = Tuning()
    }

    /// The ladder — cheapest and most absolute first, in `AmendPlanner`'s
    /// idiom of flat early returns.
    public static func verdict(
        _ situation: Situation, tuning: Tuning = .standard
    ) -> Verdict {
        let raw = situation.segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .hold(.empty) }

        // FIRST, AND UNCONDITIONALLY. Her own TTS coming back through the mic
        // is the one input that can make her answer herself, and no later rung
        // can undo having believed it.
        guard !situation.selfSpeaking else { return .hold(.selfSpeech) }

        guard situation.segment.isFinalized else { return .hold(.volatile) }

        let words = raw.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= tuning.minimumWords else { return .hold(.tooBrief) }

        guard situation.segment.silenceAfter >= tuning.completionSilence else {
            return .hold(.midThought)
        }

        // ADDRESSED? Only a wake word or a live follow-on window earns the
        // turn pipeline. Everything else is remembered, which is never wrong.
        let addressed = situation.recentlyAddressed || namesHer(raw, tuning: tuning)
        guard addressed else { return .remember(raw) }

        // …AND THE ACOUSTIC PATH GETS FIRST REFUSAL. It is the only thing that
        // opens utterances today; admitting here while it holds the same
        // speech would submit the turn twice. Remembering it instead costs
        // nothing and keeps continuous hearing strictly additive.
        guard !situation.acousticPathBusy else { return .remember(raw) }

        return .admit(raw)
    }

    /// Word-boundary match over a lowercased, letters-and-spaces form — the
    /// same normalization `bareDecision` uses, so "Mary," matches and
    /// "summary" does not.
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
