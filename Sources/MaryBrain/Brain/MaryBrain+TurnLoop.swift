//
//  MaryBrain+TurnLoop.swift
//  MaryBrain
//
//  The turn loop, moved out of MaryBrain.swift: `runTurn` (supersede,
//  epoch reservation, unwind) and `runTurnBody` (the whole turn — route
//  resolution, pre-reads, gates, and the seer/legacy handoff). Both moved
//  WHOLE and verbatim — no function was split; no behavior change.
//
//  Depends on the internal-for-split promotions of the core file's stored
//  turn state (history, turnBox, openExchange, dispatchers, budgets…);
//  treat all of them as private.
//

import MaryVoice
import Foundation
import os

extension MaryBrain {

    // MARK: - The turn loop

    // internal for file split — treat as private
    func runTurn(
        userText: String,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation,
        epoch: UInt64,
        superseding: Bool
    ) async {
        // A request owns the exact source selection that existed before the
        // request UI became frontmost.  This is task-local rather than a
        // mutable global seal: a cancelled older turn cannot clear or replace
        // a newer turn's selection, and a new event mid-generation waits for
        // the next request.
        //
        // Workspace deactivation is delivered asynchronously. The coordinator
        // retries only a source that yielded within its tiny lifecycle window,
        // closing select → ask races without turning remembered workspace
        // focus into a selection-routing input.
        await SelectionHandoffCoordinator.shared.capturePendingSourceAsync()
        // Voice/hands-free input can begin while the source app remains
        // frontmost, so there is no deactivate → composer transition at all.
        // Capture only that app's exact selection ability before freezing the
        // turn.  The broader document/context refresher deliberately stays
        // inside the TaskLocal scope below: it may enrich state, but it must
        // not decide what this already-started request selected.
        await SelectionHandoffCoordinator.shared.captureFrontmostExternalSourceAsync()
        // Ability Studio can activate a new registry while this request is
        // generating. Freeze package identity, invocation aliases, routing
        // policy, and presentation with the selection claim so one turn can
        // never begin under one schema revision and dispatch under another.
        let abilitySnapshot = dispatcher?.abilitySnapshot
            ?? AbilityLibrary.shared.snapshotEnsuringLoaded()
        // A source-owned selection is one machine Interaction, but natural
        // conversation can refer to it across adjacent sentences. Preserve
        // the most recently claimed packet only for an explicitly deictic or
        // revision-shaped follow-up; unrelated turns still see no historical
        // selection and cannot accidentally route through it.
        let mayReferenceSelection = AmbientRanker.isDeictic(userText)
            || EditIntentClassifier.intent(in: userText) != nil
        let snapshot = AmbientSelectionTurnSnapshot(
            handoff: ambient.snapshotSelectionForTurn(
                allowingRecentClaimed: mayReferenceSelection))
        let signalSnapshot = SchemaSignalRuntime.shared.snapshotForTurn(
            registry: abilitySnapshot,
            ambientSelection: snapshot.handoff)
        await AbilityTurnContext.$snapshot.withValue(abilitySnapshot) {
            await SchemaSignalTurnContext.$snapshot.withValue(signalSnapshot) {
                await AmbientSelectionTurnContext.$snapshot.withValue(snapshot) {
                    await AmbientRouteTurnContext.$state.withValue(
                        AmbientRouteTurnState()
                    ) {
                        await self.runTurnBody(
                            userText: userText,
                            continuation: continuation,
                            epoch: epoch,
                            superseding: superseding)
                    }
                }
            }
        }
    }

