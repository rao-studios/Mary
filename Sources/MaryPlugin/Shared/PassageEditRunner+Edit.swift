//
//  PassageEditRunner+Edit.swift
//  MaryPlugin
//
//  WHAT: Guard-chain steps 5–9 (compute → apply → remint).
//  IN:   PassageEditRunner.swift (sibling split)
//  OUT:  PassageWriter | ContentUndoStore | PassageRegistry
//  PIN:  Replace hands the writer a unique minimal span, not the whole passage.
//

import Foundation

extension PassageEditRunner {

    // MARK: - The edit

    /// Steps 5–9. `text` ignored for `.delete` (empty replacement).
    public static func edit(
        _ operation: PassageOperation,
        handle: String?, target: String?, text: String,
        backing: PassageBacking,
        registry: PassageRegistry = .shared,
        ambient: AmbientContextStore = .shared,
        undo: ContentUndoStore = PassageEditRunner.undoStore,
        now: Date = Date()
    ) async -> SkillOutcome {

        // 1–4. Locate first, even when the world cannot write.
        let found: Located
        switch await locate(
            handle: handle, target: target, backing: backing,
            registry: registry, ambient: ambient, now: now) {
        case .refused(let sentence, _):
            // PIN: every edit-path refusal is `ok: false` — a requested change did not happen.
            return SkillOutcome(ok: false, summary: sentence)
        case .found(let located):
            found = located
        }

        guard let writer = backing.writer else {
            return SkillOutcome(
                ok: false,
                summary: backing.writeRefusal?.errorDescription
                    ?? "I can find it, but I can't change it there yet.")
        }

        // Empty replace would delete. Redirect to delete_passage.
        if operation == .replace,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SkillOutcome(
                ok: false,
                summary: "That would replace it with nothing — taking a passage "
                    + "out is delete_passage's job, so I've left it alone.")
        }
        // Heading matches have no size ceiling of their own.
        if operation == .replace || operation == .delete,
           found.range.count > PassageWidening.maxSpan {
            return SkillOutcome(
                ok: false,
                summary: PassageWriteError.spanTooLarge(
                    characters: found.range.count,
                    limit: PassageWidening.maxSpan).errorDescription ?? "")
        }

        // Target-resolved replace: refuse if the prompt's body hash drifted.
        // OUT: refusal carries the fresh passage. Handle-resolved edits skip.
        if operation == .replace, handle == nil,
           let promptedHash = await backing.promptedBodyHash?(),
           promptedHash != found.snapshot.hash {
            let fresh = SpokenText.truncate(found.passage.text, limit: 1800)
            return SkillOutcome(
                ok: false,
                summary: "\(found.snapshot.documentTitle) has moved on since I last "
                    + "read it, so I haven't changed anything. As it reads now:\n\(fresh)",
                passageHandle: found.passage.handle)
        }

        // 5. PassageEdit. Unit carries kind — separators depend on it.
        let unit = PassageUnit(
            range: found.range, label: found.label, level: 0,
            kind: found.passage.unitKind)
        let edited = PassageEdit.apply(
            operation, text: text, to: unit, in: found.snapshot.text)

        // 6. Hash re-check on this documentKey, not the front window.
        guard let fresh = await backing.body(for: found.snapshot.documentKey) else {
            return SkillOutcome(ok: false, summary: noDocumentMessage(backing.place))
        }
        guard fresh.hash == found.snapshot.hash,
              fresh.documentKey == found.snapshot.documentKey else {
            return SkillOutcome(
                ok: false, summary: "You typed while I was working — try that again.")
        }

        // 7. APPLY. Words to find, never an offset. `hint` only breaks identical-occurrence ties.
        guard let write = writeSpan(
            operation, edited: edited, in: found.snapshot.text, hint: found.range) else {
            // Identical recompose: nothing differs. Do not hand a writer a no-op.
            return SkillOutcome(
                ok: true,
                summary: "\(found.snapshot.documentTitle) already reads that way — "
                    + "there was nothing to change.",
                editDisposition: .unchanged)
        }
        let receipt: WriteReceipt
        do {
            receipt = try await writer.replace(
                write.anchor, with: write.replacement,
                hint: write.range, in: found.snapshot)
        } catch let error as LocalizedError {
            return SkillOutcome(
                ok: false,
                summary: error.errorDescription ?? "I couldn't make that change.")
        } catch {
            return SkillOutcome(ok: false, summary: "I couldn't make that change.")
        }

        // 8. Verify. Writer receipt first (same session as the write).
        let after: BodySnapshot?
        if let body = receipt.newBody {
            after = BodySnapshot(
                text: body,
                documentKey: found.snapshot.documentKey,
                documentTitle: found.snapshot.documentTitle)
        } else if let read = await backing.body(for: found.snapshot.documentKey),
                  read.documentKey == found.snapshot.documentKey {
            // PIN: mismatched documentKey is no read-back.
            after = read
        } else {
            after = nil
        }
        let verified = verify(
            edited, operation: operation,
            before: found.snapshot.text, after: after?.text)

        // Sent write, hash unchanged → failure (AX no-op). Not unconfirmed.
        if let after, !verified, after.hash == found.snapshot.hash {
            return SkillOutcome(
                ok: false,
                summary: "I sent the change and \(found.snapshot.documentTitle) "
                    + "didn't take it — nothing has changed.")
        }

