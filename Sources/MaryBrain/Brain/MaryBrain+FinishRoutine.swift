//
//  MaryBrain+FinishRoutine.swift
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
        //
        // THE FAILURE THIS FIXES: this guard used to be `guard let routine =
        // activeRoutines[id] else { return }`, and `expireRoutine` removes the
        // entry — so a lane that came back one second after the cap had its
        // ENTIRE result discarded, silently, having already told the user "that
        // one stalled… ask me again and I'll retry". Completed work was denied
        // and the user invited to pay for it a second time. `expireRoutine`
        // parks the routine now, and this is where it is redeemed.
        //
        // A stopped or already-settled routine still returns here: `clearActive
        // Routine` removed it and nothing parked it, which is the correct
        // silence — the stop turn spoke its own acknowledgement.
        var late = false
        var claimed = clearActiveRoutine(id: id)
        if claimed == nil {
            claimed = expiredRoutines.removeValue(forKey: id)?.routine
            late = claimed != nil
        }
        guard let routine = claimed else { return }

        // Nothing actually ran (a slow NOOP) — nothing to SPEAK, but the
        // routine must still settle terminally or the app's "still working"
        // state sticks forever (the stuck-chip bug). One exception speaks:
        // an ACTION routine left "(on it)" in history and then did nothing —
        // silence would break the command's promise, so the honest line
        // rides the follow-up channel. Superseded routines stay quiet (the
        // topic change was the acknowledgement, and the command is stale), and
        // so does a LATE one — the expiry already spoke about this very
        // routine, and two sentences about one non-event is one too many.
        //
        // AND A SECOND EXCEPTION, because "action routine" was too narrow a
        // test for "the user asked for something".
        //
        // THE FAILURE THIS FIXES: "list my reminders" returned NOTHING AT ALL
        // — no reminders, no error, no sentence. `list` is a question opener,
        // so `ActionClassifier` correctly calls it a question and
        // `isActionTurn` is false; the lane then NOOPed, ran nothing, and this
        // guard settled it in perfect silence. The user asked a plain question
        // about their own reminders and got a void.
        //
        // `namesAmbientSource` is the read side's existing vocabulary for
        // "this names one of their eyeless sources" — calendar, reminders,
        // events, inbox. Reused rather than respelled. Music and the other
        // action-shaped worlds already reach the arm above, because their
        // verbs ARE action verbs; this covers the ones whose natural phrasing
        // is a question.
        let askedForSomething = routine.isActionTurn
            || NamedPartClassifier.namesAmbientSource(routine.userText)
        guard !result.outcomes.isEmpty || result.confirmQuestion != nil else {
            if askedForSomething, !routine.supersededByNewTurn, !late {
                // The line must reach HISTORY too, not just the ear and the
                // transcript — otherwise "(on it)" stands uncorrected and the
                // model keeps grounding on a command that never ran. Unless the
                // turn already said it in-turn, which is the doubled-apology
                // screenshot; `speakSettleLine` owns that judgement.
                await speakSettleLine(
                    Self.couldNotActLine(label: Self.routineLabel(from: routine.userText)),
                    originUserTurnID: routine.originUserTurnID)
            }
            proactive.yield(.routineSettled(originUserTurnID: routine.originUserTurnID))
            return
        }

        // G4 — A DETACHED REVISION SPEAKS ITS REPORT, and it is routed OUT of
        // the silent-settle arm below rather than being made an exception
        // inside it.
        //
        // THE FAILURE THIS FIXES: the arm below silences any all-ok ACTION
        // routine, on the sound argument that the chips were the reply. A
        // revision IS an all-ok action routine, and it is also the one act
        // where the chips are NOT the reply — `replace_passage` on a chip says
        // nothing about which words changed, and a Pages AX write is slow
        // enough that most revisions detach. So the correct behaviour and the
        // shipped behaviour differed by "the document changed and nobody was
        // told".
        //
        // DETERMINISTIC, AND IT BYPASSES SEER ENTIRELY — the same mechanism the
        // honest-failure lines above and in `expireRoutine` already use.
        // `speakRoutineFollowUp` would hand these outcomes to a model and ask
        // it to phrase them, which is precisely what a report about a change to
        // the user's own words may not be.
        //
        // TWO THINGS OUTRANK IT, both by falling through rather than by being
        // special-cased here: an unrecovered FAILURE (one sentence about one
        // failure, and the failure is the more important one) and a surfaced
        // CONFIRM (a question the user has to answer beats a report about what
        // already happened).
        //
        // SUPERSEDED DOES NOT SUPPRESS IT. The user moving on is not consent to
        // an unannounced edit. `mergeFollowUpIntoHistory` puts it under its own
        // exchange so the TRANSCRIPT always has it; whether it reaches the ear
        // is the follow-up floor's call, exactly as it is for `supersededRead`.
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
            proactive.yield(.routineSettled(originUserTurnID: origin))
            return
        }

        // Silent settle, FOUR ways in: an ACTION routine whose every outcome
        // landed OK (the chips already told the story), a routine the user
        // moved past — their topic change was the acknowledgement — a routine
        // that only SPAWNED deferred work (an "on it" ack is not a finished
        // result, and narrating it in completed tense would lie; the real
        // outcome arrives later on its own channel, and failures speak through
        // the coding bridge) — or a routine whose passage FETCH-FIRST already
        // spoke, which did nothing since but read it again. The history marker
        // "(on it)" gets its factual epilogue via the merge so future turns
        // know where things stand; only failures (or a surfaced CONFIRM) fall
        // through to the spoken follow-up.
        //
        // The fetch-first arm is narrowed to a read-ONLY routine on purpose:
        // "read me the part about batteries, then fix the build" pre-reads the
        // passage AND changes something, and the change still owes the user a
        // word. `isReadOnly` is the same predicate that keeps reads out of
        // Totem.
        //
        // AND NARROWED AGAIN, to reads of the world the pre-read could
        // actually have served. THE FAILURE THIS FIXES (traced): the arm was
        // "servedByPreRead && every outcome is a read", so ANY read-only lane
        // was silenced once fetch-first had fired — including the
        // `list_reminders` that held the real answer while a Pages `find` had
        // spoken a paragraph from the wrong place. Fetch-first only ever reads
        // a WORKSPACE document (`readNamedPart` needs a leading world with a
        // `targetedRead`, and only the workspace plugins declare one), so a
        // lane whose reads belong to an eyeless source cannot have been served
        // by it — by construction, not by wording. The correct answer must
        // never be suppressed.
        let concrete = result.outcomes.filter { !$0.deferred }
        // The look disjunct: a pre-lane LOOK served the request the same way
        // a workspace pre-read does, and Lane B repeating the look must not
        // double-speak the description the voice already carried in-turn.
        let servedSameRequest = routine.servedByPreRead
            && !concrete.isEmpty
            && concrete.allSatisfy { outcome in
                dispatcher?.isReadOnly(outcome.skillName) == true
                    && (dispatcher?.world(ofSkill: outcome.skillName)?.hasEyes == true
                        || dispatcher?.isLookSkill(outcome.skillName) == true)
            }

        // SUPERSEDED IS NOT WORTHLESS — and this is the arm that made it so.
        //
        // THE FAILURE THIS FIXES (confirmed against a live user session, and
        // the cheapest explanation of it: it requires nothing to be broken).
        // Every new turn marks EVERY running routine superseded (see the sweep
        // in `runTurn`), and this arm then returned without speaking. So: ask
        // what's on the calendar → the lane detaches → say anything else at all,
        // or let the ASR fire on a cough — and a COMPLETED, all-ok calendar
        // answer was discarded forever. Asking again worked, which is precisely
        // what the user reported.
        //
        // The user's decision is already on the record and it is not silence:
        // "A late follow-up never cuts in: if its originating exchange is no
        // longer on screen it waits for genuine quiet, and if the moment has
        // passed it is dropped rather than spoken into the wrong context. THE
        // TRANSCRIPT STILL SHOWS IT UNDER ITS OWN EXCHANGE." Not cutting in is
        // the FLOOR's job (`FollowUpSpeech` / the pipeline's origin gate), and
        // both of them honour it. Destroying the text before it can reach the
        // transcript pre-empts a decision that was already made.
        //
        // So a superseded routine whose concrete outcomes are all SUCCESSFUL
        // READS WITH CONTENT takes the follow-up path like any other read: the
        // passage lands in the transcript under its origin, history keeps it,
        // and the floor decides about the ear. An ACTION that landed while the
        // user moved on still settles silently — the chips were the reply, and
        // narrating a finished command late is noise rather than an answer.
        let supersededRead = routine.supersededByNewTurn
            && !concrete.isEmpty
            && concrete.allSatisfy { outcome in
                outcome.ok && dispatcher?.isReadOnly(outcome.skillName) == true
                    && !outcome.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        //
        // A LATE RESULT NEVER SETTLES SILENTLY. The user has already been told
        // this exact routine stalled and been invited to ask again; letting the
        // real answer settle without a word would leave that standing as the
        // last thing said about work that in fact completed. `!late` is the
        // whole of the correction — every other condition is unchanged.
        // A ROUTINE THAT ONLY LOOKED, ON A TURN THAT ASKED FOR A CHANGE, HAS
        // NOT FINISHED — and must never be filed as done in silence.
        //
        // THE FAILURE THIS FIXES (traced): "…can you revise that section for
        // me" ran `find_passage`, stopped, and every arm below waved it
        // through — `isActionTurn` alone is enough to settle silently, on the
        // rule that a completed fast action's chips are the reply. But the
        // chips said `find_passage`, and the revision never happened. Nothing
        // here could tell "did the thing" from "looked at the thing", because
        // every condition asks whether outcomes EXIST, never what they DID.
        //
        // The lane's own continuation is the first line of defence and this is
        // the second: if it declined to continue, the user still learns that
        // the passage was found and left alone.
        let onlyLooked = !concrete.isEmpty
            && concrete.allSatisfy { dispatcher?.isReadOnly($0.skillName) == true }
        let wantedChange = routine.editIntent != nil
            || AmbientRanker.namesTransform(routine.userText)
        // A READ WHOSE CONTENT IS ALREADY IN HAND SETTLES SILENTLY — the
        // user's decision, after machine receipts ("Sketch completed the
        // document-model command. The current page holds five top-level
        // layers.") stacked up as chat paragraphs. Those reads DEPOSIT their
        // real content ambiently (the canvas outline in "Still in hand");
        // reciting the machine summary on top is redundant, and the chip
        // modal now carries the receipt. A read whose content did NOT
        // deposit — a grocery list, a calendar — is the user's answer and
        // still speaks.
        // …EXCEPT A SCREEN LOOK. A look's summary IS the answer's content
        // ("Looked at Safari — <title>: <description>") — the exact carve-out
        // the deposit rule's last sentence names. Yesterday's ambientDeposited
        // change routed detached looks in here, which silenced the answer
        // while the origin turn's voice had already improvised a denial: the
        // lie stood uncorrected. Looks take the spoken follow-up road.
        let readsAlreadyDeposited = onlyLooked
            && concrete.allSatisfy(\.ambientDeposited)
            && !concrete.contains { dispatcher?.isLookSkill($0.skillName) == true }
        // A POLICY refusal is not an adapter failure. When every concrete
        // outcome was BLOCKED and the turn was already answered (the pre-lane
        // look served it) or the user moved on, speaking "didn't go through"
        // would announce a refusal about work the turn never needed — the
        // incident's three mismatch-mirror blocks arrived exactly here and
        // were narrated as "The changes in Xcode are done." Settle honestly
        // to the transcript; an unserved, current turn still speaks the
        // deterministic failure line below.
        let blockedOnly = !concrete.isEmpty && concrete.allSatisfy(\.blocked)
        if blockedOnly, result.confirmQuestion == nil, !late,
           routine.servedByPreRead || routine.supersededByNewTurn {
            mergeFollowUpIntoHistory(
                "(blocked: \(Self.spokenBrief(concrete[0].summary)))",
                originUserTurnID: routine.originUserTurnID)
            proactive.yield(.routineSettled(originUserTurnID: routine.originUserTurnID))
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
            proactive.yield(.routineSettled(originUserTurnID: routine.originUserTurnID))
            return
        }

        // Speak FIRST (serialized on the follow-up chain: two background
        // actions finishing together talk one-after-another — raw
        // interleaved tokens in the pipeline's single buffer garble both),
        // then settle. Settling last keeps the chip honest ("still working"
        // covers the narration) and the pipeline no longer clears its
        // buffer on settle, so another routine's terminal can't truncate
        // this one's speech.
        let originID = routine.originUserTurnID
        let originFocus = routine.originFocus
        // Captured beside `originFocus` for the same reason: the closure below
        // outlives this scope, and `speakable` needs to know whether the voice
        // already delivered this lane's look in-turn.
        let servedByPreRead = routine.servedByPreRead
        // Debugger honesty: the DETACHED read is the path that always worked
        // (it is why a slower read behaved better than a fast one), so the
        // pane can show both routes side by side and the inversion — if it
        // ever reopens — is one glance away instead of one trace.
        //
        // A MISS MINTS NO ROW. `foundNothing` is ok:true, non-deferred and
        // read-only — every gate this filter had — so the miss that was recited
        // aloud as a passage was ALSO booked here as "detached read → voice",
        // with the miss-message's character count standing in for a passage's.
        // The one instrument that exists to expose delivery failures was
        // reporting this one as a success.
        let detachedReads = result.outcomes.filter {
            $0.ok && !$0.deferred && !$0.foundNothing
                && dispatcher?.isReadOnly($0.skillName) == true
        }
        if !detachedReads.isEmpty {
            // …and a SUPERSEDED read gets its own row rather than borrowing
            // that one. `.spokenDetached` claims "detached read → voice", which
            // for a read whose exchange has already left the screen is a
            // delivery failure wearing a success's clothes — the exact class of
            // blind spot the ledger exists to close. It reaches the TRANSCRIPT;
            // whether it reaches the ear is the floor's call, and the floor
            // overwrites this row with `.heldForQuiet` / `.droppedStale` when
            // it makes it.
            //
            // AND IT CARRIES HOW LONG THE LANE TOOK, in `detail` — no new row,
            // because this is one more fact about the delivery the row already
            // describes. The duration is the whole point of the debugger line
            // for a routine: "detached read → voice" answers WHERE it went and
            // says nothing about the five minutes the user spent waiting for
            // it, which is the complaint that started this. Measured from the
            // lane's SPAWN, so it is the wait the user actually had.
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
        proactive.yield(.routineSettled(originUserTurnID: routine.originUserTurnID))
    }
}
