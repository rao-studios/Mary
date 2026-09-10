//
//  PassageRefresh.swift
//  MaryPlugin
//
//  WHAT: After a caret write, re-anchor minted passages that only moved.
//  IN:   PassageEditRunner.minimalChange  OUT: PassageRegistry / held facts
//  PIN:  Bracket the write; two independent edits would spread the span.

import Foundation

/// SHOWING A LONG PASSAGE WITHOUT DROWNING THE READER — head, an elision, and tail, so the
/// ends that identify a passage both survive.
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

    /// WHERE ONE HELD PASSAGE ENDED UP, relative to a change that landed somewhere in the
    /// document.
    public enum Shift: Sendable, Equatable {
        /// The change happened BELOW it. Same words at the same offsets — only
        /// the body hash and the document's length moved.
        case unchanged
        /// The change happened ABOVE it. Same words, `delta` characters further
        /// down.
        case moved(Range<Int>)
        /// The change happened INSIDE it. `[S1]` still names the same part of the document,
        /// and now includes what was just typed into it.
        case grown(Range<Int>)
        /// The change covers one of its edges and not the other. Refused rather than
        /// guessed — the same instinct as `PassageResolver`'s: an edit that half-overlaps a
        /// passage.
        case straddled
    }

    /// The pure rule. `change` is where the run sits in the BEFORE string —
    /// `ChangedSpan.before` — and `delta` is how much longer the document got.
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
            // WHERE IT SAT IN THE *BEFORE* STRING, which is not always its stored range:
            // the handle may have been minted against an older body still.
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
            // A SHRINK CAN SWALLOW A PASSAGE WHOLE. Nothing left to point a handle at, and
            // a handle over an empty span would resolve to `.gone` on its next use anyway.
            guard !words.isEmpty else { continue }

            // MINTING DOES THE UNCHANGED-TEXT CASE FOR FREE, and that is why nothing here
            // calls a new registry API.
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
            // `clearSpoken` IS THE DIFFERENCE BETWEEN A REWRITE AND A MOVE, and this is the
            // caller `PassageEditRunner.refreshHeldFact` grew the parameter for.
            PassageEditRunner.refreshHeldFact(
                from: passage, to: minted, after: after,
                ambient: ambient, now: now, clearSpoken: rewritten)
            refreshed += 1
        }
        return refreshed
    }
}