        // 9a. Undo after the write, against read-back text (not computed).
        // OUT: ContainerRegistry.noteEvidence(.actedOn) — this is the write funnel.
        ContainerRegistry.shared.noteEvidence(
            place: backing.place, key: found.snapshot.documentKey, .actedOn)

        if let after {
            undo.record(
                key: found.snapshot.documentKey,
                prior: found.snapshot.text,
                applied: after.text)
        }

        // 9b. Remint and forward — verified writes only.
        var replacement: Passage?
        if verified, let after, operation != .delete, !edited.replacement.isEmpty {
            replacement = remint(
                edited, found: found, after: after,
                registry: registry, ambient: ambient, now: now)
        }
        // Delete mints nothing. Next use of the old handle re-anchors and misses.

        var summary = report(
            clause: PassageEdit.summaryClause(
                operation, unit: unit,
                changedFraction: reduction(write.anchor, of: edited.anchorText)),
            found: found, replacement: replacement, verified: verified)
        if !verified {
            // Unconfirmed: may have landed; retry could apply twice.
            summary += " It may have landed, and sending it again could apply it twice."
        }
        return SkillOutcome(
            ok: true,
            summary: summary,
            // Verified → state snapshot. Unconfirmed → episodic.
            archivePolicy: verified ? .stateSnapshot : .episodic,
            passageHandle: replacement?.handle ?? found.passage.handle,
            editDisposition: verified ? .landed : .unconfirmed)
    }

    /// What the writer is handed. Replace → unique minimal span of the whole body.
    /// Insert/delete pass through (PassageEdit already chose the span). Nil = nothing differs.
    public static func writeSpan(
        _ operation: PassageOperation, edited: PassageEditResult,
        in body: String, hint: Range<Int>
    ) -> (anchor: String, replacement: String, range: Range<Int>)? {
        guard operation == .replace else {
            // Hint = resolved span. Only breaks identical-occurrence ties.
            return (edited.anchorText, edited.replacement, hint)
        }
        let change = minimalChange(from: body, to: edited.newBody)
        guard !change.anchor.isEmpty || !change.replacement.isEmpty else { return nil }
        return change
    }

    /// Fraction of the passage the write touched, 0…1. OUT: PassageEdit.summaryClause.
    /// PIN: uniqueAnchor can grow past the passage; clamp at 1.
    public static func reduction(_ written: String, of passage: String) -> Double {
        guard !passage.isEmpty else { return 1 }
        return min(1, Double(written.count) / Double(passage.count))
    }

    /// Did it land? Hash match → yes. Unchanged hash → no. Else: old words gone
    /// (replace/delete) or length grew (insert). PIN: do not require the new
    /// spelling — Pages substitutes quotes on the keystroke path.
    public static func verify(
        _ edited: PassageEditResult, operation: PassageOperation,
        before: String, after: String?
    ) -> Bool {
        guard let after else { return false }
        if ContentUndoStore.hash(after) == ContentUndoStore.hash(edited.newBody) { return true }
        if ContentUndoStore.hash(after) == ContentUndoStore.hash(before) { return false }
        switch operation {
        case .replace, .delete:
            return !edited.anchorText.isEmpty && !after.contains(edited.anchorText)
        case .insertBefore, .insertAfter:
            return after.count > before.count
        }
    }

    /// Mint a handle for the new text, forward the old one, refresh the held fact.
    public static func remint(
        _ edited: PassageEditResult, found: Located, after: BodySnapshot,
        registry: PassageRegistry, ambient: AmbientContextStore, now: Date
    ) -> Passage? {
        // Exactly one occurrence in the new body, or no handle.
        let hits = PassageWidening.occurrences(of: edited.replacement, in: after.text)
        guard hits.count == 1 else { return nil }
        guard let minted = registry.mint(
            place: found.passage.place,
            documentKey: after.documentKey,
            documentTitle: after.documentTitle,
            text: edited.replacement,
            bodyHash: after.hash,
            bodyLength: after.length,
            range: hits[0],
            unitKind: found.passage.unitKind,
            locatorNote: "the part I just changed",
            provenance: .recipeRead,
            at: now)
        else { return nil }
        registry.supersede(found.passage.handle, with: minted, at: now)
        refreshHeldFact(from: found.passage, to: minted, after: after, ambient: ambient, now: now)
        return minted
    }

    /// Supersede the held fact by handle (same slot). PIN: clearSpoken on rewrite,
    /// not on a move (PassageRefresh after a caret write above).
    public static func refreshHeldFact(
        from old: Passage, to new: Passage, after: BodySnapshot,
        ambient: AmbientContextStore, now: Date, clearSpoken: Bool = true
    ) {
        guard let stale = ambient.reads(at: now).first(where: {
            $0.passageHandle == old.handle && $0.place == old.place
        }) else { return }
        var refreshed = stale
        refreshed.content = "[\(new.handle)] \(after.documentTitle) — characters "
            + "\(new.range.lowerBound)–\(new.range.upperBound) of \(after.length), "
            + "as it reads now:\n" + SpokenText.truncate(new.text, limit: 1800)
        refreshed.bounds = new.range
        refreshed.documentTotal = after.length
        refreshed.subject = after.documentTitle
        refreshed.capturedAt = now
        refreshed.passageHandle = new.handle
        if clearSpoken {
            refreshed.spokenAt = nil
            refreshed.spokenNote = nil
        }
        ambient.register(refreshed, at: now)
    }

}
