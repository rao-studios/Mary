//
//  EditIntentClassifier.swift
//  MaryBrain
//
//  Deterministic "is this a REVISION of something already written, or is it
//  LIVE COMPOSITION?" — the switch that decides whether a turn reaches for a
//  passage binding or for `type_at_cursor`.
//
//  THE FAILURE THIS FIXES (live capture, in Pages). The user said "replace
//  the Purpose section with the tighter version". She called
//  `type_at_cursor`, typed the new prose wherever the caret happened to sit,
//  and left the Purpose section standing. Their verdict: "intended for live
//  writing behavior rather than revision behavior."
//
//  Two mechanisms conspired. `NamedPartClassifier.connectors` carried bare
//  "with", so the pre-read captured "the tighter version" — the REPLACEMENT —
//  and searched the document for prose that by definition was not in it yet.
//  And nothing anywhere named the shape of the sentence, so the Skill execution lane saw
//  an imperative with no located target and typed. This file is the second
//  half of that fix: `NamedPartClassifier` gave up bare "with" in Phase A
//  precisely so this classifier could own the payload shape (read the comment
//  on `connectors` — it names this file by name), and here the split is
//  non-greedy, target before payload.
//
//  THE SECOND LIVE FAILURE, and it was this file's `^` anchors meeting an
//  ordinary human sentence. "Yeah yeah exactly can you reword the whole thing
//  for me." The Skill execution lane read it the way a person does and `REPLACE_PASSAGE`
//  landed correctly — but `stripAddress` peeled only "hey"/"mary"/"ok"/
//  "okay", so "Yeah" led the string, no shape matched, and `intent` came back
//  nil. Every gate went dark and the voice improvised a permission question
//  about an edit that had already happened: "I'm on it, but I need a quick
//  clarification — do you mean the whole document, or the Background section?"
//  `stripPreamble` is the fix here; the load-bearing half is `EditReport` being
//  re-keyed off a landed edit, because peeling this particular sentence yields
//  the target "whole thing", which no document contains.
//
//  MECHANICAL GATE, NOT A PARAGRAPH OF DOCTRINE. This codebase has twice
//  replaced an instruction the model ignored with a mechanism it cannot
//  ignore — `ActionClassifier`, `bareDecision`, `hasPendingSkillConfirmation` were each
//  introduced that way. A prompt line asking her to prefer `replace_passage`
//  is necessary and insufficient; a classifier that answers before the model
//  is consulted is what makes the caret write impossible rather than
//  discouraged.
//
//  BIAS: conservative, like `ActionClassifier` and unlike
//  `NamedPartClassifier`. A false positive here is not a wasted read — it
//  turns a sentence the user meant to have TYPED into an overwrite of
//  something they already wrote. That asymmetry is why every shape is anchored
//  at `^` (a revision verb must LEAD), why a "?" anywhere vetoes, and above
//  all why `add`/`write`/`type` with NO anchor clause yields nil. "write a
//  paragraph about the budget" must keep behaving exactly as it does today.
//  Live composition is not a gap in this classifier; it is the half of the
//  world this classifier is forbidden to touch.
//
//  ONE VOCABULARY, TWO CONSUMERS. `partNouns`, `numberedNouns`,
//  `spokenNumbers`, `clean` and `namesAmbientSource` are
//  `NamedPartClassifier`'s and are used from there, not copied. The read side
//  and the write side must agree on what a "section" is, and the only way to
//  guarantee that is for there to be one list.
//

import Foundation

/// A revision the user asked for, in the only vocabulary a passage editor can
/// act on: what to do, WHICH passage, and what to put there.
///
/// PUBLIC, UNLIKE THE CLASSIFIER THAT PRODUCES IT — and the asymmetry is the
/// point. `EditIntentClassifier` stays internal beside `ActionClassifier`,
/// because deciding what a sentence IS is the brain's own business. But the
/// intent itself crosses a public seam twice: `AbilityDispatching`'s
/// `locatePassage(_:)` requirement and `AbilityRuntime`'s witness for it, both
/// of which are `public` and neither of which can name an internal type
/// ("method cannot be declared public because its parameter uses an internal
/// type" — the tree did not compile with this left `internal`).
public struct EditIntent: Equatable, Sendable {

