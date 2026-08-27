//
//  PassageResolver.swift
//  MaryBrain
//
//  IS THIS PASSAGE STILL WHERE IT WAS? The staleness half of the contract, and
//  the half that has to be willing to say no.
//
//  A handle is minted with a body hash and a range. Between minting it and
//  using it the document is LIVE: the user types, Mary's own previous edit
//  lands, autosave reflows. The range that was right thirty seconds ago now
//  points at somebody else's sentence — and writing to it would replace text
//  the user never named, silently, with no error anywhere. That is the failure
//  mode this file exists to make impossible.
//
//  THE RULE, in one line: **re-locate by TEXT, or refuse.** Never adjust a
//  stored integer, never "clamp to the nearest paragraph", never accept the
//  closest of several. The stored range is a hint that breaks ties; it is
//  never the thing being trusted.
//
//  Pure — a passage and a body in, an outcome out. The runner does the I/O.
//

import Foundation

/// What happened when the passage was re-located.
public enum AnchorOutcome: Sendable, Equatable {
    /// The body hash matches: the document is byte-for-byte what it was when
    /// the passage was minted, so the stored range is still exactly right.
    /// Nothing needs searching.
    case exact
    /// The body changed, and the passage's words appear EXACTLY ONCE. This is
    /// the common and important case: she edited paragraph three, the user
    /// asks about paragraph nine, and every offset below the edit moved.
    /// `drift` is how far, signed — positive if the passage moved later in the
    /// document.
    case reanchored(Range<Int>, drift: Int)
    /// The words are not in the body at all. Somebody deleted or rewrote it.
    case gone
    /// The words appear more than once and the stored range does not decide
    /// between them by a clear enough margin. Refused rather than guessed —
    /// see `driftMargin`.
    case ambiguousAfterDrift(count: Int)

    /// Did we end up with a range we are willing to write to?
    public var isResolved: Bool {
        switch self {
        case .exact, .reanchored: return true
        case .gone, .ambiguousAfterDrift: return false
        }
    }
}

public enum PassageResolver {

    /// HOW MUCH CLOSER the nearest occurrence must be than the next one before
    /// "nearest to where it used to be" is evidence rather than a coin toss.
    ///
    /// `PassageWidening.maxSpan` — the largest single edit this system will
    /// ever make. One edit of ours can slide everything after it by at most
    /// that many characters, so an occurrence that has come within that
    /// distance of the old position could BE the one that slid there. Only
    /// past it is proximity an argument.
    ///
    /// It bounds OUR edits, not the user's typing, which is unbounded — so
    /// this is a floor on the honest answer, never a proof. That is the right
    /// direction to be wrong in: it refuses more often than it must, and the
    /// thing it refuses to do is overwrite the wrong paragraph.
    public static var driftMargin: Int { PassageWidening.maxSpan }

    /// Re-locate `passage` in the body as it now stands.
    public static func anchor(_ passage: Passage, in body: String) -> AnchorOutcome {
        // THE FAST, TOTAL ANSWER. Equal hashes mean the whole body is
        // identical to the one the range was measured against, so the range is
        // correct by construction — there is nothing a search could add.
        if ContentUndoStore.hash(body) == passage.bodyHash { return .exact }

        guard !passage.text.isEmpty else { return .gone }
        let hits = PassageWidening.occurrences(of: passage.text, in: body)
        switch hits.count {
        case 0:
            return .gone
        case 1:
            let found = hits[0]
            return .reanchored(found, drift: found.lowerBound - passage.range.lowerBound)
        default:
            // Nearest the OLD position, but only if the runner-up is clearly
            // further. `sorted` by distance is stable, so equal distances
            // resolve to document order and the comparison below still refuses
            // them (a gap of 0 is never >= the margin).
            let byDistance = hits.sorted {
                abs($0.lowerBound - passage.range.lowerBound)
                    < abs($1.lowerBound - passage.range.lowerBound)
            }
            let nearest = abs(byDistance[0].lowerBound - passage.range.lowerBound)
            let next = abs(byDistance[1].lowerBound - passage.range.lowerBound)
            guard next - nearest >= driftMargin else {
                return .ambiguousAfterDrift(count: hits.count)
            }
            let found = byDistance[0]
            return .reanchored(found, drift: found.lowerBound - passage.range.lowerBound)
        }
    }

