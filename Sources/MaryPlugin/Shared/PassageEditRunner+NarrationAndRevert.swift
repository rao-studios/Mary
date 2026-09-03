//
//  PassageEditRunner+NarrationAndRevert.swift
//  MaryPlugin
//
//  WHAT: Spoken edit report and revert_last_edit.
//  IN:   PassageEditRunner.swift (sibling split)
//  OUT:  PassageWriter via minimalChange | ContentUndoStore
//  PIN:  Hash guard — prior comes back only if the document still matches.
//

import Foundation

extension PassageEditRunner {

    // MARK: - What she says about it

    /// Spoken report, built here. Clause arrives (what happened, not what was asked).
    /// PIN: no offsets in the sentence.
    public static func report(
        clause: String, found: Located, replacement: Passage?, verified: Bool
    ) -> String {
        var sentence = verified
            ? "Done — I \(clause) in \(found.snapshot.documentTitle)."
            // Unconfirmed: own sentence — sent, not confirmed. Not success or failure.
            : "I \(clause) in \(found.snapshot.documentTitle), but I "
                + "couldn't confirm it landed — take a look."
        if let forwardedFrom = found.forwardedFrom {
            sentence += " That was [\(forwardedFrom)]"
            if let replacement { sentence += "; it's [\(replacement.handle)] now" }
            sentence += "."
        } else if let replacement, verified {
            sentence += " That part is [\(replacement.handle)] now."
        }
        // Undo offer only when contested or widened.
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

    /// Heading if present, else the kind noun. OUT: PassageEdit.spokenSubject.
    public static func spoken(_ found: Located) -> String {
        PassageEdit.spokenSubject(PassageUnit(
            range: found.range, label: found.label, level: 0,
            kind: found.passage.unitKind))
    }

    // MARK: - revert_last_edit

    /// Restore the last passage edit. PIN: prior comes back only if the hash still matches.
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
            // No entry vs hash mismatch: different sentences.
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

        // Surgical revert: unique minimal span, not the whole body.
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
            // `take` consumed the entry; write failed — put it back.
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