    public enum Shape: String, Equatable, Sendable {
        case replace, insert, delete, move
    }

    /// Where an insertion or a move lands relative to its target.
    public enum Anchor: String, Equatable, Sendable {
        case before, after, into
    }

    public var shape: Shape

    /// ORDERED CANDIDATES, BEST FIRST — deliberately a LIST and never one
    /// guess. The user's standing rule for an ambiguous target is "read wider,
    /// then decide alone", and a resolver handed a single string cannot widen:
    /// it either hits or it misses, and a miss becomes a silent no-op or —
    /// exactly the shipped bug — a write at the caret. Every candidate here is
    /// another rung the resolver gets to try before it is allowed to give up.
    public var target: [String]

    /// The prose to write, VERBATIM. See `EditIntentClassifier.payload` for
    /// why nothing in this file is allowed to touch it.
    public var payload: String?

    public var anchor: Anchor?

    /// Where a `.move` lands, in the same ordered-candidate form as `target`.
    public var destination: [String]

    /// THE TARGET IS "THE ONE WE WERE JUST TALKING ABOUT" — "reword it",
    /// "tighten that paragraph", "polish this".
    ///
    /// THE FAILURE THIS FIXES, traced in the Routes pane across five turns.
    /// Mary found the passage correctly on the FIRST turn and handed it back
    /// with a handle. Every turn after that asked her to change it, and none of
    /// them classified as a revision — because the target reduced to a pronoun,
    /// `candidates(forTarget:)` rightly refuses to hand a `find` a pronoun, and
    /// `replaceIntent`'s `guard !target.isEmpty` returned nil. The turns fell
    /// through to `perceive` and finally to `converse`, so nothing located, no
    /// veto armed, no report fired, and Lane A filled the silence with "I'm on
    /// it" over an edit that never happened. The user: "It should have
    /// committed to the action right away once it found it."
    ///
    /// It is a FLAG rather than a magic target string because the resolution is
    /// not the classifier's to make: this file is pure, and which passage "it"
    /// means is a fact about the handle ledger. `AbilityRuntime.locatePassage`
    /// answers it with the most recently minted passage in the focused world —
    /// which is, exactly, the one she just showed them.
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

    /// Verbs that mean "there is already text here and I want it different".
    /// Every one of them presupposes an existing passage, which is what
    /// separates them from `insertVerbs` below: you cannot tighten, polish or
    /// reword something that has not been written yet.
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

    /// Verbs that mean "put new words in". ON THEIR OWN THESE ARE
    /// COMPOSITION, NOT REVISION — they only become an edit intent when an
    /// anchor clause names something already on the page to sit beside. That
    /// requirement is this file's single most important line of defence; see
    /// `insertIntent`.
    public static let insertVerbs = [
        "insert", "append", "add", "put", "write", "type",
    ]

    public static let moveVerbs = ["move", "relocate", "shift"]

    /// What sits between the TARGET and the PAYLOAD in a replacement.
    ///
    /// THE ENTIRE FIX FOR THE LIVE BUG IS THE NON-GREEDY MATCH BEFORE THIS
    /// LIST. `<verb> (.+?) <split> (.+)` takes the SHORTEST target, so
    /// "replace the Purpose section with the tighter version" splits into
    /// target "the Purpose section" / payload "the tighter version" — the
    /// exact inversion of what `NamedPartClassifier` used to do with the same
    /// sentence. A greedy match, or a match that scanned from the right, would
    /// reproduce the shipped bug with a different regex.
    ///
    /// The cost, stated honestly: a target that itself contains one of these
    /// words ("replace the section for beginners with …") splits early and
    /// takes too little. That is the safe direction to be wrong in — a target
    /// that is too small misses and widens, while a target that is too large
    /// overwrites text the user never mentioned.
    public static let splitWords = ["to say", "to read", "with", "into", "using", "for"]

    /// Anchor phrases, LONGEST FIRST. "under" is a prefix of "underneath", and
    /// while the trailing `\s+` in the pattern already prevents the short one
    /// from stealing the match, ordering says so without depending on a
    /// backtrack to be correct.
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