    private func runTurnBody(
        userText: String,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation,
        epoch: UInt64,
        superseding: Bool
    ) async {
        defer { turnBox.retire(epoch) }
        if superseding {
            // The superseded turn's exchange — its user turn, any Skill pairs,
            // any partial reply that landed before the epoch bump — is
            // replaced wholesale by the amended query. The amend contract:
            // no .exchangeSuperseded here — the voice amend UI rewrites its
            // bubbles in place (turnSuperseded/userAmended).
            removeLastExchange()
        } else if turnBox.isCurrent(epoch), let open = openExchange {
            // Overlap-supersede: a plain respond() landed while another turn
            // was mid-flight. The old turn's partial exchange leaves history
            // AND the transcript together — the event carries the removed
            // exchange's user-turn id so the UI drops the SAME bubbles, and
            // it precedes .turnBegan so the page is clean before the new
            // identity stamps it. The removal is decided on HISTORY STATE,
            // not timing: an exchange that already carries a non-empty
            // assistant turn is CLOSED — a completed reply whose entry
            // survived the guarded-clear race, or a barge-in partial the
            // keep-partial contract protects — and stays. Only a reply-less
            // exchange leaves; a cancelled turn too slow to land its partial
            // before the user asked again resolves as a replace (the amend
            // flow's semantics), never a corrupt half-state. A newcomer that
            // is itself already stale leaves the entry for its superseder.
            openExchange = nil
            if exchangeIsOpen(anchoredAt: open.userTurnID) {
                removeExchange(anchoredAt: open.userTurnID)
                continuation.yield(.exchangeSuperseded(userTurnID: open.userTurnID))
            }
        }
        // A HELD DICTATION SESSION OWNS THE UTTERANCE OUTRIGHT.
        //
        // The deterministic paths further down each answer ONE closed utterance
        // without the model — a bare yes/no, a bare stop. This answers EVERY
        // utterance until it is closed, because that is exactly what the user
        // asked for when they said "take this down". A novelist's sentence is
        // not a command and must never be asked whether it is one.
        //
        // THE PLACEMENT IS THE DESIGN. Everything below is skipped, and each
        // omission is deliberate:
        //
        //   - `turnContextPreparer`: a whole-workspace refresh per dictated
        //     sentence is the latency that would make this unusable.
        //   - `setTurnOverride`: prose must not rewrite where the user is.
        //   - `ambient.noteUtterance`: THE MOMENT both prompt lanes rank
        //     against. Forty sentences of a novel would poison the ranking of
        //     every later turn.
        //   - `appendHistory(userTurn)`: dictated prose is manuscript, not
        //     conversation. It would fill the rolling window and walk straight
        //     through writing.mary's own guardrail — "raw selected or written
        //     text never enters durable receipts" — by the back door.
        //   - the bare decision and bare stop gates: a novelist who dictates
        //     "No." or "Cancel." must not cancel Mary's routines. Inside a
        //     session the address is the only stop.
        //
        // An armed CONFIRM still wins, and is the one thing that does: a
        // question already asked must not be answered by typing the answer
        // into a manuscript.
        let pendingConfirmationArmed = dispatcher?.hasPendingSkillConfirmation ?? false
        if !pendingConfirmationArmed || Self.bareDecision(in: userText) == nil {
            if DictationSession.shared.isHeld() {
                if await runHeldDictationTurn(
                    userText: userText, continuation: continuation, epoch: epoch) {
                    continuation.finish()
                    return
                }
            } else if Self.dictationOpener(in: userText) {
                await openDictationSession(
                    userText: userText, continuation: continuation, epoch: epoch)
                continuation.finish()
                return
            }
        }

        if let prepare = turnContextPreparer {
            _ = await withNanosecondBudget(Self.turnContextRefreshBudgetNanoseconds) {
                await prepare()
                return Optional(())
            }
            if Task.isCancelled {
                continuation.finish()
                return
            }
        }
        dispatcher?.beginTurn()

        // The utterance may name a domain ("add a scene…", "fix the build…").
        // That overrides ambient focus for THIS turn so the named world's
        // context and Skills lead even when the other app is frontmost —
        // the "if I do name it, it must work" guarantee. Window truth
        // (current()) is untouched — a word must never rewrite where the
        // user actually is. Cleared at every exit so it never leaks to the
        // next turn or a detached follow-up.
        focusTracker.setTurnOverride(FocusOverride.classifyOverride(utterance: userText))
        defer { focusTracker.clearTurnOverride() }
        // THE MOMENT, published before either prompt is built. The ambient
        // store's budget policy ranks by "relevance to the current utterance",
        // and the SYSTEM prompt provider is a zero-argument closure — putting
        // the utterance in the store rather than widening two provider
        // signatures is what lets both lanes rank against the same words.
        // Deliberately NOT cleared on exit: between turns the last thing the
        // user said is still the situational moment, and a detached routine's
        // follow-up should rank against the request that spawned it.
        ambient.noteUtterance(userText)

        let userTurn = BrainTurn(role: .user, text: userText)
        // The turn's identity leads every path — deterministic decision,
        // bare-stop, legacy, seer — so the app can stamp the exchange before
        // any token or chip arrives.
        continuation.yield(.turnBegan(id: userTurn.id))
        // A turn arriving on the heels of a remark is that remark being
        // answered — the one thing that earns her the next one.
        appendHistory(userTurn, epoch: epoch)
        // Adjacency bookkeeping for the acceptance gate: what was the
        // PREVIOUS turn, before this one becomes it.
        let precedingUserTurnID = lastUserTurnID
        lastUserTurnID = userTurn.id
        // THE EPISODE OPENS WITH THE TURN'S OWN IDENTITY — one user turn is
        // one episode, and inventing a second id for the same thing would
        // mean joining them forever after. `priorEpisodeID` chains turns
        // instead of embedding history, so a conversation is a linked list of
        // episodes rather than an episode that grows without bound.
        wiring.behavior.openEpisode(
            id: userTurn.id,
            query: userText,
            priorEpisodeID: precedingUserTurnID,
            provenance: behavioralProvenance())
        if turnBox.isCurrent(epoch) { openExchange = (userTurn.id, epoch) }
        // Guarded clear: only a turn that exits while still CURRENT —
        // completed, or barge-in cancelled with no replacement — closes its
        // own exchange. A SUPERSEDED turn's epoch is stale by the time it
        // unwinds; it must leave the entry in place for the replacing turn
        // to consume (a fast unwind can beat the new runTurn onto the
        // actor), and the epoch match keeps a LATE unwind from nulling the
        // new turn's own entry.
        defer {
            if let open = openExchange, open.epoch == epoch, turnBox.isCurrent(epoch) {
                openExchange = nil
            }
            // SEALED ON THE WAY OUT, whichever way out this turn took.
            //
            // The reason is read from the SAME epoch test the exchange clear
            // uses, so the two can never disagree about whether this turn was
            // replaced: a turn still current when it unwinds completed (or was
            // cancelled by a barge-in, which the record's own dispositions
            // show); a turn whose epoch is stale was superseded, and its
            // replacement is already running.
            //
            // `seal` defers itself while detached routines are still in
            // flight, so a turn that spawned background work is not filed as
            // finished until that work is.
            wiring.behavior.seal(
                userTurn.id,
                reason: turnBox.isCurrent(epoch) ? .completed : .superseded)
        }
        trimHistory()

        // A pending action + a bare yes/no is not the model's decision to
        // make — small models re-ask or re-run the original command instead
        // of calling confirm_pending_skill, looping forever. Execute the
        // user's answer deterministically; the model only narrates the
        // grounded result. (An overlap-supersede may have removed the
        // QUESTION's exchange while dispatcher.hasPendingSkillConfirmation stayed
        // armed — a later bare "yes" still executes deterministically,
        // identical to the amend flow's behavior today.)
        // THE TURN AS IT ARRIVED, read ONCE and before the deterministic
        // paths below consume it. `hasPendingSkillConfirmation` goes false the instant a
        // confirm dispatches and `activeRoutines` is emptied by a bare stop,
        // so anything asking afterwards describes a turn that never happened.
        // `bareDecision` is pure, and was being computed twice below.
        let bareDecision = Self.bareDecision(in: userText)
        let hadPendingAction = dispatcher?.hasPendingSkillConfirmation ?? false
        let routinesAtEntry = activeRoutines.count

        var decisionOutcome: SkillOutcome?
        if let dispatcher, dispatcher.hasPendingSkillConfirmation,
           let approved = bareDecision {
            let skillName = approved
                ? AbilityRuntime.confirmSkillName
                : AbilityRuntime.cancelSkillName
            let invocation = ModelSkillInvocation(
                id: "decision-\(UUID().uuidString)", name: skillName, argumentsJSON: "{}")
            let invocationReference = dispatcher.skillReference(for: skillName)
            continuation.yield(.skillInvocation(
                reference: invocationReference, argumentsJSON: "{}",
                runID: invocation.id))
            let startedAt = Date()
            let outcome = await dispatcher.dispatch(
                name: skillName, argumentsJSON: "{}", runID: invocation.id)
            continuation.yield(.skillResult(record: BehavioralActionRecord(
                outcome: outcome,
                intention: skillName,
                argumentsJSON: "{}",
                reference: invocationReference,
                runID: invocation.id,
                startedAt: startedAt)))
            appendHistory(contentsOf: [
                BrainTurn(role: .assistant, text: "", skillInvocations: [invocation]),
                BrainTurn(
                    role: .skillResult,
                    text: outcome.summary,
                    skillInvocationID: invocation.id,
                    skillName: skillName
                ),
            ], epoch: epoch)
            decisionOutcome = outcome
        }

        // A bare "stop/cancel" while routines run halts EVERYTHING (user
        // decision: one stop, no disambiguation grammar) — deterministic,
        // like the pending-action decision above (which wins when both
        // exist: a surfaced CONFIRM already ended its routine). A paused
        // typing remainder dies too: "stop" must never leave something a
        // later "continue" would surprise-type.
        if decisionOutcome == nil, !activeRoutines.isEmpty,
           bareDecision == false {
            let stopped = activeRoutines.values.map(\.label)
            for id in Array(activeRoutines.keys) {
                cancelRoutine(id: id)
            }
            PausedTypingSession.clear()
            let ack = stopped.count == 1
                ? "Okay — I stopped it."
                : "Okay — I stopped everything: \(SpokenPhrase.joinSpoken(stopped))."
            continuation.yield(.token(ack))
            appendHistory(BrainTurn(role: .assistant, text: ack), epoch: epoch)
            continuation.yield(.completed(fullText: ack))
            continuation.finish()
            return
        }

        // A new topic while actions run in the background reads as "they
        // landed — move on": all-ok routines settle silently from here on
        // (failures still speak; a bare yes/no is an ANSWER to a routine's
        // CONFIRM, not a move-on, and stop already cancelled everything).
        if decisionOutcome == nil {
            for id in activeRoutines.keys {
                activeRoutines[id]?.supersededByNewTurn = true
            }
        }

        // WHAT SHAPE OF TURN IS THIS? — asked HERE, once, and ABOVE the Seer
        // guard, which is the whole point of the placement.
        //
        // The two classifiers describe the SAME TURN from two angles: "is this
        // a command?" and "is this command about words that already exist?".
        // Every mechanism downstream reads them together — the pre-read guard
        // inverts on the pair, the Skill lane's prompt is seeded from the pair,
        // the caret-write veto is bounded by the pair — and computing either
        // one twice is precisely how the pre-read guard came to be backwards in
        // the first place: two copies of one judgement, edited on different
        // days, disagreeing about the same sentence.
        //
        // THEY USED TO SIT BELOW THE `guard seerReady`, AND THAT WAS THE BUG.
        // Seer being unavailable is an ordinary condition — a dropped network,
        // an expired token, the local-MLX configuration — not an edge case, and
        // on every one of those turns the legacy loop got NONE of G1–G4: no
        // intent, no locate, no passage in the prompt, no caret-write veto, no
        // report. "Replace the Purpose section with the tighter version" typed
        // at the caret again, exactly as shipped, the moment the voice went
        // offline. A gate that only holds while a NETWORK is up is not a gate.
        // APP-ADDRESSED COMMANDS. "Sketch can you add a white circle" is the
        // same command as "can you add a white circle" — but the app name is
        // not an address word, so every peel stopped on word 0 and the polite
        // frame was never seen: an app-addressed imperative routed as
        // conversation (live: the sketch turn that ad-libbed "Got it" with no
        // dispatch). The registered applications' single-word aliases are
        // handed to the classifiers as addresses; profiles are fetched here
        // (cheap) and reused below.
        let applicationProfiles = dispatcher?.applicationProfiles ?? []
        let applicationAddressAliases = Set(applicationProfiles.flatMap { profile in
            profile.aliases.compactMap { alias -> String? in
                let lowered = alias.lowercased()
                guard !lowered.contains(" ") else { return nil }
                return lowered
            }
        })
        let classifiedIntent = EditIntentClassifier.intent(
            in: userText, applicationAliases: applicationAddressAliases)
        // AN ACCEPTED OFFER BECOMES A REVISION, here, above everything that
        // reads the intent — so the whole revision spine (route .revise,
        // locate-first, targetBrief, RevisionVeto, EditReport, the action
        // rhythm that suppresses Lane A) is inherited, not rebuilt. The
        // synthesized intent carries the discussed text as its one target and
        // NO payload — same contract as "tighten the intro": the model writes
        // the replacement, and WHAT was offered reaches the lane through
        // history (the offer sentence and the "yes please" are both there).
        let acceptedOffer: AcceptedOffer? = classifiedIntent == nil && decisionOutcome == nil
            ? Self.bareAcceptance(
                bareDecision: bareDecision,
                hadPendingAction: hadPendingAction,
                routinesAtEntry: routinesAtEntry,
                referent: discussedPassageReferent,
                precedingUserTurnID: precedingUserTurnID,
                lastAssistantText: lastSpokenAssistantText(),
                persistentLead: ambient.leadPlace()?.world,
                now: Date())
            : nil
        let editIntent = classifiedIntent ?? acceptedOffer.map {
            EditIntent(shape: .replace, target: [$0.referent.text], isAnaphoric: true)
        }
        if acceptedOffer != nil {
            // One yes, one act. A second "yes please" has nothing carried and
            // stays conversational.
            discussedPassageReferent = nil
            Self.laneLog.info("bare acceptance armed the revision spine")
        }
        if bareDecision == false, decisionOutcome == nil {
            // "No thanks" declines the offer — the referent must not survive
            // to reinterpret a later, unrelated yes.
            discussedPassageReferent = nil
            offeredProseReferent = nil
        }

        // SHE OFFERED PROSE AND THEY SAID WRITE IT — the deterministic road.
        //
        // ABOVE the lane, and it returns rather than falling through, because
        // the requirement is EXACT BYTES: what lands on the page must be what
        // was read aloud. Handing the lane a brief would make that the model's
        // choice, and on the turn this was built for the model declined twice
        // — the ordinary roll and the retry nudge both came back empty, and
        // the user got "I couldn't work out how to do that" about a sentence
        // Mary had just composed herself.
        //
        // The shape is the pending-decision block above, verbatim: yield the
        // invocation, dispatch, yield the result, append the history pair. It
        // is `type_at_cursor` in compose mode, so this never resolves a
        // passage and never overwrites — the worst case is prose the user
        // asked for landing at their caret, which is visible and undoable.
        if classifiedIntent == nil, decisionOutcome == nil, acceptedOffer == nil,
           let dispatcher,
           let offer = Self.acceptedProse(
            utterance: userText,
            bareDecision: bareDecision,
            hadPendingAction: hadPendingAction,
            routinesAtEntry: routinesAtEntry,
            referent: offeredProseReferent,
            precedingUserTurnID: precedingUserTurnID,
            lastAssistantText: lastSpokenAssistantText(),
            applicationAliases: applicationAddressAliases,
            now: Date()) {
            // One yes, one act — before the dispatch, so a failure cannot
            // leave it armed for an unrelated later yes.
            offeredProseReferent = nil
            Self.laneLog.info("accepted prose offer dispatched to the typer")
            var arguments: [String: String] = ["text": offer.text, "mode": "compose"]
            // WHERE SHE OFFERED IT, not wherever is frontmost when they
            // agreed. `TypingSurface.resolve` has a taught-application rung
            // above the running-apps rung, so this reaches a manuscript
            // application even with Mary's own window in front.
            if let name = offer.place?.registration?.id { arguments["app"] = name }
            let argumentsJSON = (try? JSONSerialization.data(
                withJSONObject: arguments, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let skillName = "type_at_cursor"
            let invocation = ModelSkillInvocation(
                id: "prose-\(UUID().uuidString)", name: skillName,
                argumentsJSON: argumentsJSON)
            let invocationReference = dispatcher.skillReference(for: skillName)
            continuation.yield(.skillInvocation(
                reference: invocationReference, argumentsJSON: argumentsJSON,
                runID: invocation.id))
            let startedAt = Date()
            let outcome = await dispatcher.dispatch(
                name: skillName, argumentsJSON: argumentsJSON,
                runID: invocation.id)
            continuation.yield(.skillResult(record: BehavioralActionRecord(
                outcome: outcome,
                intention: skillName,
                argumentsJSON: argumentsJSON,
                reference: invocationReference,
                runID: invocation.id,
                startedAt: startedAt)))
            appendHistory(contentsOf: [
                BrainTurn(role: .assistant, text: "", skillInvocations: [invocation]),
                BrainTurn(
                    role: .skillResult,
                    text: outcome.summary,
                    skillInvocationID: invocation.id,
                    skillName: skillName
                ),
            ], epoch: epoch)
            let spoken = outcome.ok
                ? Self.wroteOfferedProseLine(place: offer.place?.displayName)
                : Self.couldNotWriteOfferedProseLine(detail: outcome.summary)
            continuation.yield(.token(spoken))
            appendHistory(
                BrainTurn(role: .assistant, text: spoken), epoch: epoch)
            continuation.yield(.completed(fullText: spoken))
            continuation.finish()
            return
        }

        // A REVISION IS AN ACTION, and saying so here is the other half of
        // "commit to it right away".
        //
        // These two used to be independent, and a revision only took the
        // action rhythm when `ActionClassifier` happened to catch it too —
        // true for "replace the Purpose section…" (`replace` leads) and false
        // for every anaphoric follow-up ("can you reword it"). On those turns
        // Lane A was not suppressed, so it filled the gap with "I'm on it";
        // the lane got the 250 ms join grace instead of 5 s, so a real edit
        // could not land inside the turn and detached; and the next utterance
        // superseded the routine, settling it silently. Five turns to reword
        // one paragraph, with the passage correctly in hand the whole time.
        //
        // `EditIntentClassifier` is the stricter, more conservative of the two
        // — it refuses anything that could be live composition — so anything
        // it calls a revision is a command by construction.
        let actionTurn = ActionClassifier.isActionCommand(
            userText, applicationAliases: applicationAddressAliases) || editIntent != nil

        // THE ROUTE — resolved here because this is where the turn's shape is
        // finally known, and RECORDED ONLY. Nothing below reads it.
        //
        // Stage 0 of the ambient-engine work is deliberately inert: the
        // taxonomy has to be checked against real traffic before a prompt or
        // a roster is allowed to depend on it, and this tree's whole
        // classifier stack is built on "a false positive is free" — an intent
        // that decided what the user may REACH would be the first mechanism
        // here whose false negative costs capability. So the engine observes,
        // the pane shows, and the numbers decide later.
        //
        // It re-runs nothing it is given: `actionTurn` and `editIntent` are
        // the values computed directly above, for the reason stated there —
        // two copies of one judgement, edited on different days, is how the
        // pre-read guard came to be backwards.
        // The source-owned packet stays independent from persistent workspace
        // focus. AmbientEngine may make its source the turn-effective schema
        // lead when the utterance points at it, without rewriting that focus.
        let attention = ambient.attention()
        let focusedApplicationID = dispatcher?.focusedApplicationID
        let now = Date()
        let namedApplicationIDs = Set(applicationProfiles.lazy
            .filter { $0.isMentioned(in: userText) }
            .map(\.id))
        let inheritedApplicationID: String?
        if namedApplicationIDs.isEmpty,
           AmbientRanker.referencesApplicationAnaphorically(userText),
           let recent = recentApplicationReferent,
           now.timeIntervalSince(recent.resolvedAt) <= Self.applicationReferentLifetime,
           applicationProfiles.contains(where: { $0.id == recent.id }) {
            inheritedApplicationID = recent.id
        } else {
            inheritedApplicationID = nil
        }
        let route = AmbientEngine.resolve(AmbientEngine.Inputs(
            utterance: userText,
            actionTurn: actionTurn,
            editIntent: editIntent,
            bareDecision: bareDecision,
            hasPendingSkillConfirmation: hadPendingAction,
            activeRoutineCount: routinesAtEntry,
            attention: attention,
            // A pronoun continues the named conversational subject even when
            // another recognized app remains frontmost behind Mary.
            // Live frontmost identity outranks memory; the tracker's lead
            // record fills exactly the hole a frontmost read cannot — the
            // user speaking while Mary's own window (or an unregistered
            // app) is front, moments after working in Sketch. Only a
            // DYNAMIC lead contributes here: a native lead place carries a
            // nil application lane, so the projection falls through exactly
            // as the old dynamic record nilled itself when a native signal
            // was newer.
            leadApplicationID: inheritedApplicationID
                ?? focusedApplicationID
                ?? Self.routableApplicationID(
                    focusTracker.leadPlace()?.application,
                    profiles: applicationProfiles,
                    // THE LEAD ASSERTS; A CANDIDATE ONLY OFFERS. This value
                    // becomes an ASSERTED application in
                    // `ApplicationProviderResolver`, and a skill whose only
                    // provider is disjoint from what was asserted ABSTAINS.
                    // So a guessed browser here does not merely mis-target —
                    // it deletes the other browser's verbs from the turn.
                    // That is what happened: the roster-order fallback
                    // asserted `safari`, every `browsing.*` skill Chrome
                    // provides came back mismatched, and the only browser
                    // verbs left standing were the Safari natives. With no
                    // evidence, asserting NOTHING is the honest answer — both
                    // toolsets stay reachable and the per-call
                    // `BrowserTarget` decides which engine is driven.
                    requireEvidence: true,
                    focusTracker: focusTracker),
            profiles: applicationProfiles,
            addressCandidates: Self.addressCandidates(
                profiles: applicationProfiles,
                elementIndex: wiring.elementIndex,
                focusTracker: focusTracker)))
        ambient.noteRoute(route)
        // Explicit language outranks a live but unrelated window. Otherwise a
        // recognized frontmost application becomes the next short follow-up's
        // referent. Merely inheriting a referent does not refresh its lifetime.
        if namedApplicationIDs.count == 1, let named = namedApplicationIDs.first {
            recentApplicationReferent = (named, now)
        } else if namedApplicationIDs.isEmpty,
                  route.gate.addressedApplications.count == 1,
                  let addressed = route.gate.addressedApplications.first,
                  applicationProfiles.contains(where: { $0.id == addressed }) {
            // ADDRESSED BY ITS CONTENTS — the middle rung, and the one that
            // closes "do you see this Google doc" → "add a draft here". A
            // literal name still outranks it; it still outranks a merely
            // frontmost window, because speaking the title of something an
            // application is showing is stronger evidence than which window
            // happens to be up. It arms a REFERENT, not a lead: a five-minute
            // conversational memory that reaches routing only if the NEXT
            // utterance independently passes the anaphora gate.
            recentApplicationReferent = (addressed, now)
        } else if inheritedApplicationID == nil,
                  let focusedApplicationID,
                  applicationProfiles.contains(where: { $0.id == focusedApplicationID }) {
            recentApplicationReferent = (focusedApplicationID, now)
        }
        // WHICH CONTAINER THIS TURN MEANS, resolved ONCE and published.
        //
        // Here rather than at the seams, because four of them derive it
        // independently — the targeted read, the passage locate, the body
        // reader, and the Skill bindings' own `window:` parameters — at four different
        // times in two lanes. Four derivations of one answer is exactly how
        // `document 1` and the front window came to disagree.
        //
        // AFTER the route and BEFORE locate (twenty lines below), so it needs no
        // classifier hoist. Nil is the common value and means "nobody named a
        // container", which leaves every reader at today's behaviour — see
        // `ReferenceFocus`'s Xcode guarantee.
        // A ONE-WORD CORRECTION OF THE LAST REFERENCE — the doctrine's third
        // clause, and it must run BEFORE `noteReference` below overwrites what
        // the previous turn resolved. That value is the only record of what is
        // being corrected.
        //
        // RE-AIM ONLY: salience is updated so the NEXT command lands correctly,
        // and nothing that already landed is touched.
        //
        // AND IT RETURNS EARLY, like the bare-stop path it mirrors.
        // `bareCorrection` matches the WHOLE utterance, so a correction cannot
        // be a prefix of a command — there is never a rest of the sentence to
        // drop. Acknowledging and stopping is also what makes it cheap: no lane
        // spawns, no skills, no model round.
        if Self.bareCorrection(in: userText),
           let previous = ambient.reference().referent,
           let resolveCorrection = referenceCorrector {
            let intended = resolveCorrection(previous)
            let ack = intended.map { "Got it — \($0.title)." } ?? "Got it — not that one."
            Self.laneLog.info("reference corrected away from \(previous.key, privacy: .public)")
            continuation.yield(.token(ack))
            appendHistory(BrainTurn(role: .assistant, text: ack), epoch: epoch)
            continuation.yield(.completed(fullText: ack))
            continuation.finish()
            return
        }

        // A WHOLE-APPLICATION WINDOW VERB NEEDS NO MODEL ROUND.
        //
        // THE COST IT REMOVES: Lane B's rounds all serialize on `engineGate`
        // against a local 12B model generating up to 800 tokens with ~130 tool
        // schemas in its prompt. "List the TextEdit windows" paid all of that
        // to be told a verb the classifier had already named, for an
        // application the route had already resolved — and when other routines
        // were queued it paid the wait for theirs as well, missed the 250 ms
        // join grace, and detached. That is how a one-second act became a
        // background routine carrying a seven-minute watchdog.
        //
        // TWO VERBS ONLY, and the boundary is not arbitrary: `list_app_windows`
        // and `bring_all_windows_forward` take an application and nothing else,
        // and that application comes from the route's own resolution rather
        // than from anything parsed here. `bring_window_forward` needs a window
        // TITLE, which nothing at this seam can resolve — guessing one is how a
        // raise lands on the wrong document — so it keeps its model round.
        //
        // MIRRORS THE BARE-CORRECTION PATH ABOVE, deliberately: same early
        // return, same "no lane spawns, no skills, no model round". A miss
        // falls through to the ordinary turn, so this can only make a turn
        // faster, never make one impossible.
        //
        // IT SKIPS THE PROMPT, NOT THE GATES. `dispatch` runs the same
        // `dispatchCore` every model-issued call runs — roster arbitration,
        // provider selection, capability and confirmation policy — and that
        // roster is computed live rather than read back from what `schemas`
        // projected. So a window Skill this turn is not eligible for is
        // refused here exactly as it would have been refused there; what is
        // skipped is the round that would have OFFERED it, not the check that
        // decides whether it may run.
        if let dispatcher,
           decisionOutcome == nil, editIntent == nil, !hadPendingAction,
           let verb = Self.deterministicWindowVerb(userText) {
            // THE ROUTE'S ANSWER, NOT THIS PATH'S GUESS. A named place is the
            // application the user said; the lead is the one the turn is in;
            // neither means the frontmost application, which is the declared
            // meaning of an omitted `app` on both bindings.
            let named = route.namedPlaces.first { $0.application != nil }
            let application = (named ?? route.leadPlace)?.application
            var arguments: [String: String] = [:]
            if let application { arguments["app"] = application }
            let argumentsJSON = (try? JSONSerialization.data(
                withJSONObject: arguments, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let invocation = ModelSkillInvocation(
                id: "window-\(UUID().uuidString)", name: verb,
                argumentsJSON: argumentsJSON)
            let invocationReference = dispatcher.skillReference(for: verb)
            continuation.yield(.skillInvocation(
                reference: invocationReference, argumentsJSON: argumentsJSON,
                runID: invocation.id))
            let startedAt = Date()
            let outcome = await dispatcher.dispatch(
                name: verb, argumentsJSON: argumentsJSON, runID: invocation.id)
            continuation.yield(.skillResult(record: BehavioralActionRecord(
                outcome: outcome,
                intention: verb,
                argumentsJSON: argumentsJSON,
                reference: invocationReference,
                runID: invocation.id,
                startedAt: startedAt)))
            appendHistory(contentsOf: [
                BrainTurn(role: .assistant, text: "", skillInvocations: [invocation]),
                BrainTurn(
                    role: .skillResult,
                    text: outcome.summary,
                    skillInvocationID: invocation.id,
                    skillName: verb
                ),
            ], epoch: epoch)
            Self.laneLog.info("window verb dispatched deterministically — no model round")
            // A READ'S SUMMARY IS THE ANSWER; A RAISE'S IS NOT.
            //
            // Listing windows produces the list that was asked for, so it is
            // spoken. A successful raise is an ACTION, and the action-first
            // rhythm settles those silently — the chip is the reply, exactly as
            // it would have been through the lane. A FAILURE always speaks,
            // whichever verb it was: that rule has no exceptions elsewhere in
            // this file and gains none here.
            let spoken = (outcome.ok && verb != "list_app_windows")
                ? "" : outcome.summary
            if !spoken.isEmpty {
                continuation.yield(.token(spoken))
                appendHistory(
                    BrainTurn(role: .assistant, text: spoken), epoch: epoch)
            }
            continuation.yield(.completed(fullText: spoken))
            continuation.finish()
            return
        }

        // THE ACT REACHES THE RESOLVER. `editIntent.shape` has been in hand
        // since ~50 lines above and used to be dropped here — so the same words
        // got the same answer whether the next thing to happen was a read or a
        // delete. `ReferenceAct.from` is the one place that mapping lives.
        ambient.noteReference(
            referentResolver?(ReferenceAct.from(editIntent?.shape)) ?? .none)

        // THE WORLD VETO CANNOT ARM IN THIS CUT, and saying so out loud is
        // the point of these lines.
        //
        // It is the dispatch-time backstop behind the roster's place scoping:
        // on a writing-led turn, a call aimed at a rival watched place is not
        // dispatched, and the synthetic refusal names the leading place's own
        // targeted read instead. It needs that read to exist.
        // `targetedReadInvocation(forWorld:)` indexes a table built solely
        // from COMPILED `MaryAdapter.targetedRead` declarations, and no `.mary`
        // package can supply one — so in Mary the arming is nil on every turn.
        //
        // KEPT NIL AND EXPLICIT rather than deleted, because the veto itself
        // is real machinery with real tests and the gap is one seam wide:
        // arming it needs a `targetedReadInvocation(forPlace:)` keyed on the
        // registration id, so a package that declares a prose surface declares
        // its own targeted read by doing so. That belongs with roster
        // arbitration, where the rest of the place-vs-place reasoning lives.
        // A guard widened to `leadPlace` today would only look like coverage.
        let worldVetoArming: WorldVeto.Arming? = nil

        var supportingContext: String?
        if let phrase = route.supportingContext, let dispatcher {
            supportingContext = await withNanosecondBudget(Self.preReadBudgetNanoseconds) {
                await dispatcher.readNamedPart(phrase)
            }
            if Task.isCancelled {
                appendCancelledEpilogue(
                    spokenText: "", actionTurn: actionTurn, outcomes: [], epoch: epoch)
                continuation.finish()
                return
            }
        }

        var systemPrompt = systemPromptProvider()
        if let phrase = route.supportingContext, let supportingContext {
            systemPrompt += "\n\n" + MaryPrompts.supportingContextBrief(
                phrase: phrase, text: supportingContext)
        }
        if route.selectionDefinesTurn,
           route.writingTarget == .selection,
           let attention = route.attention {
            systemPrompt += "\n\n" + MaryPrompts.selectionRevisionBrief(attention)
        } else if route.selectionDefinesTurn,
                  route.verdicts.isDeictic,
                  route.attention?.isDirectReference == true,
                  let attention = route.attention {
            systemPrompt += "\n\n" + MaryPrompts.selectionReferenceBrief(attention)
        }
        // ARM THE DISCUSSED-PASSAGE REFERENT. A selection this route grounded
        // a turn on is the thing a bare "yes please" can later mean — one
        // site, one rule, both brief shapes. The handoff text is the exact
        // capture (never prompt-clipped); the fact and brief are turn-scoped
        // and stay so; only this conversational-salience copy survives, and
        // only for the acceptance gate to spend.
        if route.selectionDefinesTurn, let attention = route.attention,
           let discussed = ambient.selectionHandoff(world: attention.world)?.text
                ?? attention.selectedText,
           !discussed.isEmpty {
            discussedPassageReferent = DiscussedPassageReferent(
                text: discussed,
                world: attention.world,
                applicationID: attention.applicationID,
                subject: attention.subject,
                armedAt: Date(),
                armedByExchange: userTurn.id)
        }

        let traceID = UUID()
        let turnRegistry = dispatcher?.abilitySnapshot
            ?? AbilityLibrary.shared.snapshot()
        // The responder-layer signal stamped at exchange time, so the lens
        // shows what was co-active WHEN the turn ran, never live state
        // projected onto an old row.
        let focusSignal = focusTracker.signal()
        AmbientTraceLog.shared.record(AmbientTraceRecord(
            id: traceID,
            exchangeID: userTurn.id,
            utterance: userText,
            route: route,
            systemPromptChars: systemPrompt.count,
            registryRevision: turnRegistry.revision,
            packageIDs: turnRegistry.records.map(\.id),
            exposedSkillCount: dispatcher?.schemaCount ?? 0,
            abilityRoster: dispatcher?.abilityRosterTrace ?? .empty,
            coActivePlaces: focusSignal.coActive,
            glancedPlaces: focusSignal.glanced))
        // The retrieval row opens BESIDE the route row, joined by the same
        // exchange id, before either lane exists — a turn that never finishes
        // must still leave its trace. Pure observation; nothing reads it on a
        // decision path. The claim collects what the zero-arg system-prompt
        // provider staged during the `systemPromptProvider()` build a few
        // statements above, on this same actor — single producer, single
        // consumer.
        wiring.retrieval.open(exchangeID: userTurn.id, routeTraceID: traceID)
        wiring.retrieval.claimStagedSystemPrompt(forExchange: userTurn.id)
        // THE INPUT HALF OF THE EPISODE, claimed from the same prompt build
        // and for the same reason. See `BehavioralAssembler` on why the
        // capture is staged rather than passed.
        wiring.behavior.claimStagedCapture(forEpisode: userTurn.id)

        // `actionTurn` OR the utterance NAMED the application: asking a named
        // app to do something deserves the unavailable notice even when
        // classification read the sentence as conversation — the live failure
        // had the app name blocking the polite-frame peel, and the notice was
        // silenced with it.
        // THE LEAD IS NOT THE ONLY WAY TO NAME AN APP. "move this screenshot
        // in sketch" can arrive with the lead resolved elsewhere (or nowhere)
        // while "sketch" sits asserted in the gate — and the old lead-only
        // preflight fell through to the mute two-roll NOOP ("Nothing ran")
        // instead of an honest permission or availability sentence. Every
        // asserted dynamic application gets preflighted, lead first.
        if actionTurn || namedApplicationIDs.contains(route.leadApplicationID ?? "")
            || !route.gate.applications.isEmpty {
            var preflightCandidates: [String] = []
            for candidate in [route.leadApplicationID].compactMap({ $0 })
                + route.gate.applications.sorted()
            where !preflightCandidates.contains(candidate) {
                preflightCandidates.append(candidate)
            }
            for applicationID in preflightCandidates {
                guard let profile = turnRegistry.plugins.applicationProfiles
                    .first(where: { $0.id == applicationID }),
                      route.gate.applications.contains(applicationID)
                        || inheritedApplicationID == applicationID
                        || route.leadApplicationID == applicationID
                        || !route.gate.requestedAbilities.isDisjoint(with: profile.abilities),
                      let line = Self.providerUnavailableLine(
                          applicationID: applicationID,
                          snapshot: turnRegistry)
                else { continue }
                continuation.yield(.token(line))
                appendHistory(
                    BrainTurn(role: .assistant, text: sanitizedSpoken(line)),
                    epoch: epoch)
                continuation.yield(.completed(fullText: line))
                continuation.finish()
                return
            }
        }

        let located = route.needsLocate
            ? await locateTarget(
                for: editIntent, worldHint: acceptedOffer?.referent.world)
            : nil
        if Task.isCancelled {
            appendCancelledEpilogue(
                spokenText: "", actionTurn: actionTurn, outcomes: [], epoch: epoch)
            continuation.finish()
            return
        }

        // THE CANVAS TWIN OF THE LOCATE ABOVE. A revise-shaped design cue
        // resolves to the layer the ledger says "it" means, arming the design
        // veto; a create-like cue resolves the same layer as REFERENCE
        // MATERIAL only, and nothing is ever blocked for it. Both are nil on
        // almost every turn, at the cost of a dictionary lookup.
        //
        // THE AMBIENT PROBE hands the classifier the reference gate: an
        // THE CANVAS-REFERENT LANE IS NOT IN THIS CUT. A block here used to
        // classify "make it bigger" against a live index of shapes on a page,
        // resolve which one "it" meant, and arm a created-surface referent.
        // It needed an artifact domain — a declared vocabulary of nouns, ids
        // and geometry — which no package in this cut declares.

        var seerReady = false
        if let seerChat { seerReady = await seerChat.isReady() }

        guard seerReady, let seerChat else {
            await legacyTurn(
                userText: userText,
                systemPrompt: systemPrompt,
                actionTurn: actionTurn,
                editIntent: editIntent, target: located,
                writingTarget: route.writingTarget,
                acceptedOffer: acceptedOffer != nil,
                worldVetoArming: worldVetoArming,
                traceID: traceID,
                continuation: continuation, epoch: epoch)
            return
        }

        // Seer mode with a deterministic decision already executed: the
        // outcome summary is the grounded reply — zero latency, no model in
        // the loop to re-ask or embellish.
        if let decisionOutcome {
            let spoken = decisionOutcome.summary
            continuation.yield(.token(spoken))
            appendHistory(BrainTurn(role: .assistant, text: spoken), epoch: epoch)
            continuation.yield(.completed(fullText: spoken))
            continuation.finish()
            return
        }

        await seerTurn(
            userText: userText,
            originUserTurnID: userTurn.id,
            systemPrompt: systemPrompt,
            actionTurn: actionTurn,
            editIntent: editIntent,
            target: located,
            writingTarget: route.writingTarget,
            acceptedOffer: acceptedOffer != nil,
            worldVetoArming: worldVetoArming,
            traceID: traceID,
            routeIntent: route.intent,
            leadPlace: route.leadPlace,
            seerChat: seerChat,
            continuation: continuation,
            epoch: epoch
        )
    }

    /// The tracker's lead application translated into the CLOSED profile-id
    /// vocabulary the route speaks. The cursor-obvious lead made the
    /// tracker's application lane open-form ("browser", a generic app's
    /// bundle id); the route's `leadApplicationID` must stay closed over
    /// profile ids: the browser workspace maps to the profile claiming a
    /// browser bundle ("safari"), a registered dynamic id passes through, a
    /// bundle id maps to the profile claiming it, and anything unclaimed
    /// maps to nil — never junk.
    /// APPLICATIONS WHOSE LIVE CONTENTS COULD BE ADDRESSED THIS TURN.
    ///
    /// Candidacy follows PUBLICATION, not focus — deliberately the opposite
    /// of the `probeApplications` list used for cue classification, which
    /// asks what already leads. An application the user is talking about but
    /// that has NOT been routed to is exactly the case the address probe
    /// exists for; asking "what already won" would answer the wrong
    /// question.
    ///
    /// Both filters are generic, and neither knows a browser exists:
    /// `scope.place.application` is non-nil only for `.application` places (an
    /// application published these), so fact lanes and passage scopes drop
    /// out by themselves; `routableApplicationID` is the tree's single
    /// spelling of open-form id → closed profile id. Any application that
    /// publishes elements becomes addressable here with no vocabulary at
    /// all — which is the entire point.
    static func addressCandidates(
        profiles: [ApplicationProfile],
        elementIndex: AmbientElementIndexStore,
        focusTracker: WorkspaceFocusTracker
    ) -> [AmbientAddressProbe.Candidate] {
        elementIndex
            .activeScopes(freshWithin: AmbientAddressProbe.candidateHorizon)
            .compactMap { scope in
                guard let application = scope.place.application,
                      let id = routableApplicationID(
                        application, profiles: profiles, focusTracker: focusTracker)
                else { return nil }
                return AmbientAddressProbe.Candidate(scope: scope, applicationID: id)
            }
    }

    /// `requireEvidence` separates the two questions this used to answer with
    /// one number. An ADDRESS CANDIDATE asks "could this profile serve the
    /// browser workspace?" — any browser profile can, so the roster fallback
    /// is right and dropping it would make browser tabs unaddressable. The
    /// TURN LEAD asks "which browser am I entitled to say the user meant?",
    /// and there the roster fallback is a guess that silently removes the
    /// other engine's skills from the roster. Same lookup, opposite default.
    static func routableApplicationID(
        _ application: String?,
        profiles: [ApplicationProfile],
        requireEvidence: Bool = false,
        focusTracker: WorkspaceFocusTracker
    ) -> String? {
        guard let application else { return nil }
        if profiles.contains(where: { $0.id == application }) { return application }
        if application == AmbientPlaceResolver.browserApplicationID {
            // The logical browser workspace can be served by more than one
            // profile once chrome.mary installs beside safari. Prefer the
            // profile claiming the LEDGER-EVIDENCED bundle — the browser the
            // user demonstrably worked in — so an address-probe hit routes to
            // the plugin actually driving that browser.
            //
            // TWO HORIZONS USED TO DISAGREE INSIDE ONE TURN, and that is the
            // whole "prose said Chrome, bindings said Safari" bug: this rung
            // asked for FRESH evidence (`coActiveHorizon`, five minutes) while
            // `resolveTargetBrowser` asks within `signalHorizon` (twenty). Sit
            // in Chrome for six minutes without re-activating it and the two
            // ladders answer differently about the same browser. They ask the
            // same question, so they now use the same bound.
            let evidenced = focusTracker
                .evidenceProcess(for: AmbientPlaceResolver.browserPlace)
                ?? focusTracker.evidenceProcess(
                    for: AmbientPlaceResolver.browserPlace,
                    within: WorkspaceFocusTracker.signalHorizon)
            if let evidenced,
               let owner = profiles.first(where: { profile in
                   profile.applicationIdentifiers.contains { id in
                       evidenced.hasPrefix(id) || id == evidenced
                   }
               })?.id {
                return owner
            }
            // No evidence either way. A candidate may still fall back to the
            // first browser profile; a LEAD may not — see `requireEvidence`.
            guard !requireEvidence else { return nil }
            return profiles.first { profile in
                profile.applicationIdentifiers.contains { id in
                    AmbientPlaceResolver.isBrowser(bundleID: id)
                }
            }?.id
        }
        if application.contains(".") {
            let lowered = application.lowercased()
            return profiles.first { profile in
                profile.applicationIdentifiers.contains { $0.lowercased() == lowered }
            }?.id
        }
        return nil
    }
}
