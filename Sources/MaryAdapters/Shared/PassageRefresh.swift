//
//  PassageRefresh.swift
//  MaryBrain
//
//  HANDLES THAT SURVIVE HER OWN KEYSTROKES. The third of the three live
//  failures, and the only one whose cause is that a write verb skipped the
//  contract entirely.
//
//  WHAT HAPPENED. She typed at the cursor, inside a passage the conversation
//  was calling `[S1]`. The very next request was a whole-passage replace
//  against that same handle, and she answered "it isn't in the document any
//  more." It was. Her own keystrokes had landed BETWEEN the stored words, so
//  `PassageResolver.anchor` searched for them, found zero occurrences,
//  returned `.gone`, and `[S1]` named something that had ceased to exist one
//  action after she was told about it. `type_at_cursor` is the only write verb
//  in the tree that touches no `PassageRegistry`, no `ContentUndoStore` and no
//  ambient fact — every other one maintains the invariant on its way past.
//
//  WHY A PLAIN RE-ANCHOR CANNOT FIX IT, which is the whole reason this file
//  takes a PAIR of snapshots rather than one: re-anchoring looks for the stored
//  words in the new body, and the stored words are exactly what the typing
//  interrupted. It would find zero occurrences too, for the same reason, and
//  answer the same way. Nothing derived from the after-body alone can recover a
//  passage the user typed into.
//
//  WHAT CAN: the instant before against the instant after. A caret write is ONE
//  CONTIGUOUS INSERTION AT ONE POINT — that is what "at the cursor" means — so
//  `PassageEditRunner.changedSpan`'s two-ended trim finds it exactly, and its
//  own header already names this file as the caller that premise was written
//  for. That is why `AbilityRuntime` brackets the write instead of reading the
//  body again a moment later: read it late and the user has typed something
//  themselves, at which point before/after describes two edits and nothing can
//  tell it from one.
//
//  PURE AND HEADLESS. Foundation only — two strings, a registry, an ambient
//  store and a clock. No app, no AppleScript, no Accessibility, so the rules
//  below are decided by a test rather than by a live Pages.
//

import Foundation

/// SHOWING A LONG PASSAGE WITHOUT DROWNING THE READER — head, an elision, and
/// tail, so the ends that identify a passage both survive.
///
/// Lived on Bonnie's AppleScript runner, because that is where long output
/// first arrived; it is a string helper and nothing about it was ever about
/// scripts.
public enum SpokenText {
    public static func truncate(_ text: String, limit: Int = 4000) -> String {
        // A budget of zero can only honestly return nothing; without this the
        // arithmetic below would slice with negative lengths.
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        let headLength = limit * 3 / 4
        let head = text.prefix(headLength)
        let tail = text.suffix(limit - headLength)
        let omitted = text.count - limit
        return "\(head)\n… \(omitted) characters omitted …\n\(tail)"
    }
}

public enum PassageRefresh {

    /// WHERE ONE HELD PASSAGE ENDED UP, relative to a change that landed
    /// somewhere in the document.
    ///
    /// Four answers, and the third is the failure above with its cure attached.
    public enum Shift: Sendable, Equatable {
        /// The change happened BELOW it. Same words at the same offsets — only
        /// the body hash and the document's length moved.
        case unchanged
        /// The change happened ABOVE it. Same words, `delta` characters further
        /// down.
        case moved(Range<Int>)
        /// The change happened INSIDE it. THE TRACED FAILURE AND ITS ANSWER:
        /// `[S1]` still names the same part of the document, and now includes
        /// what was just typed into it. Its words have changed, so it is a new
        /// passage that the old handle forwards to.
        case grown(Range<Int>)
        /// The change covers one of its edges and not the other. Refused rather
        /// than guessed — the same instinct as `PassageResolver`'s: an edit that
        /// half-overlaps a passage has made it into something nobody named, and
        /// the honest answer is the drift sentence
        /// (`PassageResolver.driftedSentence`) on the handle's next use.
        case straddled
    }

    /// The pure rule. `change` is where the run sits in the BEFORE string —
    /// `ChangedSpan.before` — and `delta` is how much longer the document got.
    ///
    /// THE ORDER OF THE THREE TESTS IS THE ARGUMENT, because a caret is a
    /// ZERO-LENGTH span and every boundary case turns on which test sees it
    /// first.
    ///
    ///   1. CONTAINMENT, through `PassageUnit.contains`. That rule is ALREADY
    ///      SETTLED IN THIS TREE and is reused rather than re-decided: "an empty
    ///      span at a unit's own upper bound counts as OUTSIDE — an insertion
    ///      point at the end of a paragraph belongs to the seam, not to the
    ///      paragraph." So typing at the very END of a held passage does not
    ///      grow it (test 3 catches it, unchanged), and typing at the very
    ///      START does (`contains` admits an empty span at the lower bound).
    ///      Re-deriving either answer here would be a second opinion about a
    ///      question `AbilityRuntime` and `PassageEdit` already answer.
    ///   2. ABOVE IT. Reached only after containment has declined, so the
    ///      zero-length case at the lower bound can never fall in here and be
    ///      shifted when it should have grown.
    ///   3. BELOW IT.
    ///
    /// Every range this returns is in bounds of the AFTER string, by
    /// arithmetic rather than by clamping: the change is contained in the held
    /// span (case 1) or wholly outside it (cases 2 and 3), so no bound can
    /// cross another and `held.upperBound + delta ≤ before.count + delta =
    /// after.count`.
    public static func shift(
        _ held: PassageUnit, by change: Range<Int>, delta: Int
    ) -> Shift {
        if held.contains(change) {
            return .grown(held.range.lowerBound..<(held.range.upperBound + delta))
        }
        if change.upperBound <= held.range.lowerBound {
            return .moved(
                (held.range.lowerBound + delta)..<(held.range.upperBound + delta))
        }
        if held.range.upperBound <= change.lowerBound {
            return .unchanged
        }
        return .straddled
    }

