//
//  MaryBrain+FollowUpSpeech.swift
//  MaryBrain
//
//  WHAT: Compose and speak one follow-up (persona, deadline, fallback).
//  IN:   finishRoutine / enqueueFollowUp
//  OUT:  Seer stream or deterministic line
//  PIN:  One filter does not answer two questions.
//
import MaryAmbient
import MaryFoundation
import MaryVoice
import Foundation
import MaryComputerUse
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
        // Ground only CONCRETE outcomes. A deferred ack ("Claude's on it") fed to the follow-up persona — "these really ran"
        let grounded = result.outcomes.filter { !$0.deferred && !$0.requested }
        // ONE FILTER WAS ANSWERING TWO QUESTIONS, and the two answers differ.
        let speakable = grounded.filter {
            $0.ok && !$0.foundNothing
                && !(servedByPreRead
                     && dispatcher?.isLookSkill($0.skillName) == true)
        }
        // ON A CONFIRM TURN THE QUESTION IS THE WHOLE REPLY.
        let confirmPending = result.confirmQuestion != nil
            && dispatcher?.hasPendingSkillConfirmation == true
        if !grounded.isEmpty, !confirmPending {
            // WHICH PERSONA THIS FOLLOW-UP GETS — the decision that made a successful calendar read present as "I checked your calendar for you", with no events in it.
            // PIN: The "did anything CHANGE?" half still asks `grounded`
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
            // ONE GUARD, ZERO LADDER DISTURBANCE.
            let onlyRestating = Self.composeWouldOnlyRestate(grounded)
            if onlyRestating {
                Self.laneLog.info(
                    "follow-up compose skipped — the plain line already says it")
            }
            var seerSpoke = false
            // Concrete failures still need the bounded voice pass: raw AX, AppleScript and process errors are not user-facing speech.
            if !onlyRestating, let seerChat, await seerChat.isReady() {
                var built = spokenMessages()
                built.append(SeerChatMessage(role: "user", content: nudge))
                // Immutable before it crosses into the bounded stream's task —
                // a captured `var` is a data race the Swift 6 mode rejects.
                let messages = built
                // THROUGH the provider, not around it. Calling MaryPrompts directly here handed the follow-up neither the capability line nor the live document/file
                let instructions = seerInstructionsProvider(pass)
                // THE ONE AWAIT THAT WEDGED THE WHOLE CHANNEL, on a deadline.
                let streamGate = EmissionGate()
                let proactive = self.proactive
                // THE ACTION PERSONA BUFFERS; the read persona streams live.
                let bufferedCompose = !readOnly
                let streamed = await bounded(speechBudget) {
                    () async -> (text: String, autoMemory: Bool) in
                    var text = ""
                    var autoMemory = false
                    do {
                        for try await event in seerChat.stream(
                            messages: messages, instructions: instructions) {
                            // THE FLAG RIDES THIS SAME STREAM, and this loop used to match `.token` alone — so `.autoMemory` fell on the floor.
                            if case .autoMemory(let flag) = event {
                                autoMemory = autoMemory || flag
                            }
                            guard case .token(let token) = event else { continue }
                            text += token
                            // Gated: a token yielded after the deadline has already spoken the fallback would re-open the transcript's per-origin accumulation and leave a bubble that never…
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
                    // THE NOUN CHECK: the grounded persona may only name applications its own evidence names.
                    if bufferedCompose, !streamed.text.isEmpty,
                       let foreign = Self.namesForeignApplication(
                           streamed.text,
                           groundedBlock: block,
                           outcomes: grounded,
                           profiles: dispatcher?.applicationProfiles ?? [],
                           owner: { dispatcher?.attention(ofSkill: $0) }) {
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
                        // Same pair the turn-side path runs in `seerTurn`: drop the folded history, tell the app to collapse.
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
                // SAME EXCLUSION AS `speakable`, for the same reason.
                let usable = grounded.filter {
                    !(servedByPreRead
                      && dispatcher?.isLookSkill($0.skillName) == true)
                }
                // A READ'S FALLBACK IS THE PASSAGE, AND IT IS NEVER DROPPED.
                //
                // PIN: THE VOICE SPOKE WITHOUT IT, WHICH IS WHY IT CANNOT BE A
                // RESTATEMENT. The `addsNothing` guard exists to stop a
                // deterministic receipt repeating what the turn already said —
                // sound reasoning for an act. For a read it is the exact wrong
                // rule: Lane A answered a question about a page having never
                // seen the page, so the passage is the one thing it did NOT
                // say, and dropping it ended the turn in silence with the
                // person still waiting. Measured as "follow-up line dropped —
                // already said in-turn" on a turn that then said nothing at all.
                let readBack = readOnly ? Self.spokenReadBack(outcomes: usable) : ""
                let line = readBack.isEmpty
                    ? Self.fallbackFollowUpLine(outcomes: usable)
                    : readBack
                if readBack.isEmpty, Self.addsNothing(line, over: originSpokenText) {
                    Self.laneLog.info("follow-up line dropped — already said in-turn")
                    readLedger.record(ReadDelivery(
                        route: .droppedAsRestating,
                        detail: usable.map(\.skillName).joined(separator: ", "),
                        characters: line.count))
                } else {
                    // Replaces any partial tokens rather than appending to them
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

        // HISTORY IS WRITTEN EVEN WHEN THE MOUTH IS SHUT.
        mergeFollowUpIntoHistory(spoken, originUserTurnID: originUserTurnID)
        guard gate.isOpen else { return }
        proactive.yield(.followUpCompleted(fullText: spoken, originUserTurnID: originUserTurnID))
    }
}
