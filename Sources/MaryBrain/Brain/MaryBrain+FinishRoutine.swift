//
//  MaryBrain+FinishRoutine.swift
//  MaryBrain
//
//  WHAT: Settle a detached routine — speak, silent, superseded, late.
//  IN:   OrchestratorLaneResult + activeRoutines / expiredRoutines
//  OUT:  follow-up speech / ledger / clear
//  PIN:  A result after the watchdog is still an answer.
//
import MaryAmbient
import MaryFoundation
import MaryVoice
import Foundation
import os

extension MaryBrain {


    // internal for file split — treat as private
    func finishRoutine(_ result: OrchestratorLaneResult, id: UUID) async {
        // A RESULT THAT ARRIVES AFTER THE WATCHDOG IS STILL AN ANSWER.
        // A stopped or already-settled routine still returns here: `clearActive Routine` removed it and nothing parked it
        var late = false
        var claimed = clearActiveRoutine(id: id)
        if claimed == nil {
            claimed = expiredRoutines.removeValue(forKey: id)?.routine
            late = claimed != nil
        }
        guard let routine = claimed else { return }

        // Nothing actually ran (a slow NOOP) — nothing to SPEAK
        let askedForSomething = routine.isActionTurn
            || NamedPartClassifier.namesAmbientSource(routine.userText)
        guard !result.outcomes.isEmpty || result.confirmQuestion != nil else {
            if askedForSomething, !routine.supersededByNewTurn, !late {
                // The line must reach HISTORY too, not just the ear and the transcript
                await speakSettleLine(
                    Self.couldNotActLine(label: Self.routineLabel(from: routine.userText)),
                    originUserTurnID: routine.originUserTurnID)
            }
            proactive.yield(.routineSettled(
                routineID: routine.id, originUserTurnID: routine.originUserTurnID))
            return
        }

        // G4 — A DETACHED REVISION SPEAKS ITS REPORT, and it is routed OUT of the silent-settle arm below rather than being made an exception inside it.
        if result.confirmQuestion == nil,
           Self.unrecoveredFailure(in: result.outcomes) == nil,
           let report = EditReport.report(
            intent: routine.editIntent, target: routine.locatedTarget,
            writingTarget: routine.writingTarget,
            outcomes: result.outcomes) {
            let origin = routine.originUserTurnID
            let line = report.sentence
            mergeFollowUpIntoHistory(line, originUserTurnID: origin)
            await enqueueFollowUp(origin: origin) { [weak self] gate in
                guard gate.isOpen else { return }
                self?.proactiveYield(.followUpToken(line, originUserTurnID: origin))
                self?.proactiveYield(.followUpCompleted(fullText: line, originUserTurnID: origin))
            }
            proactive.yield(.routineSettled(routineID: routine.id, originUserTurnID: origin))
            return
        }

        // Silent settle, FOUR ways in: an ACTION routine whose every outcome landed OK (the chips already told the story), a routine the user moved past
        let concrete = result.outcomes.filter { !$0.deferred }
        // The look disjunct: a pre-lane LOOK served the request the same way
        // a workspace pre-read does, and Lane B repeating the look must not
        // double-speak the description the voice already carried in-turn.
        let servedSameRequest = routine.servedByPreRead
            && !concrete.isEmpty
            && concrete.allSatisfy { outcome in
                dispatcher?.isReadOnly(outcome.skillName) == true
                    && (dispatcher?.attention(ofSkill: outcome.skillName)?.hasEyes == true
                        || sight?.isLookSkill(outcome.skillName) == true)
            }

        // Superseded successful reads still take the follow-up path.
        let supersededRead = routine.supersededByNewTurn
            && !concrete.isEmpty
            && concrete.allSatisfy { outcome in
                outcome.ok && dispatcher?.isReadOnly(outcome.skillName) == true
                    && !outcome.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        // A LATE RESULT NEVER SETTLES SILENTLY. The user has already been told this exact routine stalled and been invited to ask again
        let onlyLooked = !concrete.isEmpty
            && concrete.allSatisfy { dispatcher?.isReadOnly($0.skillName) == true }
        let wantedChange = routine.editIntent != nil
            || AmbientRanker.namesTransform(routine.userText)
        // A READ WHOSE CONTENT IS ALREADY IN HAND SETTLES SILENTLY — the user's decision, after machine receipts ("Sketch completed the document-model command.
        let readsAlreadyDeposited = onlyLooked
            && concrete.allSatisfy(\.ambientDeposited)
            && !concrete.contains { sight?.isLookSkill($0.skillName) == true }
        // A POLICY refusal is not an adapter failure.
        let blockedOnly = !concrete.isEmpty && concrete.allSatisfy(\.blocked)
        if blockedOnly, result.confirmQuestion == nil, !late,
           routine.servedByPreRead || routine.supersededByNewTurn {
            mergeFollowUpIntoHistory(
                "(blocked: \(Self.spokenBrief(concrete[0].summary)))",
                originUserTurnID: routine.originUserTurnID)
            proactive.yield(.routineSettled(
                routineID: routine.id, originUserTurnID: routine.originUserTurnID))
            return
        }
        if result.confirmQuestion == nil, !late,
           result.outcomes.allSatisfy({ $0.ok }),
           !result.outcomes.contains(where: { $0.foundNothing }),
           !(wantedChange && onlyLooked),
           routine.isActionTurn || (routine.supersededByNewTurn && !supersededRead)
               || concrete.isEmpty || servedSameRequest
               || readsAlreadyDeposited {
            mergeFollowUpIntoHistory(
                Self.doneMarker(outcomes: result.outcomes),
                originUserTurnID: routine.originUserTurnID)
            proactive.yield(.routineSettled(
                routineID: routine.id, originUserTurnID: routine.originUserTurnID))
            return
        }

        // Speak FIRST (serialized on the follow-up chain: two background actions finishing together talk one-after-another
        let originID = routine.originUserTurnID
        let originFocus = routine.originFocus
        // Captured beside `originFocus` for the same reason: the closure below
        // outlives this scope, and `speakable` needs to know whether the voice
        // already delivered this lane's look in-turn.
        let servedByPreRead = routine.servedByPreRead
        // Debugger honesty: the DETACHED read is the path that always worked (it is why a slower read behaved better than a fast one)
        let detachedReads = result.outcomes.filter {
            $0.ok && !$0.deferred && !$0.foundNothing
                && dispatcher?.isReadOnly($0.skillName) == true
        }
        if !detachedReads.isEmpty {
            // …and a SUPERSEDED read gets its own row rather than borrowing that one.
            let skills = detachedReads.map(\.skillName).joined(separator: ", ")
            let took = "lane took \(Self.spokenDuration(since: routine.spawnedAt))"
            readLedger.record(ReadDelivery(
                route: supersededRead ? .supersededToTranscript : .spokenDetached,
                detail: supersededRead
                    ? "\(skills) — the user had moved on, \(took)"
                    : "\(skills) — \(took)",
                characters: detachedReads.reduce(0) { $0 + $1.summary.count }))
        }
        await enqueueFollowUp(origin: originID) { [weak self] gate in
            await self?.speakRoutineFollowUp(
                result: result, originUserTurnID: originID,
                originFocus: originFocus,
                servedByPreRead: servedByPreRead, gate: gate)
        }
        proactive.yield(.routineSettled(
                routineID: routine.id, originUserTurnID: routine.originUserTurnID))
    }
}
