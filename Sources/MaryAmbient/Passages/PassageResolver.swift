//
//  PassageResolver.swift
//  MaryBrain
//
//  WHAT: Is this passage still where it was? The staleness half of the contract.
//  IN:   Passage (body hash + range)
//  OUT:  relocate or refuse
//  PIN:  Re-locate by text, or refuse. Stored range is a tie-break, never trusted.
//

import Foundation

/// What happened when the passage was re-located.
public enum AnchorOutcome: Sendable, Equatable {
    /// The body hash matches: the document is byte-for-byte what it was when
    /// the passage was minted, so the stored range is still exactly right.
    /// Nothing needs searching.
    case exact
    /// The body changed, and the passage's words appear EXACTLY ONCE. This is the common and
    /// important case: she edited paragraph three, the user asks about paragraph nine, and
    /// every offset below the edit moved.
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

    /// HOW MUCH CLOSER the nearest occurrence must be than the next one before "nearest to
    /// where it used to be" is evidence rather than a coin toss. `PassageWidening.maxSpan`.
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
            // Nearest the OLD position, but only if the runner-up is clearly further. `sorted` by
            // distance is stable, so equal distances resolve to document order and the comparison
            // below still refuses them (a gap of 0 is never >= the margin).
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

    /// The spoken refusal, or nil when the outcome resolved. A REFUSAL HERE IS `ok: false` AT
    /// THE RECIPE, and NOT `foundNothing`. The distinction is load-bearing and the two flags
    /// are not interchangeable:
    public static func refusal(_ outcome: AnchorOutcome, for passage: Passage) -> String? {
        switch outcome {
        case .exact, .reanchored:
            return nil
        case .gone:
            return driftedSentence(
                opening: passage.opening(), document: passage.documentTitle)
        case .ambiguousAfterDrift(let count):
            // NO "BE MORE SPECIFIC". Same reading as `driftedSentence`'s: it is an imperative, and the
            // model reads an imperative in a Skill result as a thing to carry out.
            return "\"\(passage.opening())\" appears \(count) times in "
                + "\(passage.documentTitle) now and it has moved since I read it, "
                + "so I can't tell which one you mean. The heading above the one "
                + "you want would settle it."
        }
    }

    /// What is left says the one thing that is true whoever moved it — the words changed since
    /// she picked them up — and then states the condition that would resolve it instead of
    /// ordering anybody to do anything.
    public static func driftedSentence(opening: String, document: String) -> String {
        "\"\(opening)\" has changed in \(document) since I picked it up, so the words "
            + "I'm holding aren't the words that are there now. A heading, or the part "
            + "as it reads today, is enough for me to pick it up again."
    }
}