    /// The one anchor phrase that changes the SHAPE rather than the position.
    /// "put a summary in place of the intro" is a replacement wearing an
    /// insert verb; treating it as an insert would leave the intro standing,
    /// which is the shipped failure again by another door.
    public static let inPlaceOfPhrase = "in place of"

    /// Leading forms of address, stripped before anything is matched — the
    /// same loop shape and the same four words as
    /// `ActionClassifier.isActionCommand`, because "mary, replace the
    /// Purpose section…" is the same command as "replace the Purpose
    /// section…" and only one of them should have to be spelled here.
    public static let addressWords: Set<String> = ["hey", "mary", "ok", "okay"]

    /// BACKCHANNEL — the noises a person makes on the way into a sentence, and
    /// the reason this classifier missed a live revision entirely.
    ///
    /// THE FAILURE THIS FIXES, in the user's own words: "Yeah yeah exactly can
    /// you reword the whole thing for me." `stripAddress` peeled only the four
    /// address words, so "Yeah" survived, and every shape below is `^`-anchored
    /// — a revision verb must LEAD. Three words of backchannel unanchored the
    /// whole classifier: `intent` came back nil, all four gates went dark, and
    /// Lane A improvised a permission question over an edit that had already
    /// landed. None of these words carries meaning about WHAT to do; they are
    /// the sound of a person agreeing with themselves before they ask.
    public static let backchannelWords: Set<String> = [
        "yeah", "yep", "right", "exactly", "sure", "alright", "so", "well",
    ]

    /// CONFIRMATION PHRASES — the sound of a person accepting what Mary just
    /// found, immediately before telling her what to do with it.
    ///
    /// THE FAILURE THIS FIXES, from the same five-turn trace as
    /// `EditIntent.isAnaphoric`: "Yeah that's the one can you reword that
    /// paragraph". `backchannelWords` peeled "yeah" and stopped, leaving
    /// "that's the one…" in front — and every shape below is `^`-anchored, so
    /// the revision verb no longer led and the whole classifier went dark.
    /// Identical in kind to the backchannel bug one field up, and it appears
    /// in exactly the position that matters most: the turn right after a
    /// successful find, when the user is confirming and instructing in one
    /// breath.
    ///
    /// Peeled as WHOLE PHRASES, like `requestFrames` and for the same reason —
    /// "that's the one" is a confirmation, while "that's the wrong paragraph"
    /// is a correction that must reach the shapes intact.
    ///
    /// Spelled in LETTER RUNS, which is how `nextWord` tokenises: an
    /// apostrophe is not a letter, so "that's" arrives as "that" then "s" and
    /// the contraction and the bare spelling share one entry.
    public static let confirmationPhrases: [[String]] = [
        ["that", "s", "the", "one"], ["thats", "the", "one"],
        ["that", "s", "it"], ["thats", "it"],
        ["this", "one"], ["that", "one"],
    ]

    /// POLITE REQUEST FRAMES, peeled as WHOLE PHRASES and never as words.
    ///
    /// THE BOUND IS THE POINT. "Can you tighten the intro" is a request, and
    /// "what did you replace" is a question about the past — both contain
    /// "you", both open with something in `ActionClassifier.questionOpeners`,
    /// and only the first is an instruction. A "revision verb anywhere" rule
    /// would catch them both; a two-word frame catches exactly the one, because
    /// "what did you" is not one of these phrases and so nothing is peeled and
    /// the question opener still vetoes it.
    ///
    /// Each frame may be followed by "please" ("could you please reword this"),
    /// which is the only place a bare "please" is peeled — a politeness word
    /// that can appear anywhere is not evidence of anything.
    public static let requestFrames: [[String]] = [
        ["can", "you"], ["could", "you"], ["would", "you"],
    ]

    /// The one word allowed to trail a request frame. See `requestFrames`.
    public static let politeTail = "please"

    /// THE CANDIDATE CEILING. Three is the ladder's own arithmetic rather than
    /// a round number: rung 4's heading form, plus rung 3's cleaned tail (or
    /// rung 2's container), plus one runner-up is the widest a single
    /// utterance can produce that is still worth a `find`. Anything past that
    /// is `clean`'s five-word clip of a phrase already in the list, and a
    /// resolver that tries it has stopped widening and started guessing.
    public static let maxCandidates = 3

}
