//
//  EditIntentClassifier.swift
//  MaryBrain
//
//  WHAT: Is this a revision of something already written, or live composition?
//  OUT:  passage binding vs type_at_cursor. Splits: +EntryAndClauses / +Payload / +Shapes
//  PIN:  Shape of the sentence is the gate — "replace X with Y" must not type at the caret.
//

import Foundation

/// A revision the user asked for, in the only vocabulary a passage editor can act on: what
/// to do, WHICH passage, and what to put there. PUBLIC, UNLIKE THE CLASSIFIER THAT PRODUCES
/// IT.
public struct EditIntent: Equatable, Sendable {

    public enum Shape: String, Equatable, Sendable {
        case replace, insert, delete, move
    }

    /// Where an insertion or a move lands relative to its target.
    public enum Anchor: String, Equatable, Sendable {
        case before, after, into
    }

    public var shape: Shape

    /// ORDERED CANDIDATES, BEST FIRST — deliberately a LIST and never one guess.
    public var target: [String]

    /// The prose to write, VERBATIM. See `EditIntentClassifier.payload` for
    /// why nothing in this file is allowed to touch it.
    public var payload: String?

    public var anchor: Anchor?

    /// Where a `.move` lands, in the same ordered-candidate form as `target`.
    public var destination: [String]

    /// THE TARGET IS "THE ONE WE WERE JUST TALKING ABOUT".
    public var isAnaphoric: Bool

    public init(
        shape: Shape,
        target: [String],
        payload: String? = nil,
        anchor: Anchor? = nil,
        destination: [String] = [],
        isAnaphoric: Bool = false
    ) {
        self.shape = shape
        self.target = target
        self.payload = payload
        self.anchor = anchor
        self.destination = destination
        self.isAnaphoric = isAnaphoric
    }
}


public enum EditIntentClassifier {

    // MARK: - Vocabulary

    /// Verbs that mean "there is already text here and I want it different". Every one of them
    /// presupposes an existing passage, which is what separates them from `insertVerbs` below:
    /// you cannot tighten, polish or reword something that has not been written yet.
    public static let replaceVerbs = [
        "replace", "swap", "substitute", "rewrite", "reword", "rephrase",
        "change", "update", "revise", "tighten", "shorten", "condense",
        "expand", "polish", "correct", "fix",
    ]

    /// Longest first, so "get rid of the intro" cannot settle for a prefix and
    /// hand "rid of the intro" to the target ladder.
    public static let deleteVerbs = [
        "get rid of", "take out", "cut out", "strike out",
        "delete", "remove", "cut", "drop", "strike",
    ]

    /// Verbs that mean "put new words in". ON THEIR OWN THESE ARE COMPOSITION, NOT REVISION —
    /// they only become an edit intent when an anchor clause names something already on the
    /// page to sit beside.
    public static let insertVerbs = [
        "insert", "append", "add", "put", "write", "type",
    ]

    public static let moveVerbs = ["move", "relocate", "shift"]

    /// What sits between the TARGET and the PAYLOAD in a replacement. THE ENTIRE FIX FOR THE
    /// LIVE BUG IS THE NON-GREEDY MATCH BEFORE THIS LIST.
    public static let splitWords = ["to say", "to read", "with", "into", "using", "for"]

    /// Anchor phrases, LONGEST FIRST. "under" is a prefix of "underneath", and while the
    /// trailing `\s+` in the pattern already prevents the short one from stealing the match,
    /// ordering says so without depending on a backtrack to be correct.
    public static let anchorVocabulary: [(phrase: String, anchor: EditIntent.Anchor)] = [
        ("at the start of", .before),
        ("at the top of", .before),
        ("at the end of", .after),
        ("at the bottom of", .after),
        ("underneath", .after),
        ("inside", .into),
        ("before", .before),
        ("above", .before),
        ("after", .after),
        ("below", .after),
        ("under", .after),
        ("into", .into),
    ]

    /// The one anchor phrase that changes the SHAPE rather than the position. "put a summary in
    /// place of the intro" is a replacement wearing an insert verb; treating it as an insert
    /// would leave the intro standing, which is the shipped failure again by another door.
    public static let inPlaceOfPhrase = "in place of"

    /// Leading forms of address, stripped before anything is matched.
    public static var addressWords: Set<String> { RoutingLexicon.addressWords }

    /// BACKCHANNEL — the noises a person makes on the way into a sentence, and the reason this
    /// classifier missed a live revision entirely.
    public static let backchannelWords: Set<String> = [
        "yeah", "yep", "right", "exactly", "sure", "alright", "so", "well",
    ]

    /// CONFIRMATION PHRASES — the sound of a person accepting what Mary just found, immediately
    /// before telling her what to do with it. Peeled as WHOLE PHRASES, like `requestFrames` and
    /// for the same reason — "that's the one" is a confirmation, while "that's the wrong.
    public static let confirmationPhrases: [[String]] = [
        ["that", "s", "the", "one"], ["thats", "the", "one"],
        ["that", "s", "it"], ["thats", "it"],
        ["this", "one"], ["that", "one"],
    ]

    /// POLITE REQUEST FRAMES, peeled as WHOLE PHRASES and never as words. THE BOUND IS THE
    /// POINT. "Can you tighten the intro" is a request, and "what did you replace" is a
    /// question about the past.
    public static let requestFrames: [[String]] = [
        ["can", "you"], ["could", "you"], ["would", "you"],
    ]

    /// The one word allowed to trail a request frame. See `requestFrames`.
    public static let politeTail = "please"

    /// THE CANDIDATE CEILING. Three is the ladder's own arithmetic rather than a round number:
    /// rung 4's heading form, plus rung 3's cleaned tail (or rung 2's container), plus one
    /// runner-up is the widest a single utterance can produce that is still worth a `find`.
    public static let maxCandidates = 3

}
