//
//  PassageEditRunner+ResolveAndFind.swift
//  MaryAdapter
//
//  Split out of PassageEditRunner.swift (docs/DECOMPOSITION.md Wave 4)
//  — pure relocation, no declaration changed.
//

import Foundation

extension PassageEditRunner {

    // MARK: - 1 & 2. Resolve and snapshot

    /// Find the passage the caller means: a handle if they gave one, otherwise
    /// the words they used, located by the widening ladder.
    ///
    /// THE ORDER IS NOT A PREFERENCE. A handle is an IDENTITY the registry
    /// minted; a target is a DESCRIPTION the model composed, and the ladder has
    /// to guess at it. Trying the description first would let a fuzzy token
    /// match outrank the exact passage the conversation has been calling `[S1]`
    /// for three turns.
    public static func locate(
        handle: String?,
        target: String?,
        backing: PassageBacking,
        registry: PassageRegistry = .shared,
        ambient: AmbientContextStore = .shared,
        now: Date = Date()
    ) async -> Lookup {
        let wantedHandle = (handle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let wantedTarget = (target ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wantedHandle.isEmpty || !wantedTarget.isEmpty else {
            // `XcodeEditError`'s precedent — a missing argument asks for the
            // one thing that would make the call work, in the words a person
            // would use, rather than naming a parameter.
            //
            // A QUESTION, NOT AN ERRAND. "Name the heading, or give me the
            // words" was two imperatives, and a Skill-invoking model reads an
            // imperative in a Skill result as a thing to go and do — see
            // `noDocumentMessage`, where that reading fired `open_in_pages` on
            // a passage refusal that never mentions Pages. What is left says
            // what would resolve it and stops.
            return .refused("Which part should I change? A heading, or the words "
                + "themselves, and I'll find it.", looked: false)
        }

        // RESOLVE THE HANDLE BEFORE READING THE BODY, and the order is the
        // whole of multi-window correctness.
        //
        // `resolveHandle` is registry-only — a dictionary lookup, no Apple
        // event, no I/O — so hoisting it above the read costs nothing and buys
        // the one thing the read needs to be correct: WHICH DOCUMENT. Read
        // first and the body is always the front one, so a handle minted in
        // the todo note gets re-anchored against whatever window the user has
        // since danced to, and `anchor` then reports the passage as gone from
        // a document it was never in.
        //
        // Nil `documentKey` (no handle, or a world with one document) means
        // "the one in front", which is exactly what `body(for:)` falls back to
        // and exactly what every world did before this line existed.
        var resolution: HandleResolution?
        if !wantedHandle.isEmpty {
            resolution = resolveHandle(wantedHandle, registry: registry, at: now)
        }
        var wantedDocument: String?
        if case .resolved(let passage, _) = resolution { wantedDocument = passage.documentKey }

        guard let snapshot = await backing.body(for: wantedDocument) else {
            return .refused(noDocumentMessage(backing.place), looked: false)
        }

        if let resolution {
            switch resolution {
            case .resolved(let passage, let forwardedFrom):
                return anchor(
                    passage, in: snapshot, forwardedFrom: forwardedFrom, backing: backing)
            case .unknown:
                // A handle the registry has never heard of, or has pruned. If
                // the caller ALSO named the part, that naming is a perfectly
                // good instruction and there is no reason to make them repeat
                // it; a bare unknown handle has nothing to fall back to.
                guard !wantedTarget.isEmpty else {
                    return .refused(
                        "I don't have anything called [\(wantedHandle)] any more — a heading "
                        + "or the words themselves would let me find it again.", looked: false)
                }
            }
        }

        return await mint(
            target: wantedTarget, in: snapshot, backing: backing,
            registry: registry, ambient: ambient, now: now)
    }

    private enum HandleResolution {
        case resolved(Passage, forwardedFrom: String?)
        case unknown
    }

    /// Follow a superseded handle to whatever replaced it.
    ///
    /// BOUNDED, and the bound is not defensive noise: an edit supersedes, and a
    /// second edit of the same passage supersedes again, so a conversation that
    /// tightens one paragraph four times leaves a chain four long. It is a
    /// chain and not a cycle — `supersede` refuses `old == new` — but a bound
    /// costs one integer and removes the whole class of question.
    private static func resolveHandle(
        _ handle: String, registry: PassageRegistry, at now: Date
    ) -> HandleResolution {
        var current = handle
        var forwardedFrom: String?
        for _ in 0..<8 {
            switch registry.resolve(current, at: now) {
            case .live(let passage):
                return .resolved(passage, forwardedFrom: forwardedFrom)
            case .superseded(let replacedBy):
                if forwardedFrom == nil { forwardedFrom = current }
                current = replacedBy
            case .unknown:
                return .unknown
            }
        }
        return .unknown
    }

    /// Step 4 for a passage we already hold: is it still where it was?
    public static func anchor(
        _ passage: Passage, in snapshot: BodySnapshot,
        forwardedFrom: String?, backing: PassageBacking
    ) -> Lookup {
        // THE DOCUMENT COMES FIRST. A passage carries the document it was cut
        // from; if the world is now showing another one, re-locating its words
        // in THAT document would find them or not by luck, and either answer
        // would be about the wrong file. This is the `-1728` in its preventable
        // form, checked before any text is searched.
        guard passage.documentKey == snapshot.documentKey else {
            return .refused(
                (PassageWriteError.documentMoved(
                    expected: passage.documentTitle,
                    found: snapshot.documentTitle.isEmpty ? nil : snapshot.documentTitle)
                ).errorDescription ?? noDocumentMessage(backing.place),
                looked: false)
        }
        let outcome = PassageResolver.anchor(passage, in: snapshot.text)
        guard let range = PassageResolver.range(outcome, of: passage) else {
            // The body WAS searched here — `.gone` and `.ambiguousAfterDrift`
            // are both results of looking — so a read reports them as an
            // answer rather than as a breakage.
            return .refused(
                PassageResolver.refusal(outcome, for: passage)
                    ?? noDocumentMessage(backing.place),
                looked: true)
        }
        return .found(Located(
            passage: passage, snapshot: snapshot, range: range, label: "",
            confidence: nil, rung: nil, runnerUp: nil,
            forwardedFrom: forwardedFrom,
            trace: ["resolved by handle", "anchor: \(outcome)"]))
    }

    /// Locate by the words the user used, and mint a handle for what was found.
    public static func mint(
        target: String, in snapshot: BodySnapshot, backing: PassageBacking,
        registry: PassageRegistry, ambient: AmbientContextStore, now: Date
    ) async -> Lookup {
        let units = backing.units(snapshot.text)
        let decision = PassageWidening.locate(
            target: target, in: snapshot.text, units: units,
            attention: attention(for: backing.place, ambient: ambient))
        guard let span = decision.span else {
            return .refused(decision.refusal ?? PassageWidening.missReason, looked: true)
        }
        let text = PassageWidening.substring(of: snapshot.text, span)
        guard let passage = registry.mint(
            place: backing.place,
            documentKey: snapshot.documentKey,
            documentTitle: snapshot.documentTitle,
            text: text,
            bodyHash: snapshot.hash,
            bodyLength: snapshot.length,
            range: span,
            unitKind: decision.kind ?? .window,
            locatorNote: decision.rung?.locatorNote ?? "",
            provenance: .recipeRead,
            at: now)
        else {
            // Only a world that cannot hold passages lands here, and none of
            // the three that declare a backing is one. Refusing rather than
            // force-unwrapping keeps a future fourth world's category error a
            // sentence instead of a crash.
            return .refused(noDocumentMessage(backing.place), looked: false)
        }
        return .found(Located(
            passage: passage, snapshot: snapshot, range: span,
            label: decision.label ?? "",
            confidence: decision.confidence, rung: decision.rung,
            runnerUp: decision.runnerUp, forwardedFrom: nil,
            trace: decision.trace))
    }

    /// WHERE THE USER IS LOOKING, from the ambient store's own words.
    ///
    /// `PassageAttention` takes TEXT rather than an offset on purpose (a raw AX
    /// integer counts UTF-16 over a string that includes headers; a `body text`
    /// offset does neither), and this is the honest source for it: the
    /// selection the watcher published, or failing that the viewport excerpt.
    /// Both are located by `range(of:)` inside the body itself, so a fact from
    /// a different coordinate space simply fails to locate and the tie-break
    /// falls through to document order — never to a fabricated position.
    public static func attention(
        for place: AmbientPlace, ambient: AmbientContextStore
    ) -> PassageAttention? {
        // `application:` CARRIED THROUGH on the viewport read: two taught
        // applications share the `.otherApps` host lane, so the world alone
        // would hand one manuscript's viewport to the other's locate ladder —
        // and attention is a TIE-BREAK between identical candidate spans, so a
        // wrong one lands silently on the wrong paragraph.
        let words = ambient.routedSelectionHandoff(world: place.world)?.text
            ?? ambient.fact(
                world: place.world, application: place.application,
                slot: .viewport)?.content
        guard let words, !words.isEmpty else { return nil }
        return PassageAttention(text: words)
    }

    /// The "I can't see it" sentence, in the register of the place that owns
    /// the document. One phrasing per place, built from `displayName` rather
    /// than hand-written strings that would drift — which is also what lets a
    /// taught application refuse in its own name instead of the host lane's.
    ///
    /// THE ERRAND IS GONE, AND THIS IS THE ONE THAT FIRED. It used to end
    /// "bring the one you mean up and ask me again", and a Skill-invoking model
    /// reads that as an instruction it can carry out: the live transcript shows
    /// `OPEN_IN_PAGES` fired off the back of a passage refusal, and nothing
    /// anywhere in the passage path calls it. The tree already settled this
    /// question in its own words elsewhere — "A SIZE, NOT AN ERRAND … which a
    /// Skill-invoking model takes as fetch it" — so the condition is stated and the
    /// imperative is deleted. Telling the USER to grant Accessibility is a
    /// different job and has its own seam, `SkillBinding.spokenFailureHint`.
    public static func noDocumentMessage(_ place: AmbientPlace) -> String {
        // The trailing sentence is a REDIRECT to the correct verb, not an
        // errand: `body` is nil for a closed app AND for a blank document
        // (Pages returns nil on an empty body), and the blank case used to
        // dead-end here — every passage verb refused a fresh document while
        // the one verb that fills it went unnamed.
        "I can't see a document with text open in \(place.displayName) right now, "
            + "so there's nothing in front of me to look in. A blank document "
            + "is written with type_at_cursor, never passage edits."
    }

    // MARK: - find_passage

    /// A READ: locate the passage, mint the handle, hand back its words.
    ///
    /// `foundNothing` on a miss, `ok: true` — the read genuinely ran and this
    /// is its honest answer. What the flag denies is AUTHORITY, so a miss can
    /// never be carried into the voice's live block and recited to the user as
    /// though it were the passage they asked for.
    public static func find(
        handle: String?, target: String?, backing: PassageBacking,
        registry: PassageRegistry = .shared,
        ambient: AmbientContextStore = .shared,
        now: Date = Date()
    ) async -> SkillOutcome {
        switch await locate(
            handle: handle, target: target, backing: backing,
            registry: registry, ambient: ambient, now: now) {
        case .refused(let sentence, let looked):
            return SkillOutcome(ok: looked, summary: sentence, foundNothing: looked)
        case .found(let found):
            return SkillOutcome(
                ok: true,
                summary: passageBlock(found),
                passageHandle: found.passage.handle)
        }
    }

    /// The read's answer, in the bounds-label contract this tree already has.
    ///
    /// `Name — characters N–M of T` IS A CONTRACT, not a phrasing choice:
    /// `AmbientBridge.parseBounds` pulls those three numbers back out of this
    /// exact head so the fact carries real bounds, and
    /// `PagesPlugin.regionOutcome` is where it is written down. The handle goes
    /// in FRONT of it — `parseBounds` strips exactly that prefix before reading
    /// the subject, and it is the one token on the line a Skill will accept.
    public static func passageBlock(_ found: Located) -> String {
        var head = "[\(found.passage.handle)] \(found.snapshot.documentTitle) — "
            + "characters \(found.range.lowerBound)–\(found.range.upperBound) "
            + "of \(found.snapshot.length)"
        if !found.label.isEmpty { head += ", \(found.label)" }
        let note = found.passage.locatorNote
        if !note.isEmpty { head += " — \(note)" }
        return head + ":\n" + SpokenText.truncate(found.passage.text, limit: 1800)
    }

}
