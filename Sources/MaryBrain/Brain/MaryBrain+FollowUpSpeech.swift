//
//  MaryBrain+FollowUpSpeech.swift
//

import MaryAmbient
import MaryFoundation
import MaryVoice
import Foundation
import os

extension MaryBrain {


    func speakRoutineFollowUp(
        result: OrchestratorLaneResult,
        originUserTurnID: UUID,
        originFocus: WorkspaceFocus?,
        servedByPreRead: Bool,
        gate: EmissionGate
    ) async {
        var spoken = ""
        // What the origin turn already said, read once — the baseline both
        // dedupe guards compare against.
        let originSpokenText = originAssistantText(originUserTurnID: originUserTurnID)
        // Ground only CONCRETE outcomes. A deferred ack ("Claude's on it")
        // fed to the follow-up persona — "these really ran" — would be
        // narrated in completed tense while the work is still running; the
        // real result reports later on its own channel. A REQUESTED park is
        // excluded for the harder reason: it is ok:true and not deferred, so
        // without its own filter it read as a finished success, went into the
        // grounded block under "your helper just finished those actions", and
        // the voice claimed the change had happened — the live "The text is
        // now in Times New Roman" for a script that never ran.
        let grounded = result.outcomes.filter { !$0.deferred && !$0.requested }
        // ONE FILTER WAS ANSWERING TWO QUESTIONS, and the two answers differ.
        //
        // `grounded` answers "is there anything to REPORT?" — a failure and a
        // miss both belong in it, because a turn that failed or found nothing
        // still owes the user a word. `speakable` answers "is there anything to
        // RECITE?", and that set is narrower by exactly the two things which are
        // not content: something that went wrong, and something that isn't there
        // (`SkillOutcome.foundNothing` — "a miss may never be dressed as a
        // passage").
        //
        // THE FAILURE THIS FIXES: with one set doing both jobs, a detached
        // `pages_body` miss passed every gate below — ok, non-deferred,
        // read-only — took the READ persona and `readBackNudge` ("read it back
        // to them: give them the words"), and Mary read the miss-message out
        // as though it were the passage.
        //
        // AND NARROWER AGAIN BY ONE MORE THING THAT IS NOT NEW CONTENT: a look
        // the voice ALREADY delivered in-turn.
        //
        // THE FAILURE THIS FIXES (live, in the transcript): the fireplace-video
        // turn spoke the description once as Lane A prose and then again as a
        // greyed follow-up paragraph. `servedSameRequest` was meant to stop
        // that, but it is `allSatisfy` — deliberately, so an eyeless read
        // carrying the real answer can never be silenced by a look beside it —
        // so a look PLUS any eyeless read failed the whole test and the lane
        // took the READ persona over both. All-or-nothing was the wrong
        // altitude: the question "was this outcome already spoken?" is per
        // OUTCOME, and answering it here leaves the eyeless read speaking and
        // drops only the repeat. A look-ONLY lane never reaches this line —
        // `servedSameRequest` settles it silently above.
        let speakable = grounded.filter {
            $0.ok && !$0.foundNothing
                && !(servedByPreRead
                     && dispatcher?.isLookSkill($0.skillName) == true)
        }
        // ON A CONFIRM TURN THE QUESTION IS THE WHOLE REPLY. Composing a
        // follow-up sentence around a parked action buys a model round to
        // risk reinventing exactly the completion claim the `requested`
        // filter above just removed — and the question is already held
        // verbatim, so there is nothing for a model to add. The legacy loop
        // has answered this way all along (`actionTurn` relays the question
        // and nothing else); this brings the detached road to the same rule.
        let confirmPending = result.confirmQuestion != nil
            && dispatcher?.hasPendingSkillConfirmation == true
        if !grounded.isEmpty, !confirmPending {
            // WHICH PERSONA THIS FOLLOW-UP GETS — the decision that made a
            // successful calendar read present as "I checked your calendar for
            // you", with no events in it.
            //
            // THE FAILURE THIS FIXES (traced): every detached follow-up used
            // the ACTION persona — "You just FINISHED actions… ONE short
            // spoken sentence… never repeat the content that was written" —
            // with the results 500-char-clamped inside it. That is literally
            // an instruction not to read a passage aloud, and a turn whose
            // only outcomes were READS has nothing else to say. The READ
            // persona ("reciting IS the answer") was built for exactly this
            // and was never produced: `readReport` was set nowhere in the
            // tree, so the fix for the bug was unreachable.
            //
            // A routine whose every concrete outcome is a READ takes it, with
            // `readPassageBlock`'s far larger clamp (2,400 per result rather
            // than 500 — `PagesPlugin.regionSpan` alone is 1,800, and a day of
            // events is longer than a sentence). Anything that CHANGED
            // something keeps the action persona: its job is to report an
            // outcome, not recite a document. The two are mutually exclusive
            // at this call site, as `SeerPass` requires.
            //
            // A READ PERSONA WITH NOTHING TO RECITE IS THE BUG, NOT THE FIX.
            // `allSatisfy` is vacuously true of the empty set, so a routine
            // whose only read MISSED would still take the read persona and be
            // handed an empty passage — the "I checked your calendar for you"
            // shape again, this time with the miss where the events should be.
            // Nothing to recite means the ACTION persona, whose job is to report
            // an outcome rather than to read a document.
            //
            // The "did anything CHANGE?" half still asks `grounded`, not
            // `speakable`: a lane that read one thing and failed to write
            // another must not be narrated by the persona that recites and
            // never mentions the write. This predicate is therefore strictly
            // narrower than the one it replaces — it can only move a routine
            // from the read persona to the action persona, never the reverse,
            // so no failure can be silenced by it.
            let readOnly = !speakable.isEmpty
                && grounded.allSatisfy { dispatcher?.isReadOnly($0.skillName) == true }
            let block = readOnly
                ? Self.readPassageBlock(outcomes: speakable)
                : Self.groundedResultsBlock(outcomes: grounded)
            let pass = readOnly
                ? SeerPass(readPassages: [block], readReport: true, assertedFocus: originFocus)
                : SeerPass(groundedResults: block, assertedFocus: originFocus)
            let nudge = readOnly
                ? MaryPrompts.readBackNudge : MaryPrompts.followUpNudge
            // DON'T PAY TO REPHRASE A SENTENCE YOU ALREADY HAVE.
            //
            // THE FAILURE THIS FIXES (confirmed against a live user session):
            // "the latest note I made in the Notes app". Notes was not running,
            // the binding said so in microseconds — and this turn then spent its
            // FULL `speechBudget` (20 s) asking a hosted model to restate that
            // one sentence. It produced nothing, left a `.chainStalled` row, and
            // the line the user finally heard was the deterministic one below,
            // which had been in hand since t = 0. Twenty seconds of dead air to
            // rephrase a sentence nobody needed rephrased.
            //
            // ONE GUARD, ZERO LADDER DISTURBANCE. The body still runs inside its
            // bounded rung, the nesting (speech 20 < body 25 < chainWait 30 <
            // handoff 60) is unchanged and still strict, both `EmissionGate`
            // checks are untouched, and the producer below is unchanged. THIS
            // CHANGES WHEN THE LINE IS SPOKEN, NEVER WHAT IT SAYS — see
            // `composeWouldOnlyRestate`, whose whole safety argument is that
            // `fallbackFollowUpLine` returns this outcome's own summary verbatim
            // exactly when the predicate is true.
            //
            // AND IT MINTS NO LEDGER ROW. A skip can only fire on a MISS, and
            // three lines above `detachedReads` this file already states A MISS
            // MINTS NO ROW; a `.chainStalled` row here would book the fix as the
            // failure it removes, in the one instrument that exists to expose
            // delivery failures. Logged instead, beside the lane log the
            // timed-out arm below writes to.
            let onlyRestating = Self.composeWouldOnlyRestate(grounded)
            if onlyRestating {
                Self.laneLog.info(
                    "follow-up compose skipped — the plain line already says it")
            }
            var seerSpoke = false
            // Concrete failures still need the bounded voice pass: raw AX,
            // AppleScript and process errors are not user-facing speech. The
            // nudge above now carries the hard honesty rule, so the composer
            // may phrase a failure but may never turn it into completion.
            if !onlyRestating, let seerChat, await seerChat.isReady() {
                var built = spokenMessages()
                built.append(SeerChatMessage(role: "user", content: nudge))
                // Immutable before it crosses into the bounded stream's task —
                // a captured `var` is a data race the Swift 6 mode rejects.
                let messages = built
                // THROUGH the provider, not around it. Calling MaryPrompts
                // directly here handed the follow-up neither the capability
                // line nor the live document/file — and this is the turn
                // most exposed to retrieval, because it speaks about work
                // that just changed the very document memory describes.
                //
                // …but through it with the ORIGINATING world, not the ambient
                // one. This code path runs after `runTurn`'s defer cleared the
                // utterance override, so resolving live here would make a
                // routine born from "proofread this paragraph" report back in
                // Xcode's voice, about Xcode's file, scoped to Xcode's group.
                let instructions = seerInstructionsProvider(pass)
                // THE ONE AWAIT THAT WEDGED THE WHOLE CHANNEL, on a deadline.
                //
                // THE FAILURE THIS PREVENTS (confirmed against a live user
                // session): this `for try await` was the single poisonable
                // entry on the follow-up chain, and it had no wall clock at
                // all. `SeerChatClient` sets `request.timeoutInterval = 300`,
                // but that is URLSession's IDLE timer over
                // `URLSession.shared.bytes(for:)` — an SSE stream emitting
                // heartbeats and no `data:` chunks resets it on every byte and
                // never fires (`timeoutIntervalForResource` defaulted to seven
                // days). The client carries a wall-clock resource cap now; this
                // is the second, nearer floor, sized to a spoken reply rather
                // than to a network.
                //
                // Past the budget the answer is RECITED PLAINLY rather than
                // lost: the deterministic fallback line below carries the same
                // outcome without the model's phrasing.
                // TWO GATES, AND THEY GUARD DIFFERENT RACES. `streamGate` is
                // this stream's own: it closes when the speech budget expires
                // so a straggling token cannot re-open a bubble the fallback
                // line has already completed. `gate` is the CHAIN's, closed
                // from outside when this whole body was stepped over or ran
                // past its budget — at which point everything below is speaking
                // into somebody else's audio.
                let streamGate = EmissionGate()
                let proactive = self.proactive
                // THE ACTION PERSONA BUFFERS; the read persona streams live.
                // A composed "confirmation" must pass the noun check below
                // BEFORE any token reaches the ear — tokens cannot be unsaid,
                // and the sentence being checked is one short line by the
                // nudge's own demand, so buffering costs nothing audible.
                let bufferedCompose = !readOnly
                let streamed = await bounded(speechBudget) {
                    () async -> (text: String, autoMemory: Bool) in
                    var text = ""
                    var autoMemory = false
                    do {
                        for try await event in seerChat.stream(
                            messages: messages, instructions: instructions) {
                            // THE FLAG RIDES THIS SAME STREAM, and this loop
                            // used to match `.token` alone — so `.autoMemory`
                            // fell on the floor. That mattered more here than
                            // anywhere: the follow-up request is the ONE shape
                            // that reaches Seer's threshold, because the nudge
                            // appended above adds a user message on top of the
                            // rolling window. Seer wrote the memory and
                            // answered true; nothing downstream ever heard it.
                            if case .autoMemory(let flag) = event {
                                autoMemory = autoMemory || flag
                            }
                            guard case .token(let token) = event else { continue }
                            text += token
                            // Gated: a token yielded after the deadline has
                            // already spoken the fallback would re-open the
                            // transcript's per-origin accumulation and
                            // leave a bubble that never completes.
                            guard streamGate.isOpen, gate.isOpen else { break }
                            if !bufferedCompose {
                                proactive.yield(
                                    .followUpToken(token, originUserTurnID: originUserTurnID))
                            }
                        }
                    } catch {
                        // The flag survives a mid-stream throw: the memory was
                        // written server-side whether or not the text arrived.
                        return ("", autoMemory)
                    }
                    return (text, autoMemory)
                }
                streamGate.close()
                if let streamed {
                    // THE NOUN CHECK: the grounded persona may only name
                    // applications its own evidence names. "The Sketch edits
                    // are done" over textedit outcomes — Sketch closed,
                    // nothing edited — came from held facts riding the
                    // follow-up prompt; nothing between the model and the
                    // mouth compared the sentence to the outcomes. Same
                    // union-conservative shape as the mismatch mirror:
                    // mentioned in the composed text, absent from the
                    // grounded block, owning none of the outcomes → rejected,
                    // and the deterministic line below speaks instead.
                    if bufferedCompose, !streamed.text.isEmpty,
                       let foreign = Self.namesForeignApplication(
                           streamed.text,
                           groundedBlock: block,
                           outcomes: grounded,
                           profiles: dispatcher?.applicationProfiles ?? [],
                           owner: { dispatcher?.world(ofSkill: $0) }) {
                        Self.laneLog.error(
                            "follow-up compose rejected — named \(foreign, privacy: .public) with no such outcome")
                        // Fall through as if the model never spoke: the
                        // !seerSpoke arm below recites the honest line.
                    } else {
                        if bufferedCompose, !streamed.text.isEmpty, gate.isOpen {
                            proactive.yield(.followUpToken(
                                streamed.text, originUserTurnID: originUserTurnID))
                        }
                        spoken = streamed.text
                        seerSpoke = !streamed.text.isEmpty
                    }
                    if streamed.autoMemory {
                        // Same pair the turn-side path runs in `seerTurn`:
                        // drop the folded history, tell the app to collapse.
                        // It goes out on the PROACTIVE channel because the
                        // turn's own continuation finished long ago — this
                        // narration outlived it.
                        truncateAfterAutomemory()
                        proactive.yield(.autoMemoryTriggered)
                    }
                } else {
                    Self.laneLog.error("follow-up speech timed out — reciting the plain line")
                    readLedger.record(ReadDelivery(
                        route: .chainStalled,
                        detail: "follow-up speech timed out after \(Int(speechBudget))s",
                        characters: 0))
                }
            }
            if !seerSpoke {
                // SAME EXCLUSION AS `speakable`, for the same reason. This is
                // the OTHER road to the user's ear — the deterministic one,
                // taken when Seer never spoke — and reading raw `grounded`
                // would let it restate the look the voice already delivered
                // in-turn, which is the duplicate paragraph the per-outcome
                // filter above exists to stop. `addsNothing` below catches it
                // only when the wording happens to match, and Lane A
                // paraphrases.
                let line = Self.fallbackFollowUpLine(
                    outcomes: grounded.filter {
                        !(servedByPreRead
                          && dispatcher?.isLookSkill($0.skillName) == true)
                    })
                // A deterministic line that restates what the turn already
                // said is dropped, not spoken — the live report's greyed
                // duplicate ("All TextEdit windows are now forward." above
                // "All TextEdit windows are up.") was this line riding under
                // an in-turn sentence describing the same outcomes. Streamed
                // compose text is deliberately NOT guarded: a paraphrase
                // doesn't text-match, and `composeWouldOnlyRestate` owns that
                // judgement.
                if Self.addsNothing(line, over: originSpokenText) {
                    Self.laneLog.info("follow-up line dropped — already said in-turn")
                } else {
                    // Replaces any partial tokens rather than appending to them —
                    // `.followUpCompleted` carries `spoken` as the final text and
                    // the composer's `completed(fullText:)` overwrites with it, so
                    // the transcript ends holding the whole honest line and nothing
                    // half-streamed.
                    spoken = line
                    if gate.isOpen {
                        proactive.yield(.followUpToken(line, originUserTurnID: originUserTurnID))
                    }
                }
            }
        }

        // A protected action surfaced mid-routine: the follow-up asks; the
        // user's next bare yes/no executes deterministically as always.
        if confirmPending, let question = result.confirmQuestion,
           !Self.addsNothing(question, over: originSpokenText + " " + spoken) {
            // The containment guard closes the confirm-turn double-ask: with
            // the preview now spoken verbatim on both roads, the in-turn relay
            // and this append would otherwise emit the identical sentence.
            let sentence = spoken.isEmpty ? question : " \(question)"
            spoken += sentence
            if gate.isOpen {
                proactive.yield(.followUpToken(sentence, originUserTurnID: originUserTurnID))
            }
        }

        // HISTORY IS WRITTEN EVEN WHEN THE MOUTH IS SHUT. A stepped-over
        // follow-up may not be HEARD — its successor owns the audio — but the
        // work really happened, and dropping the epilogue would leave "(on it)"
        // standing in the model's history for a command that finished.
        mergeFollowUpIntoHistory(spoken, originUserTurnID: originUserTurnID)
        guard gate.isOpen else { return }
        proactive.yield(.followUpCompleted(fullText: spoken, originUserTurnID: originUserTurnID))
    }
}
