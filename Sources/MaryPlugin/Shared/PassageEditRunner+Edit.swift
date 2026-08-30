//
//  PassageEditRunner+Edit.swift
//  MaryAdapter
//
//  Split out of PassageEditRunner.swift (docs/DECOMPOSITION.md Wave 4)
//  — pure relocation, no declaration changed.
//

import Foundation

extension PassageEditRunner {

    // MARK: - The edit

    /// Steps 5 through 9. `text` is the new prose; it is ignored for
    /// `.delete`, which `PassageEdit` expresses as a substitution with an empty
    /// replacement.
    public static func edit(
        _ operation: PassageOperation,
        handle: String?, target: String?, text: String,
        backing: PassageBacking,
        registry: PassageRegistry = .shared,
        ambient: AmbientContextStore = .shared,
        undo: ContentUndoStore = PassageEditRunner.undoStore,
        now: Date = Date()
    ) async -> SkillOutcome {

        // 1–4. Locate FIRST, even for a world that cannot write. "I can find it
        // in Scrivener, but I can't change it there — …" is a true sentence and
        // an actionable one; "I can't change things in Scrivener" said before
        // looking is neither, and the user cannot tell it from a bug.
        let found: Located
        switch await locate(
            handle: handle, target: target, backing: backing,
            registry: registry, ambient: ambient, now: now) {
        case .refused(let sentence, _):
            // EVERY refusal on the edit path is `ok: false`, whether or not the
            // document was searched. The user asked for a CHANGE and the change
            // did not happen; the turn's "silent success, SPOKEN failure" rule
            // is exactly right about it, and `foundNothing` here would report an
            // unmade edit as an answer, in silence.
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

        // BOUND WHAT A REPLACE MAY DESTROY — two guards the schema only ever
        // advertised.
        //
        // An empty `text` on `.replace` used to silently DELETE the located
        // passage (the schema's `required: true` is advertisement, not
        // enforcement), and verify tier 3 then confirmed the deletion as a
        // successful replacement. A redirect that names the right verb, per
        // the veto doctrine: an outcome the model can act on, not a scolding.
        if operation == .replace,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SkillOutcome(
                ok: false,
                summary: "That would replace it with nothing — taking a passage "
                    + "out is delete_passage's job, so I've left it alone.")
        }
        // And the span cap the error text has promised since it was written:
        // rung-1 heading matches have no size ceiling of their own, so
        // "replace the Introduction" could rewrite an unbounded span with a
        // single sentence. `spanTooLarge` finally throws.
        if operation == .replace || operation == .delete,
           found.range.count > PassageWidening.maxSpan {
            return SkillOutcome(
                ok: false,
                summary: PassageWriteError.spanTooLarge(
                    characters: found.range.count,
                    limit: PassageWidening.maxSpan).errorDescription ?? "")
        }

        // THE STALE-RECOMPOSE TRIPWIRE. A TARGET-resolved `.replace` was
        // recomposed from prose the prompt carried — and the prompt's
        // snapshot can be a full watcher-window old. If the document has
        // moved since the model last saw it, `minimalChange` (a two-ended
        // trim, not a diff) would write one span covering the revision AND
        // everything that changed underneath, silently reverting the user's
        // own typing — with verify then confirming the write, because the
        // document matches exactly what was computed. Refuse instead, and
        // CARRY THE FRESH PASSAGE so the retry recomposes correctly — the
        // find-miss precedent: the refusal holds the retry's raw material.
        //
        // Handle-resolved edits skip: the resolver's text anchor already
        // refuses when the user typed inside the passage, and a handle names
        // an exact minted text rather than a prompt-shaped paraphrase.
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

        // 5. COMPUTE — pure. The unit carries the KIND as well as the range,
        // because the separators depend on it: an insert around a paragraph
        // needs its blank lines and an insert around a phrase must not have
        // them, and a signature taking a bare range would let one edit weld two
        // paragraphs together.
        let unit = PassageUnit(
            range: found.range, label: found.label, level: 0,
            kind: found.passage.unitKind)
        let edited = PassageEdit.apply(
            operation, text: text, to: unit, in: found.snapshot.text)

        // 6. RE-CHECK THE BODY HASH, immediately before writing. Steps 1–5 read
        // the document, parsed it, ran the ladder and computed a replacement —
        // hundreds of milliseconds during which the user is typing in that very
        // document. Xcode's writer has its own race guard on the disk bytes;
        // Pages has none, so this is the one that stands for it.
        //
        // RE-READ THE SNAPSHOT'S OWN DOCUMENT, not the front one. In a world
        // with several windows those are routinely different, and the
        // comparison below is what makes them so: an unkeyed re-read of a
        // window the user has since danced away from fails the hash and
        // reports "you typed while I was working" about a document nobody
        // touched — turning a correct background edit into a phantom race.
        guard let fresh = await backing.body(for: found.snapshot.documentKey) else {
            return SkillOutcome(ok: false, summary: noDocumentMessage(backing.place))
        }
        guard fresh.hash == found.snapshot.hash,
              fresh.documentKey == found.snapshot.documentKey else {
            return SkillOutcome(
                ok: false, summary: "You typed while I was working — try that again.")
        }

        // 7. APPLY. Words to find and words to put there — never an offset.
        // `hint` may do exactly one thing downstream: break a tie between two
        // IDENTICAL occurrences.
        guard let write = writeSpan(
            operation, edited: edited, in: found.snapshot.text, hint: found.range) else {
            // A RECOMPOSE THAT CAME BACK IDENTICAL. `minimalChange` answers
            // "nothing differs" with an empty pair, and its own header says why
            // that must never reach a writer: a no-op substitution is a real
            // disk write on Xcode and an AX select-and-set that can fall back to
            // synthesised keystrokes on Pages, all to change nothing. `revert`
            // has said this sentence since the day that guard went in; a
            // `.replace` can now arrive in exactly the same state.
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

        // 8. READ BACK AND VERIFY — the writer's own receipt FIRST. On the
        // AppleScript tier its read-back was captured in the same Apple-event
        // session as the writes: the one piece of evidence in this pipeline
        // with no check-to-write gap. The receipt used to be discarded here
        // (`_ =`) and a fourth, racier osascript read substituted for it.
        let after: BodySnapshot?
        if let body = receipt.newBody {
            after = BodySnapshot(
                text: body,
                documentKey: found.snapshot.documentKey,
                documentTitle: found.snapshot.documentTitle)
        } else if let read = await backing.body(for: found.snapshot.documentKey),
                  read.documentKey == found.snapshot.documentKey {
            // THE IDENTITY GUARD step 6 always had and step 8 lacked: in a
            // world whose keyed read falls back to the front document, an
            // alt-tab mid-write used to hand this path ANOTHER document's
            // body — verify compared the wrong text, the undo ledger was
            // poisoned with it, and the handle forwarded into the wrong
            // document. A mismatched key is no read-back at all.
            after = read
        } else {
            after = nil
        }
        let verified = verify(
            edited, operation: operation,
            before: found.snapshot.text, after: after?.text)

        // A SENT WRITE THAT CHANGED NOTHING IS A FAILURE, not an unconfirmed.
        // An AX setter that answers `.success` and no-ops looks exactly like
        // this; the document is untouched, so a retry is safe and failure
        // semantics are honest.
        if let after, !verified, after.hash == found.snapshot.hash {
            return SkillOutcome(
                ok: false,
                summary: "I sent the change and \(found.snapshot.documentTitle) "
                    + "didn't take it — nothing has changed.")
        }

        // 9a. THE UNDO ENTRY, recorded AFTER the write and against what the
        // document ACTUALLY holds.
        //
        // Two decisions, and each removes a way `revert_last_edit` would lie:
        //
        //  - AFTER, not before. `ContentUndoStore` holds ONE entry per key, so
        //    recording before the write means a failed edit overwrites the
        //    entry belonging to the successful edit before it — and the user's
        //    "undo that" then refuses about a change that is sitting right
        //    there on screen. An entry for an edit that never applied is
        //    unusable anyway: `take(for:currentHash:)` is guarded by the
        //    APPLIED hash and could never match.
        //  - `applied:` is the document as READ BACK, not as computed. Pages
        //    substitutes smart quotes on the keystroke path, so the text that
        //    landed is not always the text we composed; recording the computed
        //    version would arm a hash guard that can never match and make every
        //    revert refuse.
        // THE STRONGEST REFERENTIAL CLAIM THERE IS. Mary changed this
        // container because the user asked her to, so "the one you just
        // changed" and a bare "that one" should both land here — ahead of
        // anything she merely spoke about or was shown.
        //
        // Recorded on the WRITE PATH rather than at every binding that mutates,
        // because this is the one place every world's revision funnels through.
        ContainerRegistry.shared.noteEvidence(
            place: backing.place, key: found.snapshot.documentKey, .actedOn)

        if let after {
            undo.record(
                key: found.snapshot.documentKey,
                prior: found.snapshot.text,
                applied: after.text)
        }

        // 9b. RE-MINT AND FORWARD. Without this, "make it shorter still" two
        // turns later resolves `[S1]` to nothing and the only honest answer
        // left is "I don't know what that is" — about a passage Mary changed
        // thirty seconds ago.
        //
        // ONLY ON A VERIFIED WRITE: a handle minted over an unconfirmed state
        // is a guess, and a guess is what a later edit would overwrite.
        var replacement: Passage?
        if verified, let after, operation != .delete, !edited.replacement.isEmpty {
            replacement = remint(
                edited, found: found, after: after,
                registry: registry, ambient: ambient, now: now)
        }
        // A DELETE MINTS NOTHING, and nothing forwards. The words are gone, so
        // there is no passage to point `[S1]` at; the next use of the old
        // handle re-anchors, finds nothing, and refuses with "it isn't in
        // <doc> any more" — which is exactly what happened and exactly what
        // the user should hear.

        var summary = report(
            clause: PassageEdit.summaryClause(
                operation, unit: unit,
                changedFraction: reduction(write.anchor, of: edited.anchorText)),
            found: found, replacement: replacement, verified: verified)
        if !verified {
            // THE ANTI-RETRY FACT, stated in the register the veto doctrine
            // calls "an outcome, not a scolding": the change may be in the
            // document, so sending it again is the one repair that can make
            // things worse.
            summary += " It may have landed, and sending it again could apply it twice."
        }
        return SkillOutcome(
            ok: true,
            summary: summary,
            // A verified edit is the document as it now stands, keyed by
            // identity so the next edit REPLACES it. An unconfirmed one is
            // NOT a state snapshot — a snapshot of a state nothing confirmed
            // is a false deposit — so it archives episodically.
            archivePolicy: verified ? .stateSnapshot : .episodic,
            passageHandle: replacement?.handle ?? found.passage.handle,
            editDisposition: verified ? .landed : .unconfirmed)
    }

    /// WHAT THE WRITER IS ACTUALLY HANDED — and for a `.replace`, it is not
    /// the whole passage any more.
    ///
    /// MID-PASSAGE PLACEMENT IS HERS TO JUDGE. The user's decision, in their
    /// own words: "she should be intelligent enough to understand whether to
    /// insert the thought at the end, start, middle or wherever it makes the
    /// most sense." The mechanism that gives her that freedom is
    /// RECOMPOSE-AND-REPLACE — she holds the passage, rewrites it with the
    /// thought woven in where it belongs, and calls `replace_passage` — and the
    /// mechanism that keeps it from being a wholesale clobber is this line.
    /// `minimalChange` reduces "here is the section again, one sentence
    /// different" to that one sentence, widened only as far as it must be to
    /// appear exactly once. Composed with Pages' paragraph writer that is ONE
    /// `set`, ONE Apple event, and one press of Command Z to unwind by hand —
    /// and nothing else in the section moves.
    ///
    /// `from:` IS THE WHOLE BODY, NOT `anchorText`, and the distinction is
    /// load-bearing rather than tidy: `uniqueAnchor` widens until the span
    /// appears once IN THE STRING IT IS GIVEN, and uniqueness inside a fragment
    /// is not uniqueness in the document. A sentence that occurs once in the
    /// Background section and again under Scope would come back "unique" from
    /// the fragment and land in whichever of the two the writer met first.
    /// `revert` has always passed the whole body here; this follows it.
    ///
    /// THE OTHER THREE OPERATIONS PASS STRAIGHT THROUGH, on purpose. An insert
    /// deliberately keeps the anchor standing and a delete deliberately reaches
    /// OUT past the passage to swallow its blank lines (see `PassageEdit`), so
    /// both already send the smallest span that expresses what they mean —
    /// narrowing them again would be a second opinion about a shape that file
    /// already decided.
    ///
    /// Nil means NOTHING DIFFERS. See the caller.
    public static func writeSpan(
        _ operation: PassageOperation, edited: PassageEditResult,
        in body: String, hint: Range<Int>
    ) -> (anchor: String, replacement: String, range: Range<Int>)? {
        guard operation == .replace else {
            // The hint stays the passage's own resolved span, byte for byte
            // what this path has always sent. It may do exactly one thing
            // downstream — break a tie between two IDENTICAL occurrences — and
            // a hint measured against anything but the live body could only
            // break it the wrong way.
            return (edited.anchorText, edited.replacement, hint)
        }
        let change = minimalChange(from: body, to: edited.newBody)
        guard !change.anchor.isEmpty || !change.replacement.isEmpty else { return nil }
        return change
    }

    /// HOW MUCH OF THE PASSAGE THE WRITE ACTUALLY TOUCHED, 0…1 — the fact
    /// `PassageEdit.summaryClause` chooses its verb from.
    ///
    /// CLAMPED AT 1, and not defensively: `uniqueAnchor` grows the span OUTWARD
    /// until it is unique, and outward means past the passage's own edges, so a
    /// one-word change inside a paragraph that reads like its neighbour can be
    /// handed an anchor longer than the paragraph. That is a fine anchor and a
    /// nonsense fraction, and 1 is what it means: as much as the whole thing.
    public static func reduction(_ written: String, of passage: String) -> Double {
        guard !passage.isEmpty else { return 1 }
        return min(1, Double(written.count) / Double(passage.count))
    }

    /// Did the change land? Four tiers, strongest first.
    ///
    ///   1. THE HASH MATCHES what we computed. Proof, and nothing else is
    ///      needed.
    ///   2. THE DOCUMENT DID NOT CHANGE AT ALL. Proof of the opposite, and it
    ///      is a real failure mode rather than a paranoid one: an Accessibility
    ///      setter that returns `.success` and silently no-ops looks exactly
    ///      like this from here.
    ///   3. IT CHANGED, AND THE OLD WORDS ARE GONE (`.replace`, `.delete`).
    ///      Something replaced them, and something is what we sent.
    ///   4. IT CHANGED, AND IT GREW (`.insertBefore`, `.insertAfter`). An
    ///      insert deliberately keeps the anchor standing, so "the old words
    ///      are gone" would fail every successful one; length is the signal
    ///      that is left.
    ///
    /// WHY NOT "THE NEW WORDS ARE PRESENT", which is the obvious tier 3: it is
    /// false about writes that worked. Pages substitutes smart quotes and
    /// dashes as it types, so a keystroke fallback lands `isn’t` where we
    /// composed `isn't` — and a check for our own spelling would report a
    /// perfectly good replacement as unconfirmed, every time, on the one path
    /// that already had to fall back once.
    ///
    /// Everything past tier 1 is EVIDENCE rather than proof, and the report
    /// says so in its own words. The one thing that must never happen is
    /// calling it done without looking.
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

    /// Mint a handle for what is now there, forward the old one to it, and
    /// refresh the held fact that was still quoting the old wording.
    public static func remint(
        _ edited: PassageEditResult, found: Located, after: BodySnapshot,
        registry: PassageRegistry, ambient: AmbientContextStore, now: Date
    ) -> Passage? {
        // WHERE IT LANDED, and only when that is CERTAIN. Exactly one
        // occurrence in the new body, or nothing: a replacement that now
        // appears twice (the user already had that sentence elsewhere) has no
        // single home, and a handle pointing at a guess is worse than no
        // handle — the guess is what a later edit would overwrite.
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

    /// THE STALE QUOTE, SUPERSEDED. The read that produced `[S1]` registered a
    /// fact carrying that passage's words; after an edit those words are not in
    /// the document any more, and the prompt would go on offering them under
    /// "I really read them, so they are not memories to hedge about".
    ///
    /// The fact is found BY ITS HANDLE, not by matching its prose — which is
    /// the whole reason `AmbientFact.passageHandle` is a field. Its slot is
    /// reused exactly, so `AmbientContextStore.register` supersedes rather than
    /// accumulating; a new slot would leave the old wording sitting beside the
    /// new one, both claiming to be read.
    ///
    /// `clearSpoken` IS THE DIFFERENCE BETWEEN A REWRITE AND A MOVE, and it
    /// defaults to today's behaviour so the edit path is untouched. Clearing
    /// the note is right when the WORDING changed — what she said about the old
    /// prose cannot describe the new prose, and leaving it would suppress a
    /// perfectly good mention as "already spoken about". It is wrong when the
    /// passage merely MOVED, which is what `PassageRefresh` sees after a caret
    /// write above it: the words are identical, she has already told the user
    /// about them, and un-suppressing that would have her say the same thing
    /// twice about a paragraph nobody touched.
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
