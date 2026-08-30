//
//  MaryBrain+TurnLoop.swift
//  MaryBrain
//
//  WHAT: runTurn / runTurnBody — supersede, route, pre-reads, gates, handoff.
//  IN:   LanguageResponder.startTurn
//  OUT:  seerTurn or localTurn
//  PIN:  Both functions moved whole; never split a function.
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
        // A request owns the exact source selection that existed before the request UI became frontmost.
        // Workspace deactivation is delivered asynchronously.
        await SelectionHandoffCoordinator.shared.capturePendingSourceAsync()
        // Voice/hands-free input can begin while the source app remains frontmost, so there is no deactivate → composer transition at all.
        await SelectionHandoffCoordinator.shared.captureFrontmostExternalSourceAsync()
        // Ability Studio can activate a new registry while this request is generating.
        let abilitySnapshot = dispatcher?.abilitySnapshot
            ?? AbilityLibrary.shared.snapshotEnsuringLoaded()
        // A source-owned selection is one machine Interaction, but natural conversation can refer to it across adjacent sentences.
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

    // ROUTE: After all of the ambient contexts are retrieved
    private func runTurnBody(
        userText: String,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation,
        epoch: UInt64,
        superseding: Bool
    ) async {
        defer { turnBox.retire(epoch) }
        if superseding {
            // The superseded turn's exchange — its user turn, any Skill pairs, any partial reply that landed before the epoch bump
            removeLastExchange()
        } else if turnBox.isCurrent(epoch), let open = openExchange {
            // Overlap-supersede: a plain respond() landed while another turn was mid-flight.
            openExchange = nil
            if exchangeIsOpen(anchoredAt: open.userTurnID) {
                removeExchange(anchoredAt: open.userTurnID)
                continuation.yield(.exchangeSuperseded(userTurnID: open.userTurnID))
            }
        }
        // Held dictation owns the utterance. Bare yes/no/stop stay deterministic.
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

        dispatcher?.beginTurn()

        // The utterance may name a domain ("add a scene…", "fix the build…").
        focusTracker.setTurnOverride(FocusOverride.classifyOverride(utterance: userText))
        defer { focusTracker.clearTurnOverride() }
        // Published before either prompt is built.
        ambient.noteUtterance(userText)

        // After the utterance is published so Ability Totem search can use
        // this turn's words. Observers still refresh here so live facts and
        // the search share one budget.
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

        let userTurn = BrainTurn(role: .user, text: userText)
        // The turn's identity leads every path — deterministic decision,
        // bare-stop, local, seer — so the app can stamp the exchange before
        // any token or chip arrives.
        continuation.yield(.turnBegan(id: userTurn.id))
        // A turn arriving on the heels of a remark is that remark being
        // answered — the one thing that earns her the next one.
        appendHistory(userTurn, epoch: epoch)
        // Adjacency bookkeeping for the acceptance gate: what was the
        // PREVIOUS turn, before this one becomes it.
        let precedingUserTurnID = lastUserTurnID
        lastUserTurnID = userTurn.id
        // Episode id is the turn id.
        wiring.behavior.openEpisode(
            id: userTurn.id,
            query: userText,
            priorEpisodeID: precedingUserTurnID,
            provenance: behavioralProvenance())
        if turnBox.isCurrent(epoch) { openExchange = (userTurn.id, epoch) }
        // Guarded clear: only a turn that exits while still CURRENT — completed, or barge-in cancelled with no replacement — closes its own exchange.
        defer {
            if let open = openExchange, open.epoch == epoch, turnBox.isCurrent(epoch) {
                openExchange = nil
            }
            // SEALED ON THE WAY OUT, whichever way out this turn took.
            wiring.behavior.seal(
                userTurn.id,
                reason: turnBox.isCurrent(epoch) ? .completed : .superseded)
        }
        trimHistory()

        // A pending action + a bare yes/no is not the model's decision to make
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

        // A bare "stop/cancel" while routines run halts EVERYTHING (user decision: one stop, no disambiguation grammar)
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

        // A new topic while actions run in the background reads as "they landed — move on": all-ok routines settle silently from here on (failures still speak
        if decisionOutcome == nil {
            for id in activeRoutines.keys {
                activeRoutines[id]?.supersededByNewTurn = true
            }
        }

        // Turn shape — once, above the Seer guard.
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
        // Accepted offer → revision, above everything that reads intent.
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

        // Offered prose accepted → write path. Return; do not fall through.
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
            // WHERE SHE OFFERED IT, not wherever is frontmost when they agreed.
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

        // A REVISION IS AN ACTION, and saying so here is the other half of "commit to it right away".
        // PIN: `EditIntentClassifier` is the stricter, more conservative of the two
        let actionTurn = ActionClassifier.isActionCommand(
            userText, applicationAliases: applicationAddressAliases) || editIntent != nil

        // Route resolved here (shape now known). Recorded only; nothing below reads it.
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
            // A pronoun continues the named conversational subject even when another recognized app remains frontmost behind Mary.
            leadApplicationID: inheritedApplicationID
                ?? focusedApplicationID
                ?? Self.routableApplicationID(
                    focusTracker.leadPlace()?.application,
                    profiles: applicationProfiles,
                    // Lead asserts; a candidate only offers.
                    requireEvidence: true,
                    focusTracker: focusTracker),
            profiles: applicationProfiles,
            addressCandidates: Self.addressCandidates(
                profiles: applicationProfiles,
                elementIndex: wiring.elementIndex,
                focusTracker: focusTracker),
            focus: focusTracker.signal(),
            evidence: focusTracker.freshEvidence()))
        ambient.noteRoute(route)
        wiring.behavior.noteAbilityTargets(
            route.gate.memory.abilityTargets, forEpisode: userTurn.id)
        // Explicit language outranks a live but unrelated window. Otherwise a
        // recognized frontmost application becomes the next short follow-up's
        // referent. Merely inheriting a referent does not refresh its lifetime.
        if namedApplicationIDs.count == 1, let named = namedApplicationIDs.first {
            recentApplicationReferent = (named, now)
        } else if namedApplicationIDs.isEmpty,
                  route.gate.addressedApplications.count == 1,
                  let addressed = route.gate.addressedApplications.first,
                  applicationProfiles.contains(where: { $0.id == addressed }) {
            // ADDRESSED BY ITS CONTENTS — the middle rung, and the one that closes "do you see this Google doc" → "add a draft here".
            recentApplicationReferent = (addressed, now)
        } else if inheritedApplicationID == nil,
                  let focusedApplicationID,
                  applicationProfiles.contains(where: { $0.id == focusedApplicationID }) {
            recentApplicationReferent = (focusedApplicationID, now)
        }
        // Container for this turn — once, then published. Re-aim only (next command).
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

        // Whole-app window verbs: list_app_windows / bring_all_windows_forward.
        // Same early-return shape as bare-correction (no lane, no skills).
        if let dispatcher,
           decisionOutcome == nil, editIntent == nil, !hadPendingAction,
           let verb = Self.deterministicWindowVerb(userText) {
            // THE ROUTE'S ANSWER, NOT THIS PATH'S GUESS.
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

        // editIntent.shape → referentResolver.
        ambient.noteReference(
            referentResolver?(ReferenceAct.from(editIntent?.shape)) ?? .none)

        // World veto unarmed in this cut.
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
        // Arm discussed-passage referent so a later "yes please" can spend it.
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
        // The retrieval row opens BESIDE the route row, joined by the same exchange id, before either lane exists
        wiring.retrieval.open(exchangeID: userTurn.id, routeTraceID: traceID)
        wiring.retrieval.claimStagedSystemPrompt(forExchange: userTurn.id)
        wiring.retrieval.claimStagedAbilityRequest(forExchange: userTurn.id)
        // Episode input half — same prompt build. BehavioralAssembler stages the capture.
        wiring.behavior.claimStagedCapture(forEpisode: userTurn.id)

        // `actionTurn` OR the utterance NAMED the application: asking a named app to do something deserves the unavailable notice even when classification read the…
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

        // Design-cue locate (canvas twin of the passage locate). Arms the design veto.

        var seerReady = false
        if let seerChat { seerReady = await seerChat.isReady() }

        guard seerReady, let seerChat else {
            await localTurn(
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

    /// Candidacy follows PUBLICATION, not focus — deliberately the opposite of the `probeApplications` list used for cue classification
    /// Both filters are generic, and neither knows a browser exists: `scope.place.application` is non-nil only for…
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

    /// `requireEvidence` separates the two questions this used to answer with one number.
    static func routableApplicationID(
        _ application: String?,
        profiles: [ApplicationProfile],
        requireEvidence: Bool = false,
        focusTracker: WorkspaceFocusTracker
    ) -> String? {
        guard let application else { return nil }
        if profiles.contains(where: { $0.id == application }) { return application }
        if application == AmbientPlaceResolver.browserApplicationID {
            // The logical browser workspace can be served by more than one profile once chrome.mary installs beside safari.
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
