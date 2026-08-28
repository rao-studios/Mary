//
//  PassageEditRunner+NarrationAndRevert.swift
//  MaryAdapter
//
//  Split out of PassageEditRunner.swift (docs/DECOMPOSITION.md Wave 4)
//  — pure relocation, no declaration changed.
//

import Foundation

extension PassageEditRunner {

    // MARK: - What she says about it

    /// The spoken report, BUILT HERE and never composed by the model.
    ///
    /// NO OFFSETS. The read persona already forbids speaking character
    /// positions aloud and it is right: "I replaced characters 68 to 916" is
    /// not a sentence anybody says, and the digits are already in the chip, the
    /// action log and the ambient fact. What a person needs to hear is WHAT
    /// changed, whether it was confirmed, and — only when the choice was a
    /// close one — what the alternative was.
    ///
    /// `clause` ARRIVES RATHER THAN BEING READ OFF `PassageEditResult`, and that
    /// is the reduction ratio's whole footprint here: `summaryClause` on the
    /// result was computed before the writer was handed anything, so it
    /// describes the operation the USER ASKED FOR; the caller knows how much of
    /// the passage the write actually moved and asks `PassageEdit` for the
    /// clause that fits what HAPPENED. One clause builder, in the file that
    /// owns the words — and `edited`/`operation` are gone from this signature
    /// because with the clause supplied there was nothing left to read off
    /// either of them.
    public static func report(
        clause: String, found: Located, replacement: Passage?, verified: Bool
    ) -> String {
        var sentence = verified
            ? "Done — I \(clause) in \(found.snapshot.documentTitle)."
            // THE UNCONFIRMED CASE GETS ITS OWN SENTENCE. It is neither a
            // success nor a failure and must not borrow either one's words: the
            // change was sent and the document did not come back to confirm it.
            : "I \(clause) in \(found.snapshot.documentTitle), but I "
                + "couldn't confirm it landed — take a look."
        if let forwardedFrom = found.forwardedFrom {
            sentence += " That was [\(forwardedFrom)]"
            if let replacement { sentence += "; it's [\(replacement.handle)] now" }
            sentence += "."
        } else if let replacement, verified {
            sentence += " That part is [\(replacement.handle)] now."
        }
        // THE UNDO OFFER IS EARNED, not routine. She decides unattended, so a
        // pick that had a real rival — or a span SHE widened to rather than one
        // the user named — is the one the user might not have meant. Offering
        // to undo every confident edit would train them to stop listening.
        let widened = found.rung == .widened
        if verified, found.confidence == .contested || widened {
            if let runnerUp = found.runnerUp, !runnerUp.label.isEmpty {
                sentence += " I went with \(spoken(found)) rather than \(runnerUp.label) — "
                    + "say the word and I'll put it back."
            } else {
                sentence += " I went with \(spoken(found)) — say the word and I'll put it back."
            }
        }
        return sentence
    }

    /// What to CALL the thing she picked, out loud. The heading when there is
    /// one, the kind's own noun otherwise — `PassageEdit.spokenSubject`'s rule,
    /// reached through the unit it already takes.
    public static func spoken(_ found: Located) -> String {
        PassageEdit.spokenSubject(PassageUnit(
            range: found.range, label: found.label, level: 0,
            kind: found.passage.unitKind))
    }

    // MARK: - revert_last_edit

    /// Put the last passage edit in this document back.
    ///
    /// THE HASH GUARD IS THE POINT, and it is `ContentUndoStore`'s own doctrine
    /// spoken aloud: the prior content comes back ONLY if the document still
    /// matches what the edit produced. Somebody who kept writing after the edit
    /// has work in there that no revert may throw away, and refusing is the
    /// only honest answer — "I won't put it back over what you've written
    /// since" is a sentence a person can act on; silently restoring a document
    /// to a state five minutes old is not.
    public static func revert(
        backing: PassageBacking,
        undo: ContentUndoStore = PassageEditRunner.undoStore
    ) async -> SkillOutcome {
        guard let writer = backing.writer else {
            return SkillOutcome(
                ok: false,
                summary: backing.writeRefusal?.errorDescription
                    ?? "I can't change things in \(backing.place.displayName).")
        }
        guard let snapshot = await backing.body() else {
            return SkillOutcome(ok: false, summary: noDocumentMessage(backing.place))
        }
        guard let prior = undo.take(for: snapshot.documentKey, currentHash: snapshot.hash) else {
            // The two "no" answers are different facts and the user acts on
            // them differently: one means look somewhere else, the other means
            // your own typing is in the way.
            guard undo.entry(for: snapshot.documentKey) != nil else {
                return SkillOutcome(
                    ok: false,
                    summary: "I don't have a change of my own to take back in "
                        + "\(snapshot.documentTitle).")
            }
            return SkillOutcome(
                ok: false,
                summary: "\(snapshot.documentTitle) has changed since I edited it, so I "
                    + "won't put it back over what you've written. Command Z will step "
                    + "back through it in the app itself.")
        }

        // THE SURGICAL REVERT. The ledger holds two whole documents, and the
        // obvious move — hand the writer the entire body and the entire prior
        // body — is the wholesale clobber the doctrine bans by name, arrived at
        // by convenience instead of intent. So the change is narrowed to the
        // span that actually differs and then WIDENED only as far as it must be
        // to be unambiguous, which is the same shape every other edit on this
        // path takes.
        let change = minimalChange(from: snapshot.text, to: prior)
        guard !change.anchor.isEmpty || !change.replacement.isEmpty else {
            return SkillOutcome(
                ok: true,
                summary: "\(snapshot.documentTitle) already reads the way it did before — "
                    + "nothing to put back.")
        }
        do {
            _ = try await writer.replace(
                change.anchor, with: change.replacement,
                hint: change.range, in: snapshot)
        } catch let error as LocalizedError {
            // The entry was CONSUMED by `take` and the write did not land, so
            // put it back — otherwise one failed revert silently spends the
            // user's only way back.
            undo.record(key: snapshot.documentKey, prior: prior, applied: snapshot.text)
            return SkillOutcome(
                ok: false,
                summary: error.errorDescription ?? "I couldn't put that back.")
        } catch {
            undo.record(key: snapshot.documentKey, prior: prior, applied: snapshot.text)
            return SkillOutcome(ok: false, summary: "I couldn't put that back.")
        }

        let after = await backing.body()
        let landed = after.map { ContentUndoStore.hash($0.text) == ContentUndoStore.hash(prior) }
            ?? false
        return SkillOutcome(
            ok: true,
            summary: landed
                ? "Put back — \(snapshot.documentTitle) reads the way it did before."
                : "I put it back, but \(snapshot.documentTitle) didn't come back to confirm "
                    + "it — take a look.",
            archivePolicy: .stateSnapshot)
    }

}
