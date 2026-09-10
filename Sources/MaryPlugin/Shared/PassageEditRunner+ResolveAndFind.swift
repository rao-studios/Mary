//
//  PassageEditRunner+ResolveAndFind.swift
//  MaryPlugin
//
//  WHAT: Guard-chain steps 1–4 (resolve, snapshot, identity, mint/find).
//  IN:   PassageEditRunner.swift (sibling split)
//  OUT:  PassageResolver | PassageWidening | PassageRegistry
//  PIN:  Handle before body read — documentKey is which window.
//

import Foundation

extension PassageEditRunner {

    // MARK: - 1 & 2. Resolve and snapshot

    /// Handle if given, else locating words via the widening ladder.
    /// PIN: identity before description — a fuzzy target must not outrank [S1].
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
            // Missing arg: say what would work. Condition, not an errand.
            return .refused("Which part should I change? A heading, or the words "
                + "themselves, and I'll find it.", looked: false)
        }

        // Handle before body: registry lookup names which document to read.
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
                // Unknown handle: fall through to target if the caller named one.
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

    /// Follow a superseded handle. PIN: bound 8 — supersede chains, never cycles.
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
        // Document identity first. Re-locating words in the wrong file is luck, not a find.
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
            // Body was searched (`.gone` / `.ambiguousAfterDrift`). Read reports as an answer.
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
            // World cannot hold passages. Sentence, not a crash.
            return .refused(noDocumentMessage(backing.place), looked: false)
        }
        return .found(Located(
            passage: passage, snapshot: snapshot, range: span,
            label: decision.label ?? "",
            confidence: decision.confidence, rung: decision.rung,
            runnerUp: decision.runnerUp, forwardedFrom: nil,
            trace: decision.trace))
    }

    /// Viewport/selection words as PassageAttention. Located by range(of:) in the body.
    /// PIN: carry `application:` — two apps share `.otherApps`.
    public static func attention(
        for place: AmbientPlace, ambient: AmbientContextStore
    ) -> PassageAttention? {
        // Viewport fact is per application, not just world.
        let words = ambient.routedSelectionHandoff(attention: place.attention)?.text
            ?? ambient.fact(
                attention: place.attention, application: place.application,
                slot: .viewport)?.content
        guard let words, !words.isEmpty else { return nil }
        return PassageAttention(text: words)
    }

    /// No-document sentence from `displayName`. Condition, not an errand.
    public static func noDocumentMessage(_ place: AmbientPlace) -> String {
        // Redirect to type_at_cursor — `body` is nil for closed app AND blank document.
        "I can't see a document with text open in \(place.displayName) right now, "
            + "so there's nothing in front of me to look in. A blank document "
            + "is written with type_at_cursor, never passage edits."
    }

    // MARK: - find_passage

    /// Read: locate, mint, return words. Miss → `foundNothing` (ok, no authority).
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

    /// Bounds-label contract: `[handle] Title — characters N–M of T`.
    /// OUT: AmbientBridge.parseBounds (handle in front; parseBounds strips it).
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