    /// RE-AIM EVERY HANDLE IN THIS WORLD'S DOCUMENT ACROSS ONE UNROUTED WRITE.
    /// Returns how many were re-aimed.
    ///
    /// THE COUNT IS FOR THE CALLER'S OWN LEDGER AND NOTHING ELSE. Nothing here
    /// speaks it and nothing logs it: the moved handles ARE the product, and "I
    /// re-anchored 2 passages" is exactly the machine talk the passage contract
    /// exists to keep out of her mouth.
    ///
    /// TWO GUARDS, AND EACH ONE MAKES A MIS-ROUTED CALL HARMLESS RATHER THAN
    /// WRONG — which matters because the caller decides what to bracket from a
    /// declared flag and a focus lead, and both can be stale:
    ///
    ///   - EQUAL DOCUMENT KEYS. Two snapshots of different documents describe no
    ///     single change, and `changedSpan` handed an unrelated pair returns a
    ///     span that covers most of both. This refuses to reason about a swap
    ///     rather than shifting every handle by the difference in length between
    ///     two unrelated files.
    ///   - A REAL CHANGE. Identical bodies mean nothing landed —
    ///     `resume_typing` with nothing left to type, or a write the app quietly
    ///     refused. The hash says so in one comparison, and it is what makes
    ///     bracketing a binding that turned out not to write cost nothing but the
    ///     two reads.
    ///
    /// THE UNDO ENTRY IS RECORDED HERE, and it is the cheapest half of this
    /// file: `ContentUndoStore` holds one entry per document key, `revert_last_edit`
    /// takes it back under a hash guard, and without this a paragraph she typed
    /// thirty seconds ago is the one thing in the document "undo that" disclaims.
    /// Recorded AFTER the write and against what the document ACTUALLY holds —
    /// `PassageEditRunner.edit`'s step 9a, for the reasons it gives there.
    @discardableResult
    public static func after(
        before: BodySnapshot,
        after: BodySnapshot,
        place: AmbientPlace,
        registry: PassageRegistry = .shared,
        ambient: AmbientContextStore = .shared,
        undo: ContentUndoStore = PassageEditRunner.undoStore,
        now: Date = Date()
    ) -> Int {
        guard before.documentKey == after.documentKey else { return 0 }
        guard before.hash != after.hash else { return 0 }

        undo.record(key: after.documentKey, prior: before.text, applied: after.text)

        let change = PassageEditRunner.changedSpan(from: before.text, to: after.text)
        var refreshed = 0
        for passage in registry.live(at: now)
        where passage.place == place && passage.documentKey == after.documentKey {
            // WHERE IT SAT IN THE *BEFORE* STRING, which is not always its
            // stored range: the handle may have been minted against an older
            // body still. The resolver is the one thing allowed to answer that
            // question, and it answers by TEXT — so a passage that cannot be
            // located in the before-body is skipped rather than shifted from a
            // stale integer, which is the exact move this whole contract bans.
            guard let held = PassageResolver.range(
                PassageResolver.anchor(passage, in: before.text), of: passage)
            else { continue }

            let landed: Range<Int>
            switch shift(PassageUnit(passage, at: held), by: change.before, delta: change.delta) {
            case .straddled:        continue
            case .unchanged:        landed = held
            case .moved(let range): landed = range
            case .grown(let range): landed = range
            }

            let words = PassageWidening.substring(of: after.text, landed)
            // A SHRINK CAN SWALLOW A PASSAGE WHOLE. Nothing left to point a
            // handle at, and a handle over an empty span would resolve to
            // `.gone` on its next use anyway — so it is left to do exactly that,
            // and the user hears the drift sentence rather than a handle that
            // silently means nothing.
            guard !words.isEmpty else { continue }

            // MINTING DOES THE UNCHANGED-TEXT CASE FOR FREE, and that is why
            // nothing here calls a new registry API. Identity is
            // `place|documentKey|hash(text)`, so the SAME WORDS AT A NEW OFFSET
            // come back as the SAME HANDLE with a refreshed range and body hash
            // — the conversation goes on calling it `[S1]` and the next resolve
            // is `.exact` instead of a search. Only a passage whose words
            // changed mints a new handle, and only that one needs a forward.
            guard let minted = registry.mint(
                place: passage.place,
                documentKey: after.documentKey,
                documentTitle: after.documentTitle,
                text: words,
                bodyHash: after.hash,
                bodyLength: after.length,
                range: landed,
                unitKind: passage.unitKind,
                locatorNote: passage.locatorNote,
                provenance: passage.provenance,
                at: now)
            else { continue }

            let rewritten = minted.handle != passage.handle
            if rewritten { registry.supersede(passage.handle, with: minted, at: now) }
            // `clearSpoken` IS THE DIFFERENCE BETWEEN A REWRITE AND A MOVE, and
            // this is the caller `PassageEditRunner.refreshHeldFact` grew the
            // parameter for. A passage that merely slid down the page holds the
            // same words she has already told the user about; clearing the note
            // would un-suppress that mention and have her say it twice about a
            // paragraph nobody touched.
            PassageEditRunner.refreshHeldFact(
                from: passage, to: minted, after: after,
                ambient: ambient, now: now, clearSpoken: rewritten)
            refreshed += 1
        }
        return refreshed
    }
}