    /// The range to write to, or nil if the outcome refuses.
    public static func range(_ outcome: AnchorOutcome, of passage: Passage) -> Range<Int>? {
        switch outcome {
        case .exact:                     return passage.range
        case .reanchored(let range, _):  return range
        case .gone, .ambiguousAfterDrift: return nil
        }
    }

    /// The spoken refusal, or nil when the outcome resolved.
    ///
    /// A REFUSAL HERE IS `ok: false` AT THE RECIPE, and NOT `foundNothing`.
    /// The distinction is load-bearing and the two flags are not
    /// interchangeable:
    ///
    ///   - `foundNothing` is reserved, by its own doc comment, for a READ that
    ///     looked and did not find. It carries `ok: true` because the read
    ///     genuinely ran and this is its honest answer; what it denies is
    ///     AUTHORITY, so the miss is never recited to the user as though it
    ///     were the passage.
    ///   - This is not a read. The user asked for a CHANGE and the change did
    ///     not happen. The turn's "silent success, SPOKEN failure" rule is
    ///     exactly right about it: they must hear that their edit did not
    ///     land, and `ok: false` is the only flag that makes them hear it.
    ///
    /// Dressing this as `foundNothing` would produce the worst available
    /// outcome — an unmade edit, reported as an answer, in silence.
    public static func refusal(_ outcome: AnchorOutcome, for passage: Passage) -> String? {
        switch outcome {
        case .exact, .reanchored:
            return nil
        case .gone:
            return driftedSentence(
                opening: passage.opening(), document: passage.documentTitle)
        case .ambiguousAfterDrift(let count):
            // NO "BE MORE SPECIFIC". Same reading as `driftedSentence`'s: it is
            // an imperative, and the model reads an imperative in a Skill result
            // as a thing to carry out. What the user actually needs is the ONE
            // fact that would settle it, stated.
            return "\"\(passage.opening())\" appears \(count) times in "
                + "\(passage.documentTitle) now and it has moved since I read it, "
                + "so I can't tell which one you mean. The heading above the one "
                + "you want would settle it."
        }
    }

    /// THE DRIFT SENTENCE, WRITTEN DOWN ONCE — and the wording is a correction,
    /// not a polish.
    ///
    /// WHAT IT REPLACED, and why that sentence could not stay:
    /// "I couldn't find \"…\" to change — it isn't in <doc> any more. Point me
    /// at it again and I'll pick it up." Three things wrong with it, each
    /// independently sufficient.
    ///
    ///  1. IT ASSERTED ABSENCE, and this tree's own prompt doctrine bans that
    ///     in the same breath: "NEVER tell the user that a passage, a section or
    ///     a subject isn't in their work." The voice obeyed the doctrine while a
    ///     Skill handed her the sentence to say, so the ban was enforced
    ///     everywhere except the one place that could produce the claim.
    ///  2. IT WAS OFTEN FALSE. `.gone` means the STORED WORDS do not appear —
    ///     which is exactly what a user typing inside a held passage produces.
    ///     The part is right there, with three more words in it.
    ///  3. "POINT ME AT IT AGAIN" IS AN ERRAND. A Skill-invoking model reads an
    ///     imperative in a Skill result as an instruction it can carry out, and
    ///     the live transcript shows `OPEN_IN_PAGES` firing off the back of a
    ///     passage refusal that never mentions Pages. See
    ///     `PassageEditRunner.noDocumentMessage`, where the same reading was
    ///     traced, and the tree's own precedent: "A SIZE, NOT AN ERRAND … which
    ///     a Skill-invoking model takes as fetch it."
    ///
    /// What is left says the one thing that is true whoever moved it — the words
    /// changed since she picked them up — and then states the condition that
    /// would resolve it instead of ordering anybody to do anything.
    ///
    /// ONE IMPLEMENTATION, HERE. `PassageWriteError.passageGone` used to carry a
    /// character-for-character copy of the old sentence, so the transcript could
    /// not tell "the words are not in the document" from "the words are in the
    /// document and my writing surface could not reach them" — which is
    /// precisely the pair that produced "the insertions didn't take — the
    /// passage wasn't found" about a document `pages_body` had just read in
    /// full. That case now speaks for itself and this is the only drift
    /// sentence in the tree.
    public static func driftedSentence(opening: String, document: String) -> String {
        "\"\(opening)\" has changed in \(document) since I picked it up, so the words "
            + "I'm holding aren't the words that are there now. A heading, or the part "
            + "as it reads today, is enough for me to pick it up again."
    }
}
