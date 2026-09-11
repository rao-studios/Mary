//
//  MaryBrain+Turn.swift
//  MaryBrain
//
//  WHAT: THE TURN, WHOLE — entry, route, both lanes, and the engine seat.
//  IN:   LanguageResponder.startTurn
//  OUT:  BrainEvent stream; LaneOutcome / OrchestratorLaneResult
//
//  This file was six (TurnLoop, SewnTurn, Lanes, OrchestratorLane, LocalTurn,
//  SkillTurn), split for size alone. Following one turn meant following one
//  call chain across six files, so they are one file again, in call order:
//
//    runTurn / runTurnBody       supersede, route, embedding dispatch, gates
//    sewnTurn                    Sewn mode — dual lane, join/detach, takeover
//    runSewnLane / runRealtime…  Lane A, the spoken reply
//    runOrchestratorLane         Lane B, the silent Skill loop
//    engineTurn                  no Lane A — the engine seat answers alone
//    performSkillTurn            the dispatch ceremony both lanes share
//
//  PIN:  NEVER SPLIT A FUNCTION. Every member below moved whole; that was the
//        rule when this was six files and it is why the merge was mechanical.
//
import MaryPlugin
import MaryVoice
import Foundation
import os

extension MaryBrain {

    // MARK: - Entry — the turn loop

    // internal for file split — treat as private
    func runTurn(
        userText: String,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation,
        epoch: UInt64,
        superseding: Bool
    ) async {
        turnClockStart = DispatchTime.now()
        turnMarks = []
        defer { logTurnClock() }
        // A request owns the exact source selection that existed before the request UI became frontmost.
        // Workspace deactivation is delivered asynchronously.
        await SelectionHandoffCoordinator.shared.capturePendingSourceAsync()
        // Voice/hands-free input can begin while the source app remains frontmost, so there is no deactivate → composer transition at all.
        await SelectionHandoffCoordinator.shared.captureFrontmostExternalSourceAsync()
        // Ability Studio can activate a new registry while this request is generating.
        let abilitySnapshot = dispatcher?.abilitySnapshot
            ?? AbilityLibrary.shared.snapshotEnsuringLoaded()
        // A source-owned selection is one machine Interaction, but natural conversation can refer to it across adjacent sentences.
        // ASKED HERE, CARRIED DOWN. The body seeds this same verdict into the
        // engine rather than letting the classifier answer twice for one turn.
        let isDeictic = AmbientRanker.isDeictic(userText)
        let mayReferenceSelection = isDeictic
            || EditIntentClassifier.intent(in: userText) != nil
        let snapshot = AmbientSelectionTurnSnapshot(
            handoff: world.store.snapshotSelectionForTurn(
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
                            superseding: superseding,
                            isDeictic: isDeictic)
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
        superseding: Bool,
        /// Already answered in `runTurn` to decide whether this turn may claim a
        /// recent selection; seeded into the engine so one turn has one verdict.
        isDeictic: Bool
    ) async {
        logTurnEntry(userText: userText)
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
        // THE ONE DETERMINISTIC CONSULT. Everything else this turn asks about
        // the words, it asks the corpus — semantically.
        let bareDecision = DeterministicTier.decision(in: userText)
        // Held dictation owns the utterance. Bare yes/no/stop stay deterministic.
        // A pending action + a bare yes/no is not the model's decision to make.
        let pendingConfirmationArmed = dispatcher?.hasPendingSkillConfirmation ?? false
        // A held session owns UNADDRESSED speech — that is the whole mode.
        // Opening one is the writing package's `start_dictation` Skill, routed
        // like any other; nothing here knows the words that ask for it.
        if !pendingConfirmationArmed || bareDecision == nil,
           DictationSession.shared.isHeld(),
           await runHeldDictationTurn(
            userText: userText, continuation: continuation, epoch: epoch) {
            logTurnExit("held dictation")
            continuation.finish()
            return
        }

        dispatcher?.beginTurn()

        // The utterance may name a domain ("add a scene…", "fix the build…").
        // CLASSIFIED ONCE, then seeded into the engine below: the override the
        // tracker is actually running under has to be the one the route records.
        // ASKED OF THE INSTALLED DISCIPLINES, semantically. Read here rather
        // than off the triage verdict because the tracker override has to be
        // standing before the lead place is resolved, which is well above the
        // routing query — see `setTurnOverride` immediately below.
        let focusOverride = AmbientRanker.namedDiscipline(in: userText)
        focusTracker.setTurnOverride(focusOverride)
        defer { focusTracker.clearTurnOverride() }
        // Published before either prompt is built.
        world.store.noteUtterance(userText)

        // After the utterance is published so Ability Thread search can use
        // this turn's words. Observers still refresh here so live facts and
        // the search share one budget.
        //
        // ROUTING MEMORY IS RECALLED HERE TOO, and this is the only place it
        // can be: the readers below (`SemanticSkillRequestIndex.affinities`,
        // `SemanticIntentIndex.classify`) are synchronous all the way up, so
        // the round trip has to happen at an await that already exists, under
        // a budget, before anything scores. A recall that misses its budget
        // leaves the turn routing on its authored corpus alone.
        // AND THIS TURN'S VECTOR IS WARMED HERE, for the same reason: every
        // scorer below is synchronous, so a vector that needs an await must
        // already exist when they run. Under Apple's model this also collapses
        // the four separate vectorizations of the same sentence a turn used to
        // pay for; under Sewn's it is the only way the tier works at all.
        RoutingHabitStore.shared.clearRecall()
        // NOTHING TO DO IS NOT WORK. With no vectorizer and no memory backend
        // there is nothing to warm and nothing to recall, and wrapping that in
        // a budget still costs a scheduling hop on every turn — enough to
        // reorder a routine racing a history trim.
        let warmsThisTurn = MaryEmbeddings.engine() != nil
        let recallsThisTurn = RoutingHabitMemoryProvider.isInstalled
        if let prepare = turnContextPreparer {
            _ = await withNanosecondBudget(Self.turnContextRefreshBudgetNanoseconds) {
                async let warmed: Void = MaryEmbeddings.warm(userText)
                async let recalled: Void = recallsThisTurn
                    ? RoutingHabitStore.shared.recall(near: userText) : ()
                await prepare()
                await warmed
                await recalled
                return Optional(())
            }
            if Task.isCancelled {
                logTurnExit("cancelled during observer refresh")
                continuation.finish()
                return
            }
        } else if warmsThisTurn || recallsThisTurn {
            _ = await withNanosecondBudget(Self.turnContextRefreshBudgetNanoseconds) {
                async let warmed: Void = MaryEmbeddings.warm(userText)
                if recallsThisTurn {
                    await RoutingHabitStore.shared.recall(near: userText)
                }
                await warmed
                return Optional(())
            }
        }

        let userTurn = BrainTurn(role: .user, text: userText)
        // The turn's identity leads every path — deterministic decision,
        // bare-stop, local, sewn — so the app can stamp the exchange before
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

        let hadPendingAction = dispatcher?.hasPendingSkillConfirmation ?? false
        let routinesAtEntry = activeRoutines.count

        var decisionOutcome: SkillOutcome?
        if let dispatcher, dispatcher.hasPendingSkillConfirmation,
           let approved = bareDecision {
            let skillName = approved
                ? AbilityRuntime.confirmSkillName
                : AbilityRuntime.cancelSkillName
            decisionOutcome = await performSkillTurn(
                dispatcher: dispatcher,
                name: skillName,
                argumentsJSON: "{}",
                runIDPrefix: "decision",
                continuation: continuation,
                epoch: epoch)
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
            logTurnExit("bare stop while routines ran")
            continuation.finish()
            return
        }

        // A new topic while actions run in the background reads as "they landed — move on": all-ok routines settle silently from here on (failures still speak
        if decisionOutcome == nil {
            for id in activeRoutines.keys {
                activeRoutines[id]?.supersededByNewTurn = true
            }
        }

        // Turn shape — once, above the Sewn guard.
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
                persistentLead: world.store.leadPlace()?.attention,
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
            let outcome = await performSkillTurn(
                dispatcher: dispatcher,
                name: "type_at_cursor",
                argumentsJSON: Self.argumentsJSON(arguments),
                runIDPrefix: "prose",
                continuation: continuation,
                epoch: epoch)
            let spoken = outcome.ok
                ? Self.wroteOfferedProseLine(place: offer.place?.displayName)
                : Self.couldNotWriteOfferedProseLine(detail: outcome.summary)
            closeSkillTurn(
                spoken: spoken, exit: "accepted prose offer",
                continuation: continuation, epoch: epoch)
            return
        }

        // A REVISION IS AN ACTION, and saying so here is the other half of "commit to it right away".
        // PIN: `EditIntentClassifier` is the stricter, more conservative of the two
        let snapshot = world.snapshot()
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
        let leadApplicationID = inheritedApplicationID
            ?? focusedApplicationID
            ?? Self.routableApplicationID(
                focusTracker.leadPlace()?.application,
                profiles: applicationProfiles,
                requireEvidence: true,
                focusTracker: focusTracker)
        let recentUserTurns = Array(
            history.dropLast()
                .filter { $0.role == .user }
                .map(\.text)
                .suffix(RoutingQuery.historyCap))
        // The routing query that composes a routine.
        let routingQuery = RoutingQuery.compose(
            utterance: userText,
            world: snapshot,
            recentUserTurns: recentUserTurns)
        world.store.noteRoutingQuery(routingQuery)
        let worldBit = snapshot == nil ? "world=no" : "world=yes"
        let historyBit = recentUserTurns.isEmpty ? "history=no" : "history=yes"
        Self.turnLog.info(
            "embed query — chars=\(userText.count, privacy: .public) \(worldBit, privacy: .public) \(historyBit, privacy: .public)")
        // Hoisted above the classify: the intent index rides the frozen
        // registry (package-authored `intentSeeds`), not a process-wide
        // static — a fake dispatcher's `.empty` snapshot degrades cleanly to
        // the lexical ladder, in tests and in a headless probe alike.
        // ONE BINDING for the whole body: inside a turn this only reads the
        // installed `AbilityTurnContext` task-local anyway.
        let turnRegistry = dispatcher?.abilitySnapshot
            ?? AbilityRuntime.Snapshot.empty
        // THE ONE SEMANTIC READ of this turn. Intent, requested abilities,
        // skill affinities and the unique pick all come from the same pass, so
        // the route, the roster and the log cannot disagree about what was said.
        // THE PRE-ROUTE ROSTER. Triage needs the offered names to score, and
        // the route needs triage — so this necessarily runs before
        // `noteRoute` below, and sees no route. It is NOT the roster the log
        // and the trace record want; those read `routedProjection` after the
        // route lands. Two projections, because there are genuinely two
        // rosters in a turn body, not because either is asked twice.
        let offeredNames = dispatcher?.projectRoster().names ?? []
        mark("roster")
        let triage = TurnTriage.verdict(
            query: routingQuery,
            registry: turnRegistry,
            offeredNames: offeredNames)
        mark("triage")
        let embeddingIntent = triage.intent
        // Revision is STRUCTURE, so it ORs in rather than being embedded.
        var actionTurn = editIntent != nil || triage.isActionShaped

        // SAMPLED ONCE, for the route and the row that records it: the ledger keeps
        // moving, so a second read could show places the engine never routed on.
        let focusSignal = focusTracker.signal()
        // Route resolved here (shape now known). Recorded only; nothing below reads it.
        let route = AmbientEngine.resolve(AmbientEngine.Inputs(
            utterance: userText,
            routingQuery: routingQuery,
            actionTurn: actionTurn,
            embeddingIntent: embeddingIntent,
            editIntent: editIntent,
            bareDecision: bareDecision,
            hasPendingSkillConfirmation: hadPendingAction,
            activeRoutineCount: routinesAtEntry,
            world: snapshot,
            // A pronoun continues the named conversational subject even when another recognized app remains frontmost behind Mary.
            leadApplicationID: leadApplicationID,
            profiles: applicationProfiles,
            addressCandidates: Self.addressCandidates(
                profiles: applicationProfiles,
                elementIndex: wiring.elementIndex,
                focusTracker: focusTracker),
            focus: focusSignal,
            evidence: focusTracker.freshEvidence(),
            seeds: AmbientEngine.AmbientVerdictSeeds(
                isDeictic: isDeictic, focusOverride: focusOverride)))
        world.store.noteRoute(route)
        // THE ROUTED ROSTER, as the circuit log has always seen it: after the
        // route, before the referent.
        let routedProjection = dispatcher?.projectRoster()
        mark("roster")
        // And as a watcher sees it — from in here, where the turn's signals and
        // task-locals are still standing. A confidence-lane dispatch returns before the
        // second projection below, so for that path this is the only one there is.
        //
        // THE SEMANTIC READ RIDES ALONG. `triage` already holds the intent, its
        // score, its runner-up and the unique pick, computed once above; without
        // this it reached os_log and nothing else, and a bench could see WHICH
        // skills were offered but never what the words were judged to mean.
        if let trace = routedProjection?.trace {
            rosterProjectionObserver?(trace.carrying(triage.verdictValue()))
        }
        actionTurn = route.isActionTurn
        let offeredAffinities = triage.skillAffinities
        let uniqueSkill = triage.uniqueSkill
        let abilityList = route.gate.requestedAbilities
            .map(\.rawValue).sorted().joined(separator: ",")
        let topSkills = offeredAffinities
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map { "\($0.key.rawValue)=\(String(format: "%.2f", $0.value))" }
            .joined(separator: ",")
        let pick: String
        if uniqueSkill != nil {
            pick = "unique-win"
        } else if offeredAffinities.count > 1 {
            pick = "tie"
        } else {
            pick = "below-floor"
        }
        let intentBit = triage.intentDescription
        let abilitiesBit = abilityList.isEmpty ? "none" : abilityList
        let skillsBit = topSkills.isEmpty ? "none" : topSkills
        Self.turnLog.info(
            "embed search — \(intentBit, privacy: .public) abilities=\(abilitiesBit, privacy: .public) skills=\(skillsBit, privacy: .public) pick=\(pick, privacy: .public)")
        logCodingCircuit(
            route: route,
            focusedApplicationID: focusedApplicationID,
            actionTurn: actionTurn,
            editIntent: editIntent,
            rosterTrace: routedProjection?.trace ?? .empty)
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
        if ReferenceCorrectionGrammar.isCorrection(userText),
           let previous = world.store.reference().referent,
           let resolveCorrection = referenceCorrector {
            let intended = resolveCorrection(previous)
            let ack = intended.map { "Got it — \($0.title)." } ?? "Got it — not that one."
            Self.laneLog.info("reference corrected away from \(previous.key, privacy: .public)")
            continuation.yield(.token(ack))
            appendHistory(BrainTurn(role: .assistant, text: ack), epoch: epoch)
            continuation.yield(.completed(fullText: ack))
            logTurnExit("reference correction")
            continuation.finish()
            return
        }

        // THE ONE NO-MODEL DISPATCH. Window verbs arrive here too now: they
        // are ordinary Skills that happen to need no argument, and the gate
        // that used to name them by hand is gone.
        if let dispatcher,
           decisionOutcome == nil, editIntent == nil, !hadPendingAction,
           route.intent == .operate,
           let skill = uniqueSkill,
           let shape = EmbeddingRouting.confidenceShape(of: skill, utterance: userText),
           // A verb carrying no span claims the WHOLE sentence, so it only
           // acts on a whole simple one. A skill extracting a span already
           // reads around the joiners it finds.
           shape != .noRequiredArguments || EmbeddingRouting.isSingleClause(userText) {
            let name = skill.reference.invocationName
            // The turn's own naming: exactly one application mentioned is an
            // instruction, two is an ambiguity nobody should resolve for them.
            let namedApplicationID = route.gate.applications.count == 1
                ? route.gate.applications.first : nil
            // A SKILL POINTED AT AN APPLICATION RESOLVES ONE OF ITS OWN.
            // `namedApplicationID` is the whole roster's answer and is nil the
            // moment two apps are mentioned anywhere in the sentence; the
            // reverse lookup asks the narrower question — which of the
            // applications THIS ability can be pointed at did they mean — and
            // answers it by distance when nothing was named outright.
            let applicationReference = ApplicationReferenceResolution.resolve(
                for: skill,
                snapshot: turnRegistry,
                utterance: userText,
                assertedApplicationIDs: Set(route.gate.applications))
            let applicationID = applicationReference?.chosen?.applicationID
                ?? namedApplicationID
            let filled = EmbeddingRouting.filledArguments(
                for: skill, utterance: userText, applicationID: applicationID,
                applicationProfiles: applicationProfiles,
                templates: turnRegistry.templates)
            let argumentsJSON = filled.json
            // WHAT THE SHORTCUT DID, said where somebody can read it. A dispatch
            // with no model round is the hardest lane to trust on sight: the only
            // evidence it was right is the peeling that produced its arguments.
            if let trace = routedProjection?.trace {
                rosterProjectionObserver?(trace.carrying(triage.verdictValue(
                    lane: .confidence(
                        invocationName: name,
                        argumentsJSON: argumentsJSON,
                        stages: filled.stages))))
            }
            let outcome = await performSkillTurn(
                dispatcher: dispatcher,
                name: name,
                argumentsJSON: argumentsJSON,
                runIDPrefix: "embed",
                allowTitleCommit: true,
                // THE ONE PATH WHOSE LESSON IS FREE: the embedding picked this
                // Skill uniquely from these very words, so the row reinforces
                // a win the corpus already produced. Reads included, for the
                // same reason.
                routingHabitGrant: RoutingHabitRecordingContext.grant(
                    lane: .confidence, query: userText, route: route.intent),
                continuation: continuation,
                epoch: epoch)
            Self.turnLog.info(
                "embed dispatch — invoke \(name, privacy: .public)")
            // A committed guess must speak — silence here would start
            // playing the wrong thing with no way to catch it.
            // AND AN ACT SPEAKS ITS RECEIPT. "Click the first link on this page"
            // pressed the link, the page changed, and the turn ended without a
            // word — measured through the bench, and reported by the person as a
            // command that "did not work"; "find the word budget" opened the
            // find bar and said nothing. What the machine did is the one thing
            // worth a sentence: what it opened, what it paused, what it is
            // looking for. A skill with nothing to say returns no summary, and
            // that stays silent.
            let spoken = outcome.summary
            closeSkillTurn(
                spoken: spoken, exit: "embedding dispatch \(name)",
                continuation: continuation, epoch: epoch)
            return
        }
        if route.intent == .operate {
            Self.turnLog.info(
                "embed dispatch — laneB roster=\(skillsBit, privacy: .public)")
        }

        // editIntent.shape → referentResolver.
        world.store.noteReference(
            referentResolver?(ReferenceAct.from(editIntent?.shape)) ?? .none)
        // THE REFERENT MOVES THE ROSTER. It reaches arbitration through the
        // window-management intent's target classes, so the trace record —
        // which is written below, after this — must project again rather than
        // reuse the routed one. Only the record's own two questions collapse
        // here; they were adjacent arguments to the same initializer, each
        // arbitrating all 105 Skills to the identical verdict.
        let tracedProjection = dispatcher?.projectRoster()
        mark("roster")
        if let trace = tracedProjection?.trace {
            rosterProjectionObserver?(trace.carrying(triage.verdictValue(lane: .model)))
        }

        // World veto unarmed in this cut.
        let worldVetoArming: WorldVeto.Arming? = nil

        var supportingContext: String?
        if let phrase = route.supportingContext, let dispatcher {
            supportingContext = await withNanosecondBudget(Self.preReadBudgetNanoseconds) {
                await dispatcher.readNamedPart(phrase)
            }
            if Task.isCancelled {
                logTurnExit("cancelled during supporting-context pre-read")
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
        // ASKED ONCE, OF THE ROUTE. `routedSelectionWorld` already answers which
        // selection this turn accepted; re-spelling its guard here is how they drift.
        if route.writingTarget == .selection, let attention = route.routedSelectionWorld {
            systemPrompt += "\n\n" + MaryPrompts.selectionRevisionBrief(attention)
        } else if route.verdicts.isDeictic, let attention = route.routedSelectionWorld {
            systemPrompt += "\n\n" + MaryPrompts.selectionReferenceBrief(attention)
        }
        // Arm discussed-passage referent so a later "yes please" can spend it.
        // The snapshot was built FROM this turn's frozen handoff and carries its
        // text uncut, so there is no second copy to fetch back out of the store.
        if let attention = route.routedSelectionWorld,
           let discussed = attention.selectedText,
           !discussed.isEmpty {
            discussedPassageReferent = DiscussedPassageReferent(
                text: discussed,
                place: attention.place,
                armedAt: Date(),
                armedByExchange: userTurn.id)
        }

        let traceID = UUID()
        AmbientTraceLog.shared.record(AmbientTraceRecord(
            id: traceID,
            exchangeID: userTurn.id,
            utterance: userText,
            route: route,
            systemPromptChars: systemPrompt.count,
            registryRevision: turnRegistry.revision,
            packageIDs: turnRegistry.records.map(\.id),
            exposedSkillCount: tracedProjection?.schemas.count ?? 0,
            abilityRoster: tracedProjection?.trace ?? .empty,
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
                logTurnExit("provider unavailable for \(applicationID)")
                continuation.finish()
                return
            }
        }

        let located = route.needsLocate
            ? await locateTarget(
                for: editIntent, attentionHint: acceptedOffer?.referent.place.attention)
            : nil
        if Task.isCancelled {
            logTurnExit("cancelled during locate")
            appendCancelledEpilogue(
                spokenText: "", actionTurn: actionTurn, outcomes: [], epoch: epoch)
            continuation.finish()
            return
        }

        // Design-cue locate (canvas twin of the passage locate). Arms the design veto.

        var sewnReady = false
        if let sewnChat { sewnReady = await sewnChat.isReady() }

        guard sewnReady, let sewnChat else {
            await engineTurn(
                userText: userText,
                systemPrompt: systemPrompt,
                route: route,
                target: located,
                acceptedOffer: acceptedOffer != nil,
                worldVetoArming: worldVetoArming,
                traceID: traceID,
                continuation: continuation, epoch: epoch)
            return
        }

        // Sewn mode with a deterministic decision already executed: the
        // outcome summary is the grounded reply — zero latency, no model in
        // the loop to re-ask or embellish.
        if let decisionOutcome {
            let spoken = decisionOutcome.summary
            continuation.yield(.token(spoken))
            appendHistory(BrainTurn(role: .assistant, text: spoken), epoch: epoch)
            continuation.yield(.completed(fullText: spoken))
            logTurnExit("pending skill decision")
            continuation.finish()
            return
        }

        await sewnTurn(
            userText: userText,
            originUserTurnID: userTurn.id,
            systemPrompt: systemPrompt,
            route: route,
            target: located,
            acceptedOffer: acceptedOffer != nil,
            worldVetoArming: worldVetoArming,
            traceID: traceID,
            sewnChat: sewnChat,
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
        if let place = AmbientPlaceResolver.logicalPlace(forApplication: application) {
            // A logical workspace can be served by more than one profile; the
            // focus ledger's evidence says which. The resolver owns which ids
            // are logical and who serves them — nothing here names a browser.
            let evidenced = focusTracker.evidenceProcess(for: place)
                ?? focusTracker.evidenceProcess(
                    for: place, within: WorkspaceFocusTracker.signalHorizon)
            if let evidenced,
               let owner = profiles.first(where: { profile in
                   profile.applicationIdentifiers.contains { id in
                       evidenced.hasPrefix(id) || id == evidenced
                   }
               })?.id {
                return owner
            }
            // No evidence either way. A candidate may still fall back to the
            // first serving profile; a LEAD may not — see `requireEvidence`.
            guard !requireEvidence else { return nil }
            return profiles.first { profile in
                profile.applicationIdentifiers.contains { id in
                    AmbientPlaceResolver.serves(place, bundleID: id)
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

    // MARK: - Sewn mode (dual lane)

    // internal for file split — treat as private
    struct SewnLaneResult {
        var text = ""
        var contribution: SewnContribution?
        var autoMemory = false
        var failed = false
    }

    /// One dispatched Skill's settled outcome inside a lane. CARRIES the outcome
    /// rather than re-spelling it — restating these fields per construction site
    /// is how `foundNothing` once got dropped on the last hop.
    struct LaneOutcome: Sendable {
        /// The lane's dispatch name — the binding's operation, else the model's
        /// invocation name. The lane's own addition; not a `SkillOutcome` field.
        var skillName: String
        var outcome: SkillOutcome
        /// What was called — the model's invocation name and its arguments as
        /// sent — so a repeat can be recognised. See MaryBrain+RepeatGuard.
        var invocation: String = ""
        var argumentsJSON: String = ""

        var summary: String { outcome.summary }
        var ok: Bool { outcome.ok }
        var deferred: Bool { outcome.deferred }
        /// The binding LOOKED and what was asked for is not in what it can read.
        var foundNothing: Bool { outcome.foundNothing }
        /// A CONFIRM park.
        var requested: Bool { outcome.status == .requested }
        var editDisposition: EditDisposition? { outcome.editDisposition }
        /// The read's content already lives in ambient context ("Still in hand"),
        /// so reciting its machine summary aloud is redundant. The silent-settle
        /// gate reads this.
        var ambientDeposited: Bool { outcome.ambientDeposited }
        /// A POLICY refusal (the mismatch mirror, a schema-policy denial),
        /// distinct from an adapter failure.
        var blocked: Bool { outcome.status == .blocked }
        /// The acting intent is satisfied.
        var landed: Bool { outcome.landed }
        /// A question only the person can answer — the reply, not a failure.
        var asksThePerson: Bool { outcome.asksThePerson }
    }

    struct OrchestratorLaneResult {
        var text = ""
        /// The question of a CONFIRM the lane surfaced (already stripped of
        /// its prefix), spoken deterministically after the Sewn reply.
        var confirmQuestion: String?
        /// A question a Skill asked the person; the lane ended on it and it is
        /// the reply. Its own field: every `confirmQuestion` reader also
        /// requires a stored pending confirmation, which nothing here parks.
        var question: String?
        /// The model re-issued a call that had already failed with the same
        /// words; the lane ended rather than run it again.
        var repeatedFailedCall = false
        /// Settled outcome per dispatch — fuel for the grounded follow-up.
        var outcomes: [LaneOutcome] = []
        /// The lane's Skill turns, buffered privately (never written to shared
        /// history mid-lane) and batch-merged at join so tool_use/tool_result
        /// pairs can never be orphaned by an epoch flip.
        var laneTurns: [BrainTurn] = []
        /// The control the screen was offering when this lane ran nothing — set by the affordance escape, and the evidence the turn-level last rung needs.
        var affordanceOffer: AffordanceCandidate?
    }

    // internal for file split — treat as private
    func sewnTurn(
        userText: String,
        originUserTurnID: UUID,
        systemPrompt: String,
        /// THE TURN'S ROUTE, WHOLE. It already answers every question this used to
        /// take as a separate scalar; passing the pieces only let them disagree.
        route: AmbientRoute,
        target located: LocatedPassage? = nil,
        /// True when this turn is a synthesized accepted-offer revision —
        /// EditReport's silent-miss arm keys on it.
        acceptedOffer: Bool = false,
        /// The world-boundary backstop, armed by the turn loop from the same
        /// admission formula the roster scope uses.
        worldVetoArming: WorldVeto.Arming? = nil,
        /// Stage-0 observation only: which `AmbientTraceLog` row this turn's Skill calls belong to.
        traceID: UUID? = nil,
        sewnChat: any SewnChatProviding,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation,
        epoch: UInt64
    ) async {
        let actionTurn = route.isActionTurn
        let editIntent = route.verdicts.editIntent
        let writingTarget = route.writingTarget
        let routeIntent = route.intent
        // WHERE this turn is happening, for the prose offer this reply may carry: an offer made about a manuscript must be written back into that manuscript
        let leadPlace = route.leadPlace
        // Fetch first, then speak.
        let turnStartedAt = Date()
        var readPassages: [String] = []
        // Bound around every fetch-first call below — the dispatch
        // chokepoint appends to it when a read's `ActionInitiator` is
        // `.maryRead`. Drained once, just before the lane spawns.
        let ownActs = OwnActCollector()
        if editIntent == nil, !actionTurn, let dispatcher,
           let phrase = route.verdicts.namedPart {
            // A SUSPENSION POINT before any lane exists.
            let passage = await OwnActCollector.$current.withValue(ownActs) {
                await withNanosecondBudget(Self.preReadBudgetNanoseconds) {
                    await dispatcher.readNamedPart(phrase)
                }
            }
            if Task.isCancelled {
                appendCancelledEpilogue(
                    spokenText: "", actionTurn: actionTurn, outcomes: [], epoch: epoch)
                continuation.finish()
                return
            }
            if let passage {
                readPassages = [passage]
                readLedger.record(ReadDelivery(
                    route: .prefetched, detail: "\"\(phrase)\"",
                    characters: passage.count))
            }
        }

        // Fetch-first: highlight read / buffer / document inspect / look, then speak.
        var lookUnderway = false
        var lookServed = false
        var readServed = false
        // THE ROUTE'S OWN ANSWER, asked once for the turn — it decides the
        // pre-look here and the inspired-sight line below.
        //
        // This used to OR in a second opinion from `LookClassifier`, which
        // asked its own question of the same words with its own eighteen
        // question-openers and thirteen sight-words. The route already
        // classifies perception from every package's authored `perceive`
        // habits; a parallel word list could only disagree with it.
        if readPassages.isEmpty, editIntent == nil, !actionTurn, let dispatcher,
           routeIntent == .perceive {
            let eyes = self.sight
            let sight = await OwnActCollector.$current.withValue(ownActs) {
                await withNanosecondBudget(Self.preLookBudgetNanoseconds) {
                    () async -> (passage: String, isRead: Bool)? in
                    await eyes?.fetchDeclaredEditorSight(query: userText) ?? nil
                }
            }
            if Task.isCancelled {
                appendCancelledEpilogue(
                    spokenText: "", actionTurn: actionTurn, outcomes: [], epoch: epoch)
                continuation.finish()
                return
            }
            if let sight {
                readPassages = [sight.passage]
                lookServed = true
                readServed = sight.isRead
                readLedger.record(ReadDelivery(
                    route: .prefetched, detail: "declared-editor-sight",
                    characters: sight.passage.count))
                if let glanced = focusTracker.latestGlancePlace(),
                   let application = glanced.application,
                   let routable = Self.routableApplicationID(
                       application,
                       profiles: dispatcher.applicationProfiles,
                       focusTracker: focusTracker) {
                    recentApplicationReferent = (routable, Date())
                }
            } else if self.sight?.wouldServeLook() == true {
                lookUnderway = true
            }
        }
        // AWARENESS: the unit they are inside, and what reaches it. Runs on
        // ordinary turns too — the sentence this whole path exists for ("what
        // do you think about this code") is one the router scores as
        // conversation about as often as it scores it perception, and the
        // dispatcher's own gate decides whether this turn deserves the read.
        var awareness: [String] = []
        var awarenessServed = false
        if editIntent == nil, !actionTurn, let dispatcher {
            let sight = await OwnActCollector.$current.withValue(ownActs) {
                await withNanosecondBudget(Self.preAwarenessBudgetNanoseconds) {
                    await dispatcher.fetchAwareness(query: userText)
                }
            }
            if Task.isCancelled {
                appendCancelledEpilogue(
                    spokenText: "", actionTurn: actionTurn, outcomes: [], epoch: epoch)
                continuation.finish()
                return
            }
            if let sight {
                awarenessServed = true
                if let surroundings = sight.surroundings, !surroundings.isEmpty {
                    awareness = [surroundings]
                }
                // The unit is a READ, and takes a read's road — unless a read
                // already answered this turn, in which case that one is the
                // one they asked for and this would only crowd it.
                if let unit = sight.unit, !unit.isEmpty, readPassages.isEmpty {
                    readPassages = [unit]
                    readServed = true
                    readLedger.record(ReadDelivery(
                        route: .prefetched, detail: "awareness-unit",
                        characters: unit.count))
                }
            }
            let line = "awareness — served=\(awarenessServed)"
                + " unit=\(readServed ? readPassages.first?.count ?? 0 : 0)"
                + " surroundings=\(awareness.first?.count ?? 0)"
            Self.turnLog.info("\(line, privacy: .public)")
        }

        let lookWould = sight?.wouldServeLook() ?? false
        let lookLine = "look — wouldServe=\(lookWould) served=\(lookServed) read=\(readServed) underway=\(lookUnderway)"
        Self.turnLog.info("\(lookLine, privacy: .public)")

        // Fetch-first is over — one drain, whatever landed in the box above.
        // No LaneEmitter existed yet to carry these, so they ride the turn's
        // own continuation directly, same as every other in-turn write here.
        let ownReads = ownActs.drain()
        if !ownReads.isEmpty {
            continuation.yield(.ownReads(ownReads))
        }

        // Snapshot Sewn's messages BEFORE the orchestrator starts mutating history with Skill turns.
        // Stale-grounding windows (accepted): - W1 — routine settles mid-Lane-A: this snapshot predates a doneMarker/follow-up…
        let messages = spokenMessages()
        // The route is in hand; there is nothing to fetch back out of the store.
        let inspiredSight = route.inspiresSight
            && routeIntent == .perceive
        let instructions = sewnInstructionsProvider(SewnPass(
            readPassages: readPassages,
            // THE ROUTER'S OWN VERDICT, carried rather than re-derived —
            // except where this turn's own evidence contradicts it. Having
            // just read their work and traced what reaches it, this is not a
            // pass with nothing in hand, whatever the router called it.
            conversational: routeIntent == .converse && !awarenessServed,
            runningActionLabels: activeRoutines.values.map(\.label),
            lookUnderway: lookUnderway,
            inspiredSight: inspiredSight,
            perceiving: routeIntent == .perceive || awarenessServed,
            awareness: awareness,
            exchangeID: originUserTurnID))
        let laneSeed = history

        // Lane B is an UNSTRUCTURED task: it can outlive the turn as a detached routine.
        let emitter = LaneEmitter(continuation: continuation)
        let laneTask: Task<OrchestratorLaneResult, Never>?
        // Completion signal for the grace race — awaiting Task.value directly
        // in a task group pins the group to the lane's duration (value is not
        // cancellation-responsive); a finished AsyncStream is.
        let laneSignal: AsyncStream<Void>?
        mark("pre")
        let laneSpawn = DispatchTime.now()
        // Attached until the grace race detaches. Flipped once; the lane reads it each round.
        let laneAttachment = LaneAttachment()
        do {
            let seed = laneSeed
            let prompt = systemPrompt
            let target = located
            let (signal, signalContinuation) = AsyncStream<Void>.makeStream()
            laneSignal = signal
            laneTask = Task { [weak self] in
                let result = await self?.runOrchestratorLane(
                    userText: userText, systemPrompt: prompt,
                    seed: seed, emitter: emitter, target: target,
                    worldVetoArming: worldVetoArming,
                    traceID: traceID,
                    actionTurn: actionTurn, editIntent: editIntent,
                    routeIntent: routeIntent,
                    writingTarget: writingTarget,
                    lookUnderway: lookUnderway,
                    servedByPreLook: lookServed,
                    servedByRead: readServed,
                    attachment: laneAttachment) ?? OrchestratorLaneResult()
                signalContinuation.finish()
                return result
            }
        }
        // Lane A: realtime WebSocket route when enabled and ready; classic
        // SSE otherwise. A realtime failure before any event fell through
        // invisibly — rerun classic (rule 2).
        var sewnLane: SewnLaneResult
        var serverVoiced = false
        if actionTurn {
            // Action-first rhythm: no Lane A at all — no Sewn stream, no "I'm on it", no TTS. The command dispatches at full speed and the Skill chips are the reply.
            Self.turnLog.info("laneA — skipped; actionTurn so chips would be the reply")
            sewnLane = SewnLaneResult()
        } else if let realtime = sewnRealtime, await realtime.isReady() {
            Self.turnLog.info("laneA — speaking")
            let outcome = await runRealtimeSewnLane(
                realtime: realtime, messages: messages,
                instructions: instructions,
                exchangeID: originUserTurnID, continuation: continuation)
            if outcome.fellBackPreStream, !Task.isCancelled {
                sewnLane = await runSewnLane(
                    sewnChat: sewnChat, messages: messages,
                    instructions: instructions,
                    exchangeID: originUserTurnID, continuation: continuation)
            } else {
                sewnLane = outcome.result
                serverVoiced = outcome.serverVoiced
            }
        } else {
            Self.turnLog.info("laneA — speaking")
            sewnLane = await runSewnLane(
                sewnChat: sewnChat, messages: messages,
                instructions: instructions,
                exchangeID: originUserTurnID, continuation: continuation)
        }

        var spokenText = sewnLane.text

        if Task.isCancelled {
            // Barge-in: keep what happened so the conversation stays coherent — the lane's Skill pairs and the partial reply.
            laneTask?.cancel()
            if let laneTask,
               // BOUNDED, even here. `Task.value` ignores cancellation
               let lane = await bounded(attachedLaneBudget, { await laneTask.value }) {
                appendHistory(contentsOf: lane.laneTurns, epoch: epoch)
            }
            if !spokenText.isEmpty {
                appendHistory(
                    BrainTurn(role: .assistant, text: sanitizedSpoken(spokenText)),
                    epoch: epoch)
                noteOfferedProse(spoken: spokenText, place: leadPlace)
            }
            continuation.finish()
            return
        }

        // Join or detach. Sewn-offline-with-no-text must await fully — the orchestrator's prose is the only voice left.
        var orchestratorLane: OrchestratorLaneResult?
        var laneStalled = false
        if let laneTask, let laneSignal {
            // NOTHING WAS SAID, SO THERE IS NOTHING TO DETACH FROM.
            //
            // PIN: DETACHING EXISTS TO LET A LANE WORK WHILE THE VOICE CARRIES
            // THE TURN. When the voice carried NOTHING, detaching after 250ms
            // leaves the person with silence and a spinner, and the answer then
            // depends on the follow-up chain surviving — which it does not
            // always do. Measured: "what is this page about?" spoke in Lane A
            // with nothing in hand, Lane B took 1–3s to read the page, the turn
            // detached, and a follow-up that timed out or read as restating was
            // dropped, ending on "Listening" having said nothing at all.
            // AN ACTION TURN IS THE DELIBERATE EXCEPTION: Lane A is skipped
            // there on purpose and the Skill chips are the reply.
            if spokenText.isEmpty, sewnLane.failed || !actionTurn {
                orchestratorLane = await bounded(attachedLaneBudget) { await laneTask.value }
                laneStalled = orchestratorLane == nil
            } else if await laneFinished(
                signal: laneSignal,
                grace: actionTurn ? actionJoinGraceNanoseconds : laneJoinGraceLiveNanoseconds) {
                // The signal already SAID the lane finished, so this await returns immediately in every healthy case
                orchestratorLane = await bounded(attachedLaneBudget) { await laneTask.value }
                laneStalled = orchestratorLane == nil
            }
        }
        mark("lane")
        if laneStalled {
            laneTask?.cancel()
            Self.laneLog.error("attached lane exceeded its cap — speaking the honest stall line")
            readLedger.record(ReadDelivery(
                route: .expiredUnanswered,
                detail: Self.routineLabel(from: userText), characters: 0))
        }

        let laneElapsedMs = (DispatchTime.now().uptimeNanoseconds - laneSpawn.uptimeNanoseconds) / 1_000_000
        if let lane = orchestratorLane {
            Self.laneLog.info("lane joined in \(laneElapsedMs)ms")
            let names = lane.outcomes.map(\.skillName)
            if names.isEmpty {
                Self.turnLog.info("laneB — joined with no skill outcomes")
            } else {
                let line = "laneB — ran \(names.joined(separator: ", "))"
                Self.turnLog.info("\(line, privacy: .public)")
            }
            appendHistory(contentsOf: lane.laneTurns, epoch: epoch)
        } else if let laneTask, !laneStalled {
            // …and a STALLED lane never gets here: it already blew the cap a
            // routine would have given it and was cancelled, so registering it
            // as a routine would only buy it a second seven minutes to fail in.
            Self.laneLog.info("lane detached after grace (\(laneElapsedMs)ms since spawn; exclusiveEngine=\(self.engine.requiresExclusiveGeneration))")
            // NOBODY IS WAITING ON IT FROM HERE. Flipped before the routine is registered, so the lane's very next round already knows it is background work
            laneAttachment.detach()
            makeRoomForDetachedRoutine()
            // DETACH: the turn completes now; the lane becomes a routine and reports through the proactive channel when it finishes.
            let routineID = UUID()
            var routine = ActiveRoutine(
                id: routineID, task: laneTask, userText: userText,
                label: Self.routineLabel(from: userText),
                originUserTurnID: originUserTurnID,
                isActionTurn: actionTurn,
                // Read HERE, on the actor, inside the turn — the utterance
                // override is still installed and `effectiveFocus()` is still
                // the world the user asked in.
                originFocus: focusTracker.effectiveFocus(),
                // Born from a superseded turn (cancelled mid-grace, the lane detaches AFTER the new turn's supersede sweep ran): the user already moved on
                supersededByNewTurn: !turnBox.isCurrent(epoch),
                // The pre-read's passage went out with this turn's voice; a
                // lane that only re-reads it has nothing left to say.
                servedByPreRead: !readPassages.isEmpty,
                // Read HERE, on the actor, for the same reason `originFocus`
                // is: these are facts about the turn that spawned the routine,
                // and the routine settles long after that turn is over.
                editIntent: editIntent,
                writingTarget: writingTarget,
                locatedTarget: located,
                // FROM THE SPAWN, NOT FROM HERE. Detach is ~250 ms later on a spoken turn and up to five seconds later on an action turn
                spawnedAt: laneSpawn,
                watchdogTask: nil,
                progressTask: nil)
            // The watchdog: a lane that never returns must still settle the
            // routine so the UI's "still working" state can't stick.
            let cap = routineWatchdogNanoseconds
            routine.watchdogTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: cap)
                guard !Task.isCancelled else { return }
                // The watchdog is born inside the originating turn's task, so an unstructured Task would inherit its raw selection handoff.
                await SchemaSignalTurnContext.$snapshot.withValue(.empty) {
                    await AmbientSelectionTurnContext.$snapshot.withValue(.empty) {
                        await self?.expireRoutine(id: routineID)
                    }
                }
            }
            // Second clock — the one the user can hear.
            let marks = routineProgressMarks
            let spawn = routine.spawnedAt
            routine.progressTask = Task { [weak self] in
                for mark in marks {
                    let elapsed = DispatchTime.now().uptimeNanoseconds
                        &- spawn.uptimeNanoseconds
                    if mark > elapsed {
                        try? await Task.sleep(nanoseconds: mark - elapsed)
                    }
                    guard !Task.isCancelled else { return }
                    // Progress is proactive work too. It currently does not render ambient facts
                    await SchemaSignalTurnContext.$snapshot.withValue(.empty) {
                        await AmbientSelectionTurnContext.$snapshot.withValue(.empty) {
                            await self?.speakRoutineProgress(id: routineID)
                        }
                    }
                }
            }
            activeRoutines[routineID] = routine
            // Detach identity rides the TURN stream (before .completed), so
            // the app learns "this bubble is a routine's home" strictly
            // before the turn finalizes — the empty-bubble-drop race closes.
            continuation.yield(.routineDetached(originUserTurnID: originUserTurnID))
            emitter.flipToDetached(proactive, originUserTurnID: originUserTurnID)
            proactive.yield(.routineStarted(
                routineID: routineID,
                label: routine.label,
                originUserTurnID: originUserTurnID))
            // Registered in `settleTasks` (self-removing) so quiescence can
            // enumerate the settle hop — the one piece of routine work that
            // used to be untracked.
            settleTasks[routineID] = Task { [weak self] in
                let result = await laneTask.value
                // Lane B keeps the initiating turn's snapshot while it is executing the requested action.
                await SchemaSignalTurnContext.$snapshot.withValue(.empty) {
                    await AmbientSelectionTurnContext.$snapshot.withValue(.empty) {
                        await self?.finishRoutine(result, id: routineID)
                    }
                }
                await self?.removeSettleTask(id: routineID)
            }
        }

        // A turn cancelled during the join grace was superseded or barged in AFTER its voice finished (an in-stream cancel exits through the barge-in branch above): any…
        if Task.isCancelled {
            appendCancelledEpilogue(
                spokenText: spokenText, actionTurn: actionTurn,
                outcomes: orchestratorLane?.outcomes ?? [], epoch: epoch)
            continuation.finish()
            return
        }

        // A classified COMMAND the orchestrator judged "pure conversation" is a contradiction — re-roll ONCE with the retry note, then speak an honest failure.
        if actionTurn, let lane = orchestratorLane,
           lane.outcomes.isEmpty, lane.confirmQuestion == nil, !Task.isCancelled {
            let seed = laneSeed
            let retryPrompt = systemPrompt + "\n\n" + MaryPrompts.actionRetryNudge
            let retryTarget = located
            guard let retry = await bounded(
                attachedLaneBudget,
                { [weak self] () async -> OrchestratorLaneResult in
                return await self?.runOrchestratorLane(
                    userText: userText,
                    systemPrompt: retryPrompt,
                    // Retry carries the passage too.
                    seed: seed, emitter: emitter, target: retryTarget,
                    worldVetoArming: worldVetoArming,
                    routeIntent: routeIntent, writingTarget: writingTarget)
                    ?? OrchestratorLaneResult()
            }) else {
                // Degrade to the same honest sentence a watchdog expiry
                // speaks: the retry never came back, so nothing may claim it
                // did.
                Self.laneLog.error("action retry exceeded its cap — speaking the honest stall line")
                readLedger.record(ReadDelivery(
                    route: .expiredUnanswered,
                    detail: Self.routineLabel(from: userText), characters: 0))
                let line = Self.stalledLine(label: Self.routineLabel(from: userText))
                continuation.yield(.token(line))
                appendHistory(
                    BrainTurn(role: .assistant, text: sanitizedSpoken(line)), epoch: epoch)
                continuation.yield(.completed(fullText: line))
                continuation.finish()
                return
            }
            appendHistory(contentsOf: retry.laneTurns, epoch: epoch)
            // The downstream ladder — failure speak, confirm relay, history
            // marker — sees the retry's result, not the empty first roll.
            orchestratorLane = retry
            // The retry await is a suspension: a preempt or supersede can land during it.
            if Task.isCancelled {
                appendCancelledEpilogue(
                    spokenText: spokenText, actionTurn: actionTurn,
                    outcomes: retry.outcomes, epoch: epoch)
                continuation.finish()
                return
            }
            if retry.outcomes.isEmpty, retry.confirmQuestion == nil {
                // AN IGNORED INSTRUCTION GETS REPLACED BY A MECHANISM.
                let offer = retry.affordanceOffer
                    ?? orchestratorLane?.affordanceOffer
                let acted = offer.map { $0.score >= AffordanceProbe.confidentFloor } == true
                    ? await dispatchAffordanceAct(
                        goal: userText, continuation: continuation, epoch: epoch)
                    : nil
                if let acted {
                    // Silent on success, spoken on failure — the action-turn rhythm, unchanged.
                    if !acted.ok {
                        continuation.yield(.token(acted.summary))
                        spokenText = acted.summary
                    }
                } else {
                    let line = writingTarget == .selection
                        ? Self.couldNotReplaceSelectionLine()
                        : Self.couldNotActLine(label: Self.routineLabel(from: userText))
                    continuation.yield(.token(line))
                    spokenText = line
                }
            }
        }

        // Rule 4: everything after a server-voiced lane — CONFIRM questions,
        // fallback prose — is narrated by the local voice.
        if serverVoiced {
            continuation.yield(.speechSource(.local))
        }

        // Attached lane blew its cap. Speak first.
        if laneStalled {
            let line = Self.stalledLine(label: Self.routineLabel(from: userText))
            let sentence = spokenText.isEmpty ? line : " \(line)"
            continuation.yield(.token(sentence))
            spokenText += sentence
        }

        if sewnLane.failed, spokenText.isEmpty {
            if actionTurn, !(orchestratorLane?.outcomes.isEmpty ?? true) {
                // The action lane has grounded outcomes and the action-first
                // contract is silent success. A missing voice lane must not
                // add an ungrounded blanket claim after the fact.
            } else {
                // Sewn never spoke — the orchestrator's captured prose is the
                // best available reply. With no grounded outcome, say only
                // what is known; never imply an action ran.
                let fallback = (orchestratorLane?.text.isEmpty ?? true)
                    ? "I can't reach Sewn right now, so I'm without my usual voice."
                    : orchestratorLane!.text
                continuation.yield(.token(fallback))
                spokenText = fallback
            }
        } else if sewnLane.failed {
            let notice = " …I lost the rest of that thought — the Sewn connection dropped."
            continuation.yield(.token(notice))
            spokenText += notice
        } else if spokenText.isEmpty, !actionTurn,
                  let laneText = orchestratorLane?.text, !laneText.isEmpty {
            // Sewn succeeded but said nothing (rare) — don't leave silence.
            // Action turns are silent BY DESIGN: never speak orchestrator
            // prose for them.
            continuation.yield(.token(laneText))
            spokenText = laneText
        }

        // Takeover: Lane A's acknowledgement is replaced, not appended.
        var voicedText = spokenText
        if !laneStalled, !sewnLane.failed, !spokenText.isEmpty,
           let lane = orchestratorLane,
           lane.confirmQuestion == nil, lane.question == nil,
           !lane.outcomes.isEmpty,
           Self.unrecoveredFailure(in: lane.outcomes) == nil,
           !lane.outcomes.contains(where: \.deferred),
           lane.outcomes.contains(where: { dispatcher?.isReadOnly($0.skillName) == false }),
           !KokoroStreamSpeaker.mayAlreadyBeAudible(spokenText) {
            continuation.yield(.retractSpeech)
            voicedText = ""
        }

        // Trace: voice spoke on a non-action turn with no mutating lane outcome.
        if !actionTurn, !spokenText.isEmpty,
           orchestratorLane?.outcomes.contains(where: {
               dispatcher?.isReadOnly($0.skillName) == false
           }) != true {
            AmbientTraceLog.shared.noteVoiceSpokeWithoutMutation()
        }

        // A QUESTION THE LANE ASKED IS THE REPLY, spoken as a question.
        if let lane = orchestratorLane, let asked = Self.openQuestion(in: lane.outcomes) {
            let line = voicedText.isEmpty ? asked.summary : " \(asked.summary)"
            continuation.yield(.token(line))
            spokenText = actionTurn ? asked.summary : Self.filed(spokenText, line)
            voicedText += line
        }

        // Silent success, SPOKEN failure — on EVERY path.
        if let lane = orchestratorLane,
           let firstFailure = Self.unrecoveredFailure(in: lane.outcomes) {
            let standalone = "That didn't go through — \(firstFailure.summary)"
            let line = voicedText.isEmpty
                ? standalone
                : " Though — that didn't go through: \(firstFailure.summary)"
            continuation.yield(.token(line))
            spokenText = actionTurn ? standalone : Self.filed(spokenText, line)
            voicedText += line
        }

        // Reads the lane performed and joined — and where they go now.
        var laneReads: [LaneOutcome] = []
        if !actionTurn, let lane = orchestratorLane, lane.confirmQuestion == nil {
            laneReads = lane.outcomes.filter {
                $0.ok && !$0.deferred && dispatcher?.isReadOnly($0.skillName) == true
                    && !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        // A MISS IS NOT A DELIVERY. `foundNothing` says the binding looked and the thing is not there
        // PIN: The ALTERNATION marker below deliberately keeps counting misses: that read genuinely RAN
        let joinedReads = laneReads.filter { !$0.foundNothing }
        if !joinedReads.isEmpty, readPassages.isEmpty {
            // DID *THESE* READS LAND? Matched by CONTENT, in the same spirit as `noteSpoken`
            let held = world.store.reads(since: turnStartedAt)
            let landed = held.contains { fact in
                !fact.content.isEmpty
                    && joinedReads.contains { $0.summary.contains(fact.content) }
            }
            readLedger.record(ReadDelivery(
                route: landed ? .registered : .discarded,
                detail: joinedReads.map(\.skillName).joined(separator: ", "),
                characters: joinedReads.reduce(0) { $0 + $1.summary.count }))
        }

        // G4 — A REVISION REPORTS ITSELF, on the JOINED path.
        if let sentence = revisionReport(
            intent: editIntent, target: located,
            writingTarget: writingTarget,
            acceptedOffer: acceptedOffer,
            outcomes: orchestratorLane?.outcomes ?? [],
            after: voicedText, continuation: continuation) {
            spokenText = Self.filed(spokenText, sentence)
            voicedText += sentence
        }

        // A protected action came out of this turn's orchestration: relay its question deterministically (never trusting model prose to ask).
        if let question = orchestratorLane?.confirmQuestion,
           dispatcher?.hasPendingSkillConfirmation == true {
            let sentence = voicedText.isEmpty ? question : " \(question)"
            continuation.yield(.token(sentence))
            spokenText = Self.filed(spokenText, sentence)
            voicedText += sentence
        }

        // History write. A silent action turn still needs a NON-EMPTY assistant turn: spokenMessages() drops empty ones from the Sewn wire
        let historyText: String
        if !spokenText.isEmpty {
            historyText = spokenText
        } else if actionTurn {
            if let lane = orchestratorLane {
                let skills = lane.outcomes.map(\.skillName)
                if skills.isEmpty {
                    historyText = "(no action was needed)"
                } else if lane.outcomes.contains(where: \.deferred) {
                    // A deferred spawn joined in-turn: the marker must carry the ack ("(started: delegate_coding
                    historyText = Self.doneMarker(outcomes: lane.outcomes)
                } else {
                    historyText = "(ran: \(skills.joined(separator: ", ")))"
                }
            } else {
                historyText = "(on it)"
            }
        } else if !laneReads.isEmpty {
            // ALTERNATION on a read turn — the reason `laneReads` outlived the second pass.
            historyText = "(read: \(laneReads.map(\.skillName).joined(separator: ", ")))"
        } else {
            historyText = spokenText
        }
        // Stripped before persisting: history is replayed to Sewn every
        // later turn — a leaked blob here becomes a parrot loop.
        appendHistory(
            BrainTurn(role: .assistant, text: sanitizedSpoken(historyText)),
            epoch: epoch)
        // Offered prose from spokenText, never historyText (that may be a read marker).
        noteOfferedProse(spoken: spokenText, place: leadPlace)

        // Write back what was spoken about a fact.
        if !readPassages.isEmpty, !spokenText.isEmpty {
            // Return value is consumed here (it used to be discarded).
            let spokenKeys = world.store.noteSpoken(contentsIn: readPassages, note: spokenText)
            for key in spokenKeys {
                guard case .namedRead(let document, _) = key.slot,
                      let document, !document.isEmpty else { continue }
                // Fact key already carries the lane — spoken-about lands on the app, not the host.
                wiring.containers.noteEvidence(
                    place: key.place, key: document, .spokenAbout)
            }
        }

        if let contribution = sewnLane.contribution, let json = contribution.jsonString {
            continuation.yield(.contribution(json: json))
        }
        continuation.yield(.completed(fullText: spokenText))

        // Sewn folded the conversation into a memory — retain only the final
        // exchange, mirroring Sis's ChatStream truncation, and tell the app
        // so the visible transcript collapses the same way.
        if sewnLane.autoMemory {
            truncateAfterAutomemory()
            continuation.yield(.autoMemoryTriggered)
        }
        continuation.finish()
    }

    /// Waits up to the grace window for the lane's completion signal — fast skills stay in-turn, slow ones detach.
    private func laneFinished(signal: AsyncStream<Void>, grace: UInt64) async -> Bool {
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in signal {}   // ends when the lane finishes
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: grace)
                return false
            }
            let finished = await group.next() ?? false
            group.cancelAll()
            return finished && !Task.isCancelled
        }
    }

    /// HOW LONG AN ATTACHED LANE MAY HOLD THE TURN — the routine watchdog, expressed in seconds for `bounded`.
    /// PIN: Not a new number, and deliberately not one: the same lane, one grace window earlier
    private var attachedLaneBudget: TimeInterval {
        Double(routineWatchdogNanoseconds) / 1_000_000_000
    }

    // MARK: - Lane A runners — the spoken reply

    // internal for file split — treat as private
    func runSewnLane(
        sewnChat: any SewnChatProviding,
        messages: [SewnChatMessage],
        instructions: String,
        /// Stage-0 observation only (precedent: `runOrchestratorLane`'s
        /// `traceID`): which `RetrievalTraceLedger` row this lane's scope and
        /// contribution belong to. Nil books nothing.
        exchangeID: UUID? = nil,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation
    ) async -> SewnLaneResult {
        var result = SewnLaneResult()
        do {
            let events = sewnChat.stream(messages: messages, instructions: instructions)
            for try await event in events {
                if Task.isCancelled { break }
                switch event {
                case .token(let token):
                    result.text += token
                    continuation.yield(.token(token))
                case .scoped(let request):
                    if let exchangeID {
                        wiring.retrieval.noteSewnRequest(
                            request, forExchange: exchangeID)
                    }
                case .contribution(let contribution):
                    if result.contribution == nil { result.contribution = contribution }
                    // The ledger pairs it with the row's last-booked request
                    // itself — the rule lives beside the row, not in a
                    // hand-carried lane local.
                    if let exchangeID {
                        wiring.retrieval.noteContribution(
                            .init(contribution),
                            forExchange: exchangeID)
                    }
                case .autoMemory(let flag):
                    result.autoMemory = result.autoMemory || flag
                case .phase, .audio, .ttsFailed:
                    break   // realtime-route events; the classic client never emits them
                }
            }
        } catch {
            result.failed = true
        }
        return result
    }

    /// Lane A over the realtime WebSocket route: tokens become transcript events, PCM chunks feed the speaker directly
    /// Fallback rules (pinned by DualLaneTests): 1.
    // internal for file split — treat as private
    func runRealtimeSewnLane(
        realtime: any SewnRealtimeProviding,
        messages: [SewnChatMessage],
        instructions: String,
        /// Stage-0 observation only (precedent: `runOrchestratorLane`'s
        /// `traceID`): which `RetrievalTraceLedger` row this lane's scope and
        /// contribution belong to. Nil books nothing.
        exchangeID: UUID? = nil,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation
    ) async -> (result: SewnLaneResult, serverVoiced: Bool, fellBackPreStream: Bool) {
        var result = SewnLaneResult()
        var forwardedAny = false
        var serverVoiced = false

        func markForwarding() {
            guard !forwardedAny else { return }
            forwardedAny = true
            serverVoiced = true
            continuation.yield(.speechSource(.server))
        }

        do {
            let events = realtime.streamTurn(messages: messages, instructions: instructions)
            for try await event in events {
                if Task.isCancelled { break }
                // Content-vs-bookkeeping is classified ON THE EVENT (`SewnChatEvent.forwardsContent`), never per arm here: `forwardedAny` is rule 2's discriminator
                if event.forwardsContent { markForwarding() }
                switch event {
                case .token(let token):
                    result.text += token
                    continuation.yield(.token(token))
                case .audio(let pcm, let sampleRate):
                    continuation.yield(.audioChunk(pcm: pcm, sampleRate: sampleRate))
                case .scoped(let request):
                    // MUST NOT count as forwarded content — the client yields `.scoped` before it even connects, so counting it would make every pre-stream failure look mid-turn.
                    if let exchangeID {
                        wiring.retrieval.noteSewnRequest(
                            request, forExchange: exchangeID)
                    }
                case .phase:
                    break
                case .ttsFailed:
                    // Server audio stopped; hand the rest to the local voice.
                    if serverVoiced {
                        serverVoiced = false
                        continuation.yield(.speechSource(.local))
                    }
                case .contribution(let contribution):
                    if result.contribution == nil { result.contribution = contribution }
                    // The ledger pairs it with the row's last-booked request
                    // itself — see `noteContribution`.
                    if let exchangeID {
                        wiring.retrieval.noteContribution(
                            .init(contribution),
                            forExchange: exchangeID)
                    }
                case .autoMemory(let flag):
                    result.autoMemory = result.autoMemory || flag
                }
            }
        } catch {
            guard forwardedAny else {
                return (result, false, true)
            }
            if serverVoiced {
                serverVoiced = false
                continuation.yield(.speechSource(.local))
            }
            result.failed = true
        }
        return (result, serverVoiced, false)
    }


    // MARK: - Lane B — the silent orchestrator

    /// Skill loop with voice removed — rounds dispatch as in legacy; prose kept for offline fallback.
    // internal for file split — treat as private
    func runOrchestratorLane(
        userText: String,
        systemPrompt: String,
        seed: [BrainTurn],
        emitter: LaneEmitter,
        target: LocatedPassage? = nil,
        worldVetoArming: WorldVeto.Arming? = nil,
        /// Stage-0 observation only — see `sewnTurn`.
        traceID: UUID? = nil,
        /// Classifier verdicts, passed rather than re-derived — used only for "did they ask for a change?"
        actionTurn: Bool = false,
        editIntent: EditIntent? = nil,
        /// Route shape — first reader of the route in this tree, not only a recorder.
        routeIntent: AmbientIntent? = nil,
        writingTarget: AmbientWritingTarget? = nil,
        /// Pre-lane look fired and missed its budget. Voice already promised a look.
        lookUnderway: Bool = false,
        /// Pre-lane look already answered this turn. Look-first nudge must not fire.
        servedByPreLook: Bool = false,
        /// Pre-lane READ already answered this turn (a buffer, a document, a
        /// selection — not a look). Voice already holds their work; this
        /// lane's job is only what is NOT in that passage.
        servedByRead: Bool = false,
        /// Whether the turn is still waiting on this lane. Nil for probes and the legacy path.
        attachment: LaneAttachment? = nil
    ) async -> OrchestratorLaneResult {
        var result = OrchestratorLaneResult()
        guard let dispatcher else { return result }
        // G2 — located passage reaches the lane that executes Skills.
        var orchestratorPrompt = systemPrompt + "\n\n" + MaryPrompts.orchestratorAddendum
        if writingTarget == .selection {
            orchestratorPrompt += "\n\n" + MaryPrompts.selectionRevisionInstruction
        }
        if let target {
            orchestratorPrompt += "\n\n" + MaryPrompts.targetBrief(target)
        }
        // Pre-look already served — note rides the same prompt seam as the passage.
        // A read outranks a look: the voice holds actual content, not a glance.
        if servedByRead {
            orchestratorPrompt += "\n\n" + MaryPrompts.servedByReadNote
        } else if servedByPreLook {
            orchestratorPrompt += "\n\n" + MaryPrompts.servedByLookNote
        }
        var laneHistory = seed

        // G3 — revision veto. Bounds and judgement live in `RevisionVeto`; this is plumbing.
        var veto = RevisionVeto(target: target)
        // World veto — armed by a revise-cue with a live ledger referent, never by the habit.
        var worldVeto = WorldVeto(arming: worldVetoArming)

        var usedEmptyRetry = false
        // Whether this turn asked for a change (action, edit intent, or transform vocabulary).
        let impliesAction = actionTurn || editIntent != nil
            || AmbientRanker.namesTransform(userText)
        // ONE LESSON PER LANE, from the words that started it — a routine's
        // later steps must not each map this utterance onto a Skill the user
        // never named. Nil when the route teaches nothing (revise, halt, and
        // the classifier-owned intents the embedding never settles).
        let routingHabitGrant = RoutingHabitRecordingContext.grant(
            lane: .model, query: userText, route: routeIntent)
        var usedContinuation = false
        var round = 0
        do {
            while round < maxSkillRounds {
                round += 1
                var roundText = ""
                var skillInvocations: [ModelSkillInvocation] = []
                var roundProjection: AbilityRuntime.RosterProjection?

                // Generation rounds serialize only for engines that need it (local MLX).
                let roundStart = DispatchTime.now()
                var gateWaitMs: UInt64 = 0
                let queueDepth = engineGate.waiterCount
                do {
                    var holdsGate = false
                    if engine.requiresExclusiveGeneration {
                        let attached = attachment?.isAttached ?? true
                        if !attached, engineGate.waiterCount >= Self.maxDetachedRoutines {
                            Self.laneLog.info(
                                "detached lane dropped — engine gate already at cap")
                            break
                        }
                        // Live turn precedes background; once detached it joins them.
                        holdsGate = await engineGate.acquire(
                            priority: attached ? .attached : .detached)
                        gateWaitMs = Self.elapsedMs(since: roundStart)
                    }
                    defer { if holdsGate { engineGate.release() } }
                    // ONE PROJECTION PER ROUND. The offered schemas, the
                    // NOOP log's names and the sanitizer's names are the same
                    // roster; each used to arbitrate it again.
                    roundProjection = dispatcher.projectRoster()
                    let events = await actingEvents(
                        system: orchestratorPrompt, history: laneHistory,
                        skills: roundProjection?.schemas ?? [])
                    for try await event in events {
                        if Task.isCancelled { break }
                        switch event {
                        case .text(let token):
                            guard skillInvocations.isEmpty else { break }
                            roundText += token
                        case .skillInvocation(let rawInvocation):
                            let invocation = Self.selectionInvocation(
                                rawInvocation, writingTarget: writingTarget)
                            skillInvocations.append(invocation)
                            // Trace what the model reached for vs. what a narrowed roster would hide.
                            let reference = dispatcher.skillReference(for: invocation.name)
                            if let traceID {
                                let consumedInteractions = dispatcher.abilitySnapshot
                                    .skill(invocationName: invocation.name)
                                    .map { runtime in
                                        (SchemaSignalTurnContext.snapshot ?? .empty)
                                            .consumedReferences(for: runtime.skill)
                                    } ?? []
                                AmbientTraceLog.shared.noteSkillInvocation(
                                    reference,
                                    effect: dispatcher.abilitySnapshot.effect(
                                        forInvocation: invocation.name),
                                    inputTypes: dispatcher.abilitySnapshot.inputTypes(
                                        forInvocation: invocation.name),
                                    outputTypes: dispatcher.abilitySnapshot.outputTypes(
                                        forInvocation: invocation.name),
                                    consumedInteractions: consumedInteractions,
                                    forTurn: traceID)
                            }
                            emitter.emitSkillInvocation(
                                reference: reference,
                                argumentsJSON: invocation.argumentsJSON,
                                runID: invocation.id
                            )
                        case .done:
                            break
                        }
                    }
                }

                let generateMs = Self.elapsedMs(since: roundStart) - gateWaitMs
                let dispatchStart = DispatchTime.now()
                let callCount = skillInvocations.count
                // Defer the round log — early `continue`/`return` is the line worth seeing.
                defer {
                    let line = "round \(round) — queued \(gateWaitMs)ms"
                        + " (depth \(queueDepth)), generated \(generateMs)ms,"
                        + " dispatched \(Self.elapsedMs(since: dispatchStart))ms,"
                        + " calls=\(callCount),"
                        + " attached=\(attachment?.isAttached ?? true),"
                        + " trace=\(traceID?.uuidString.prefix(8) ?? "-")"
                    Self.laneLog.info("\(line, privacy: .public)")
                }

                if Task.isCancelled { return result }

                if roundText.isEmpty, skillInvocations.isEmpty, !usedEmptyRetry {
                    usedEmptyRetry = true
                    round -= 1
                    continue
                }

                guard !skillInvocations.isEmpty else {
                    if !usedContinuation, writingTarget == .selection {
                        usedContinuation = true
                        orchestratorPrompt += "\n\n" + MaryPrompts.selectionRevisionNudge
                        Self.laneLog.info("selected-text revision did not dispatch — retrying once")
                        continue
                    }
                    // Staging failed on an acting turn — one bounded continuation.
                    // PIN: Conditions are about the shape of the work, not the sentence.
                    if !usedContinuation,
                       let failed = result.outcomes.last(where: {
                           !$0.ok && dispatcher.preparesSurface($0.skillName)
                       }),
                       impliesAction {
                        usedContinuation = true
                        laneHistory.append(BrainTurn(
                            role: .user,
                            text: MaryPrompts.stageRecoveryNudge(
                                failedSkill: failed.skillName)))
                        Self.laneLog.info("staging failed on an acting turn — recovering once")
                        continue
                    }
                    // Only read/prepared/cognitive on an acting turn — continue once.
                    if !usedContinuation, !result.outcomes.isEmpty,
                       !result.outcomes.contains(where: \.landed),
                       result.outcomes.allSatisfy({
                           dispatcher.isReadOnly($0.skillName)
                               || dispatcher.isNonEffectful($0.skillName)
                               || dispatcher.preparesSurface($0.skillName)
                       }),
                       impliesAction {
                        usedContinuation = true
                        laneHistory.append(BrainTurn(
                            role: .user, text: MaryPrompts.continuationNudge))
                        Self.laneLog.info("lane only read/prepared on an acting turn — continuing once")
                        continue
                    }
                    // Never looked or read, on a question about their work — look once.
                    if !usedContinuation, result.outcomes.isEmpty,
                       !servedByPreLook, !servedByRead,
                       routeIntent == .perceive || lookUnderway {
                        usedContinuation = true
                        laneHistory.append(BrainTurn(
                            role: .user, text: MaryPrompts.lookFirstNudge))
                        Self.laneLog.info("lane NOOPed a question about their work — looking once")
                        continue
                    }
                    // Screen already offers a control, and nobody said so.
                    // PIN: Last escape — only after cheaper "nothing ran" readings declined.
                    if !usedContinuation, result.outcomes.isEmpty, impliesAction,
                       let offer = AffordanceProbe.candidate(for: userText),
                       !offer.labels.isEmpty {
                        usedContinuation = true
                        result.affordanceOffer = offer
                        laneHistory.append(BrainTurn(
                            role: .user,
                            text: MaryPrompts.affordanceNudge(
                                labels: offer.labels)))
                        Self.laneLog.info("lane NOOPed while the screen offered a control — naming it once")
                        continue
                    }
                    // Nothing to execute — keep prose as offline fallback for `sewnTurn`.
                    TurnCircuitLog.laneNOOP(
                        offeredNames: Array(roundProjection?.names ?? []))
                    result.text = sanitizedSpoken(
                        roundText, knownSkillNames: roundProjection?.names)
                    return result
                }

                // Skill rounds carry empty text so the tool_use → tool_result pairing survives.
                let pendingBeforeDispatch = dispatcher.pendingSkillConfirmationID
                var roundTurns = [BrainTurn(role: .assistant, text: "", skillInvocations: skillInvocations)]
                var lastOutcomes: [String] = []
                let outcomesBefore = result.outcomes.count
                for call in skillInvocations {
                    if Task.isCancelled {
                        // Superseded mid-round — stop issuing calls; synthetic results keep the pair.
                        roundTurns.append(BrainTurn(
                            role: .skillResult, text: "(cancelled before running)",
                            skillInvocationID: call.id, skillName: call.name))
                        continue
                    }
                    // Revision veto — caret write with a located passage is not dispatched.
                    // PIN: Nothing ran, so `outcomes` must not gain a row.
                    if let redirect = veto.redirect(for: call.name) {
                        let reference = dispatcher.skillReference(for: call.name)
                        emitter.emitSkillResult(.refused(
                            id: call.id,
                            action: BehavioralAction(
                                intention: call.name,
                                argumentsJSON: call.argumentsJSON,
                                skill: reference),
                            reason: redirect))
                        if let traceID {
                            AmbientTraceLog.shared.noteSkillResult(
                                reference, status: .blocked,
                                forTurn: traceID)
                        }
                        roundTurns.append(BrainTurn(
                            role: .skillResult, text: redirect,
                            skillInvocationID: call.id, skillName: call.name))
                        lastOutcomes.append(redirect)
                        continue
                    }
                    // World veto — rival watched world on a writing-led turn that named none.
                    if let redirect = worldVeto.redirect(
                        for: call.name,
                        attention: dispatcher.attention(ofSkill: call.name)) {
                        let reference = dispatcher.skillReference(for: call.name)
                        emitter.emitSkillResult(.refused(
                            id: call.id,
                            action: BehavioralAction(
                                intention: call.name,
                                argumentsJSON: call.argumentsJSON,
                                skill: reference),
                            reason: redirect))
                        if let traceID {
                            AmbientTraceLog.shared.noteSkillResult(
                                reference, status: .blocked,
                                forTurn: traceID)
                        }
                        roundTurns.append(BrainTurn(
                            role: .skillResult, text: redirect,
                            skillInvocationID: call.id, skillName: call.name))
                        lastOutcomes.append(redirect)
                        continue
                    }
                    // THE SAME CALL THAT JUST FAILED IS NOT TRIED AGAIN, and one that
                    // ran unproven waits for a look. See MaryBrain+RepeatGuard.
                    if let prior = Self.alreadyFailed(call, in: result.outcomes) {
                        let line = Self.repeatedFailureLine(call.name, prior: prior)
                        roundTurns.append(BrainTurn(
                            role: .skillResult, text: line,
                            skillInvocationID: call.id, skillName: call.name))
                        lastOutcomes.append(line)
                        result.repeatedFailedCall = true
                        Self.laneLog.info("repeat of a failed call refused — the lane ends")
                        continue
                    }
                    if Self.alreadyRanUnproven(
                        call, in: result.outcomes, isRead: dispatcher.isReadOnly) != nil {
                        let line = Self.unprovenRepeatLine(call.name)
                        roundTurns.append(BrainTurn(
                            role: .skillResult, text: line,
                            skillInvocationID: call.id, skillName: call.name))
                        lastOutcomes.append(line)
                        Self.laneLog.info("repeat of an unproven act held — look first")
                        continue
                    }
                    let startedAt = Date()
                    let outcome = await RoutingHabitRecordingContext.withGrant(routingHabitGrant) {
                        await dispatcher.dispatch(
                            name: call.name, argumentsJSON: call.argumentsJSON,
                            runID: call.id)
                    }
                    let reference = outcome.skillReference
                        ?? dispatcher.skillReference(for: call.name)
                    emitter.emitSkillResult(BehavioralActionRecord(
                        outcome: outcome,
                        intention: call.name,
                        argumentsJSON: call.argumentsJSON,
                        reference: reference,
                        runID: call.id,
                        startedAt: startedAt))
                    if let traceID {
                        AmbientTraceLog.shared.noteSkillResult(
                            reference,
                            status: outcome.status,
                            foundNothing: outcome.foundNothing,
                            forTurn: traceID)
                    }
                    roundTurns.append(BrainTurn(
                        role: .skillResult,
                        text: outcome.summary,
                        skillInvocationID: call.id,
                        skillName: call.name
                    ))
                    lastOutcomes.append(outcome.summary)
                    result.outcomes.append(LaneOutcome(
                        skillName: reference.bindingOperation ?? call.name,
                        outcome: outcome,
                        invocation: call.name,
                        argumentsJSON: call.argumentsJSON))
                    archive(
                        reference: reference,
                        skillName: reference.bindingOperation ?? call.name,
                        argumentsJSON: call.argumentsJSON,
                            summary: outcome.summary, userText: userText,
                            succeeded: outcome.ok,
                            deferred: outcome.deferred,
                            policy: outcome.archivePolicy)
                }
                // Lane history keeps the model's plan; shared history still does not.
                var laneRoundTurns = roundTurns
                let planned = sanitizedSpoken(
                    roundText, knownSkillNames: roundProjection?.names)
                if !planned.isEmpty {
                    laneRoundTurns[0] = BrainTurn(
                        role: .assistant, text: planned, skillInvocations: skillInvocations)
                }
                laneHistory.append(contentsOf: laneRoundTurns)
                result.laneTurns.append(contentsOf: roundTurns)

                if Task.isCancelled { return result }

                // A QUESTION TO THE PERSON ENDS THE LANE — the question is the reply.
                // PIN: THE ONLY OTHER THING THAT PARKS A TURN IS A CONFIRMATION, and
                // an ambiguity is not one: nothing is replayed on "yes". The next
                // utterance ("the second one") is a fresh turn.
                if let asked = result.outcomes[outcomesBefore...].first(where: \.asksThePerson) {
                    result.question = asked.summary
                    return result
                }
                if result.repeatedFailedCall { return result }

                // Stored pending action only — "CONFIRM:" text can be forged by echoed Skill output.
                if let pendingAfterDispatch = dispatcher.pendingSkillConfirmationID,
                   pendingAfterDispatch != pendingBeforeDispatch {
                    // Stored preview, not a parse of the outcome text.
                    result.confirmQuestion = dispatcher.pendingSkillConfirmationPreview
                        ?? Self.confirmQuestion(fromOutcomes: lastOutcomes)
                    return result
                }
            }
        } catch {
            // Orchestration failing must never take the voice down with it.
            return result
        }
        return result
    }

    // internal for file split — treat as private
    static func selectionInvocation(
        _ invocation: ModelSkillInvocation, writingTarget: AmbientWritingTarget?
    ) -> ModelSkillInvocation {
        guard writingTarget == .selection, invocation.name == "type_at_cursor",
              let data = invocation.argumentsJSON.data(using: .utf8),
              var arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return invocation }
        arguments["mode"] = TypingMode.replaceSelection.rawValue
        guard let normalized = try? JSONSerialization.data(
            withJSONObject: arguments, options: [.sortedKeys]),
              let argumentsJSON = String(data: normalized, encoding: .utf8)
        else { return invocation }
        return ModelSkillInvocation(
            id: invocation.id, name: invocation.name, argumentsJSON: argumentsJSON)
    }

    // MARK: - Engine mode — the turn with no Lane A

    /// THE TURN WITH NO LANE A. Nothing here is on-device — generation moved
    /// into Sewn, and `engine` is whatever `setEngine` installed. What this
    /// path means is that this brain has no `SewnChatProviding`, so the engine
    /// seat both acts AND speaks instead of a voice lane running beside it.
    /// Sand is its only production caller: `SandTurnHost` builds a brain with
    /// no Sewn chat, which is what puts a person in the model seat.
    /// PIN: NOT A LESSER TURN, and this is the parity that says so.
    /// PIN: ALL FOUR CROSS, and one of them changes shape on the way: - G1, the LOCATE
    // internal for file split — treat as private
    func engineTurn(
        userText: String,
        systemPrompt: String,
        /// THE TURN'S ROUTE, WHOLE — same parity as `sewnTurn`: the shape of this
        /// turn was decided once, and this path reads that decision rather than
        /// being handed a re-spelled copy of its parts.
        route: AmbientRoute,
        target: LocatedPassage? = nil,
        acceptedOffer: Bool = false,
        worldVetoArming: WorldVeto.Arming? = nil,
        traceID: UUID? = nil,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation,
        epoch: UInt64
    ) async {
        let actionTurn = route.isActionTurn
        let editIntent = route.verdicts.editIntent
        let writingTarget = route.writingTarget
        // ONE LESSON PER LANE, from the words that started it. Built here so a
        // multi-round turn cannot teach the router three different things, and
        // so the query is this turn's utterance rather than whatever the
        // process-wide routing query says by the time a round lands.
        let routingHabitGrant = RoutingHabitRecordingContext.grant(
            lane: .model, query: userText, route: route.intent)
        var fullText = ""
        var usedEmptyRetry = false
        // ONE EXTRA ROUND ACROSS BOTH RUNGS, the way the orchestrator lane latches it:
        // a turn may be nudged once, not once per reason.
        var usedContinuation = false
        // The screen's offer, when a rung named one — read again at the deterministic
        // press so the score is the one that was just measured.
        var affordanceOffer: AffordanceCandidate?

        // G2 — THE LOCATED PASSAGE REACHES THE LOOP THAT EXECUTES SKILLS.
        var turnPrompt = systemPrompt
        if writingTarget == .selection {
            turnPrompt += "\n\n" + MaryPrompts.selectionRevisionInstruction
        }
        if let target {
            turnPrompt += "\n\n" + MaryPrompts.targetBrief(target)
        }
        // G3 — one veto value for the whole turn, so "at most once" means at
        // most once per TURN here exactly as it means at most once per LANE
        // over there.
        var veto = RevisionVeto(target: target)
        var worldVeto = WorldVeto(arming: worldVetoArming)
        // G4's fuel. The engine loop never needed settled outcomes before — it speaks from the model's own prose
        var outcomes: [LaneOutcome] = []
        var repeatedFailedCall = false

        do {
            var round = 0
            while round < maxSkillRounds {
                round += 1
                var roundText = ""
                var skillInvocations: [ModelSkillInvocation] = []
                // One projection per round, as in the orchestrator lane.
                let roundProjection = dispatcher?.projectRoster()
                let schemas = roundProjection?.schemas ?? []

                // Same engine-gate rule as the orchestrator lane: a detached
                // routine may still be generating when an engine turn starts.
                do {
                    var holdsGate = false
                    if engine.requiresExclusiveGeneration {
                        // The engine path runs inside the turn and never
                        // detaches, so its rounds are always ones a person
                        // is waiting on.
                        holdsGate = await engineGate.acquire(priority: .attached)
                    }
                    defer { if holdsGate { engineGate.release() } }
                    let events = await actingEvents(
                        system: turnPrompt, history: history, skills: schemas)
                    for try await event in events {
                        if Task.isCancelled { break }
                        switch event {
                        case .text(let token):
                            // Once a round has called a Skill, trailing prose is almost always a hallucinated result ("it's three fifteen…") — the grounded confirmation round speaks instead.
                            guard skillInvocations.isEmpty else { break }
                            roundText += token
                            if !actionTurn {
                                fullText += token
                                continuation.yield(.token(token))
                            }
                        case .skillInvocation(let rawInvocation):
                            let invocation = Self.selectionInvocation(
                                rawInvocation, writingTarget: writingTarget)
                            skillInvocations.append(invocation)
                            let reference = dispatcher?.skillReference(for: invocation.name)
                                ?? AbilityLibrary.shared.snapshot().reference(forInvocation: invocation.name)
                            if let traceID {
                                let registry = dispatcher?.abilitySnapshot
                                    ?? AbilityLibrary.shared.snapshot()
                                let consumedInteractions = registry
                                    .skill(invocationName: invocation.name)
                                    .map { runtime in
                                        (SchemaSignalTurnContext.snapshot ?? .empty)
                                            .consumedReferences(for: runtime.skill)
                                    } ?? []
                                AmbientTraceLog.shared.noteSkillInvocation(
                                    reference,
                                    effect: registry.effect(forInvocation: invocation.name),
                                    inputTypes: registry.inputTypes(forInvocation: invocation.name),
                                    outputTypes: registry.outputTypes(forInvocation: invocation.name),
                                    consumedInteractions: consumedInteractions,
                                    forTurn: traceID)
                            }
                            continuation.yield(.skillInvocation(
                                reference: reference,
                                argumentsJSON: invocation.argumentsJSON,
                                runID: invocation.id
                            ))
                        case .done:
                            break
                        }
                    }
                }

                if Task.isCancelled {
                    // Keep the partial reply so the conversation stays coherent
                    // after barge-in. (A superseded turn's epoch is stale —
                    // the append drops and the amended turn starts clean.)
                    if !roundText.isEmpty {
                        appendHistory(
                            BrainTurn(role: .assistant, text: sanitizedSpoken(roundText)),
                            epoch: epoch)
                    }
                    pruneSyntheticTurns()
                    continuation.finish()
                    return
                }

                // A quantized model occasionally emits an entirely empty round; one silent retry beats a blank page.
                if roundText.isEmpty, skillInvocations.isEmpty, !usedEmptyRetry {
                    usedEmptyRetry = true
                    // `foundNothing` excluded too: a Skill that ran and reported nothing there ("no code editor in front of me right now") is `ok: true` by this codebase's own…
                    if outcomes.contains(where: {
                        $0.ok && !$0.blocked && !$0.requested && !$0.foundNothing
                    }) {
                        appendHistory(
                            BrainTurn(role: .user, text: Self.groundedRetryNudge),
                            epoch: epoch)
                    }
                    round -= 1
                    continue
                }

                guard let dispatcher, !skillInvocations.isEmpty else {
                    // NOT A LESSER TURN — the rungs the orchestrator lane has
                    // are here too. Without them this turn ends politely on
                    // work it only half did, and the receipts (`landed`) that the
                    // browsing lane spent its whole design earning are read by nobody.
                    //
                    // Only read or prepared a surface, on a turn that asked for
                    // something to be DONE — say so once and let it finish.
                    //
                    // PIN: GATED ON `actionTurn` ALONE, narrower than the orchestrator's
                    // wider "implies action" reading (edit intent or a named transform).
                    // A non-action engine turn streams its prose live as the tokens
                    // arrive (see the `.text` case above), so continuing after it spoke
                    // would say the same thing twice — which is not a risk the
                    // orchestrator lane runs, because it buffers into `laneHistory`.
                    if let dispatcher, !usedContinuation, actionTurn,
                       !outcomes.isEmpty,
                       !outcomes.contains(where: \.landed),
                       outcomes.allSatisfy({
                           dispatcher.isReadOnly($0.skillName)
                               || dispatcher.isNonEffectful($0.skillName)
                               || dispatcher.preparesSurface($0.skillName)
                       }) {
                        usedContinuation = true
                        appendHistory(
                            BrainTurn(role: .user, text: MaryPrompts.continuationNudge),
                            epoch: epoch)
                        Self.laneLog.info("engine turn only read or prepared on an acting turn — continuing once")
                        continue
                    }
                    // Nothing ran at all, and the screen is already offering something
                    // that would serve. Name it once; the press, if it comes, is below.
                    if !usedContinuation, actionTurn, outcomes.isEmpty,
                       let offer = AffordanceProbe.candidate(for: userText),
                       !offer.labels.isEmpty {
                        usedContinuation = true
                        affordanceOffer = offer
                        appendHistory(
                            BrainTurn(
                                role: .user,
                                text: MaryPrompts.affordanceNudge(labels: offer.labels)),
                            epoch: epoch)
                        Self.laneLog.info("engine turn NOOPed while the screen offered a control — naming it once")
                        continue
                    }

                    if skillInvocations.isEmpty {
                        TurnCircuitLog.laneNOOP(
                            offeredNames: Array(roundProjection?.names ?? []))
                    }
                    // Plain reply (or nothing left to execute) — the turn is done.
                    if actionTurn {
                        var reply = ""
                        if let failure = Self.unrecoveredFailure(in: outcomes) {
                            reply = "That didn't go through — \(failure.summary)"
                            continuation.yield(.token(reply))
                        } else if let sentence = revisionReport(
                            intent: editIntent,
                            target: target,
                            writingTarget: writingTarget,
                            acceptedOffer: acceptedOffer,
                            outcomes: outcomes,
                            after: "",
                            continuation: continuation) {
                            reply = sentence
                        } else if outcomes.isEmpty {
                            // AN IGNORED INSTRUCTION GETS REPLACED BY A MECHANISM. The
                            // model was told what the screen offers and still ran
                            // nothing; if one control answers the goal confidently
                            // enough, press it rather than report a failure. Same rung,
                            // same floor and the same `act_on_screen` the Sewn turn
                            // uses — it can do nothing the model could not have done.
                            let offer = affordanceOffer
                                ?? AffordanceProbe.candidate(for: userText)
                            let acted = offer.map {
                                $0.score >= AffordanceProbe.confidentFloor
                            } == true
                                ? await dispatchAffordanceAct(
                                    goal: userText, continuation: continuation, epoch: epoch)
                                : nil
                            if let acted {
                                // Silent on success, spoken on failure — the
                                // action-turn rhythm, unchanged.
                                if !acted.ok {
                                    reply = acted.summary
                                    continuation.yield(.token(reply))
                                }
                            } else {
                                reply = Self.couldNotActLine(
                                    label: Self.routineLabel(from: userText))
                                continuation.yield(.token(reply))
                            }
                        }
                        let historyText = reply.isEmpty
                            ? "(ran: \(outcomes.map(\.skillName).joined(separator: ", ")))"
                            : reply
                        appendHistory(
                            BrainTurn(role: .assistant, text: sanitizedSpoken(historyText)),
                            epoch: epoch)
                        pruneSyntheticTurns()
                        continuation.yield(.completed(fullText: reply))
                        continuation.finish()
                        return
                    }
                    var reply = roundText
                    // A QUESTION NEVER ENDS IN SILENCE.
                    //
                    // PIN: THE READ RAN; ONLY THE SENTENCE ABOUT IT IS MISSING.
                    // A non-action turn streams the model's prose as it arrives,
                    // so an empty round here means the model read the page (or
                    // the buffer) and then said nothing — and this exit would
                    // complete with an empty `fullText`, leaving the person
                    // looking at "Listening" with their question unanswered.
                    // The passage is in hand and is the honest answer, so it is
                    // spoken rather than dropped. The one round the empty-retry
                    // above already spent is what makes this the last resort
                    // rather than the first.
                    if fullText.isEmpty, reply.isEmpty, !outcomes.isEmpty {
                        let readBack = Self.spokenReadBack(outcomes: outcomes)
                        if !readBack.isEmpty {
                            reply = readBack
                            fullText += readBack
                            continuation.yield(.token(readBack))
                            Self.laneLog.info(
                                "engine turn read and said nothing — speaking the passage")
                            readLedger.record(ReadDelivery(
                                route: .spokenDetached,
                                detail: outcomes.map(\.skillName).joined(separator: ", "),
                                characters: readBack.count))
                        }
                    }
                    if let sentence = revisionReport(
                        intent: editIntent, target: target,
                        writingTarget: writingTarget,
                        acceptedOffer: acceptedOffer,
                        outcomes: outcomes,
                        after: reply, continuation: continuation) {
                        reply += sentence
                        fullText += sentence
                    }
                    appendHistory(
                        BrainTurn(role: .assistant, text: sanitizedSpoken(reply),
                                  skillInvocations: skillInvocations),
                        epoch: epoch)
                    pruneSyntheticTurns()
                    continuation.yield(.completed(fullText: fullText))
                    continuation.finish()
                    return
                }

                // Execute the commands and record results. Chained rounds run silently — the subshell way: run one command, read its result, decide the next.
                let pendingBeforeDispatch = dispatcher.pendingSkillConfirmationID
                let outcomesBefore = outcomes.count
                var roundTurns = [BrainTurn(
                    role: .assistant, text: sanitizedSpoken(roundText), skillInvocations: skillInvocations)]
                for call in skillInvocations {
                    if Task.isCancelled {
                        roundTurns.append(BrainTurn(
                            role: .skillResult, text: "(cancelled before running)",
                            skillInvocationID: call.id, skillName: call.name))
                        continue
                    }
                    // G3 — THE REVISION VETO, on this loop too. A caret write on a turn that located a real passage is not dispatched at all
                    if let redirect = veto.redirect(for: call.name) {
                        let reference = dispatcher.skillReference(for: call.name)
                        continuation.yield(.skillResult(record: .refused(
                            id: call.id,
                            action: BehavioralAction(
                                intention: call.name,
                                argumentsJSON: call.argumentsJSON,
                                skill: reference),
                            reason: redirect)))
                        if let traceID {
                            AmbientTraceLog.shared.noteSkillResult(
                                reference, status: .blocked,
                                forTurn: traceID)
                        }
                        roundTurns.append(BrainTurn(
                            role: .skillResult, text: redirect,
                            skillInvocationID: call.id, skillName: call.name))
                        continue
                    }
                    // The world veto crosses too.
                    if let redirect = worldVeto.redirect(
                        for: call.name,
                        attention: dispatcher.attention(ofSkill: call.name)) {
                        let reference = dispatcher.skillReference(for: call.name)
                        continuation.yield(.skillResult(record: .refused(
                            id: call.id,
                            action: BehavioralAction(
                                intention: call.name,
                                argumentsJSON: call.argumentsJSON,
                                skill: reference),
                            reason: redirect)))
                        if let traceID {
                            AmbientTraceLog.shared.noteSkillResult(
                                reference, status: .blocked,
                                forTurn: traceID)
                        }
                        roundTurns.append(BrainTurn(
                            role: .skillResult, text: redirect,
                            skillInvocationID: call.id, skillName: call.name))
                        continue
                    }
                    // THE SAME CALL THAT JUST FAILED IS NOT TRIED AGAIN, and one that
                    // ran unproven waits for a look. See MaryBrain+RepeatGuard.
                    if let prior = Self.alreadyFailed(call, in: outcomes) {
                        let line = Self.repeatedFailureLine(call.name, prior: prior)
                        roundTurns.append(BrainTurn(
                            role: .skillResult, text: line,
                            skillInvocationID: call.id, skillName: call.name))
                        repeatedFailedCall = true
                        Self.laneLog.info("repeat of a failed call refused — the turn wraps up")
                        continue
                    }
                    if Self.alreadyRanUnproven(
                        call, in: outcomes, isRead: dispatcher.isReadOnly) != nil {
                        let line = Self.unprovenRepeatLine(call.name)
                        roundTurns.append(BrainTurn(
                            role: .skillResult, text: line,
                            skillInvocationID: call.id, skillName: call.name))
                        Self.laneLog.info("repeat of an unproven act held — look first")
                        continue
                    }
                    let startedAt = Date()
                    let outcome = await RoutingHabitRecordingContext.withGrant(routingHabitGrant) {
                        await dispatcher.dispatch(
                            name: call.name, argumentsJSON: call.argumentsJSON,
                            runID: call.id)
                    }
                    let reference = outcome.skillReference
                        ?? dispatcher.skillReference(for: call.name)
                    continuation.yield(.skillResult(record: BehavioralActionRecord(
                        outcome: outcome,
                        intention: call.name,
                        argumentsJSON: call.argumentsJSON,
                        reference: reference,
                        runID: call.id,
                        startedAt: startedAt)))
                    if let traceID {
                        AmbientTraceLog.shared.noteSkillResult(
                            reference,
                            status: outcome.status,
                            foundNothing: outcome.foundNothing,
                            forTurn: traceID)
                    }
                    roundTurns.append(BrainTurn(
                        role: .skillResult,
                        text: outcome.summary,
                        skillInvocationID: call.id,
                        skillName: call.name
                    ))
                    outcomes.append(LaneOutcome(
                        skillName: reference.bindingOperation ?? call.name,
                        outcome: outcome,
                        invocation: call.name,
                        argumentsJSON: call.argumentsJSON))
                }
                appendHistory(contentsOf: roundTurns, epoch: epoch)
                if Task.isCancelled {
                    pruneSyntheticTurns()
                    continuation.finish()
                    return
                }
                // A QUESTION TO THE PERSON ENDS THE LANE — spoken as a question,
                // never as "that didn't go through". See the orchestrator lane.
                if let asked = outcomes[outcomesBefore...].first(where: \.asksThePerson) {
                    let question = asked.summary
                    continuation.yield(.token(question))
                    fullText = question
                    appendHistory(
                        BrainTurn(role: .assistant, text: sanitizedSpoken(question)),
                        epoch: epoch)
                    pruneSyntheticTurns()
                    continuation.yield(.completed(fullText: fullText))
                    continuation.finish()
                    return
                }
                if repeatedFailedCall { break }
                // Only a genuinely-stored pending action triggers the relay —
                // "CONFIRM:" text alone can be forged by echoed Skill output.
                if let pendingAfterDispatch = dispatcher.pendingSkillConfirmationID,
                   pendingAfterDispatch != pendingBeforeDispatch {
                    if actionTurn {
                        let question = dispatcher.pendingSkillConfirmationPreview
                            ?? Self.confirmQuestion(
                                fromOutcomes: outcomes.map(\.summary))
                        continuation.yield(.token(question))
                        fullText = question
                        appendHistory(
                            BrainTurn(role: .assistant, text: sanitizedSpoken(question)),
                            epoch: epoch)
                        pruneSyntheticTurns()
                        continuation.yield(.completed(fullText: fullText))
                        continuation.finish()
                        return
                    }
                    appendHistory(
                        BrainTurn(role: .user, text: Self.confirmRelayNudge),
                        epoch: epoch)
                }
            }

            // Budget exhausted with the model still running commands — force a spoken wrap-up.
            if actionTurn {
                var reply = ""
                if let asked = Self.openQuestion(in: outcomes) {
                    reply = asked.summary
                    continuation.yield(.token(reply))
                } else if let failure = Self.unrecoveredFailure(in: outcomes) {
                    reply = "That didn't go through — \(failure.summary)"
                    continuation.yield(.token(reply))
                } else if let sentence = revisionReport(
                    intent: editIntent,
                    target: target,
                    writingTarget: writingTarget,
                    acceptedOffer: acceptedOffer,
                    outcomes: outcomes,
                    after: "",
                    continuation: continuation) {
                    reply = sentence
                } else if outcomes.isEmpty {
                    reply = Self.couldNotActLine(
                        label: Self.routineLabel(from: userText))
                    continuation.yield(.token(reply))
                }
                let historyText = reply.isEmpty
                    ? "(ran: \(outcomes.map(\.skillName).joined(separator: ", ")))"
                    : reply
                appendHistory(
                    BrainTurn(role: .assistant, text: sanitizedSpoken(historyText)),
                    epoch: epoch)
                pruneSyntheticTurns()
                continuation.yield(.completed(fullText: reply))
                continuation.finish()
                return
            }
            appendHistory(BrainTurn(role: .user, text: Self.budgetNudge), epoch: epoch)
            var wrapText = ""
            do {
                var holdsGate = false
                if engine.requiresExclusiveGeneration {
                    // The engine path runs inside the turn and never
                    // detaches, so its rounds are always ones a person is
                    // waiting on.
                    holdsGate = await engineGate.acquire(priority: .attached)
                }
                defer { if holdsGate { engineGate.release() } }
                let wrapEvents = engine.stream(
                    system: turnPrompt, history: history, skills: dispatcher?.schemas ?? [])
                for try await event in wrapEvents {
                    if Task.isCancelled { break }
                    if case .text(let token) = event {
                        wrapText += token
                        fullText += token
                        continuation.yield(.token(token))
                    }
                }
            }
            // G4 on the OTHER exit. A revision that burned the whole round budget still changed the document, and the wrap-up is model prose about what it accomplished
            if let sentence = revisionReport(
                intent: editIntent, target: target,
                writingTarget: writingTarget,
                acceptedOffer: acceptedOffer,
                outcomes: outcomes,
                after: wrapText, continuation: continuation) {
                wrapText += sentence
                fullText += sentence
            }
            appendHistory(
                BrainTurn(role: .assistant, text: sanitizedSpoken(wrapText)), epoch: epoch)
            pruneSyntheticTurns()
            continuation.yield(.completed(fullText: fullText))
            continuation.finish()
        } catch {
            pruneSyntheticTurns()
            continuation.finish(throwing: error)
        }
    }

    // internal for file split — treat as private
    static let confirmRelayNudge =
        "(A protected action is waiting for the user's approval. Ask them the question from the CONFIRM result in one short spoken sentence. Nothing has run and there are NO results — do not invent, describe, or predict any. Do not call any Skill.)"

    // internal for file split — treat as private
    static let budgetNudge =
        "(Stop. You have used your command budget for this turn. Tell the user in one or two short spoken sentences what you accomplished and what remains. Do not call any Skill.)"

    /// Empty-round retry grounding — answer from the Skill result already in messages.
    // internal for file split — treat as private
    static let groundedRetryNudge =
        "(A Skill already ran this turn and its result is in the messages above — read it and answer with what it actually says. Do not greet, ask how their day was, or say anything generic; nothing here calls for small talk.)"

    // MARK: - The dispatch ceremony both lanes share

    /// Yield the invocation, dispatch it, yield the result row, append the
    /// invocation/result history pair. FOUR PATHS WROTE THIS OUT LONGHAND;
    /// the only thing that ever differed is the title-commit arming.
    @discardableResult
    func performSkillTurn(
        dispatcher: any AbilityDispatching,
        name: String,
        argumentsJSON: String,
        runIDPrefix: String,
        /// Armed only for a shortcut dispatch — a title match with no exact
        /// candidate may commit to its best guess rather than refuse. Lane B
        /// and model-driven dispatches never set this.
        allowTitleCommit: Bool = false,
        /// What this dispatch may teach the router, or nil to teach nothing.
        /// Only the paths that ARE a routing decision pass one: the deciding
        /// gates (confirm/cancel), the accepted-prose road (whose utterance is
        /// "yes please", not a way of asking for anything) and the window
        /// verbs' old hand-written gate never did.
        routingHabitGrant: RoutingHabitRecordingContext.Grant? = nil,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation,
        epoch: UInt64
    ) async -> SkillOutcome {
        let invocation = ModelSkillInvocation(
            id: "\(runIDPrefix)-\(UUID().uuidString)", name: name,
            argumentsJSON: argumentsJSON)
        let invocationReference = dispatcher.skillReference(for: name)
        continuation.yield(.skillInvocation(
            reference: invocationReference, argumentsJSON: argumentsJSON,
            runID: invocation.id))
        let startedAt = Date()
        let outcome: SkillOutcome = await RoutingHabitRecordingContext.withGrant(routingHabitGrant) {
            if allowTitleCommit {
                return await SpokenTitleCommitContext.$allowed.withValue(true) {
                    await dispatcher.dispatch(
                        name: name, argumentsJSON: argumentsJSON, runID: invocation.id)
                }
            }
            return await dispatcher.dispatch(
                name: name, argumentsJSON: argumentsJSON, runID: invocation.id)
        }
        continuation.yield(.skillResult(record: BehavioralActionRecord(
            outcome: outcome,
            intention: name,
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
                skillName: name
            ),
        ], epoch: epoch)
        return outcome
    }

    /// The tail the three EARLY-RETURNING dispatch paths share: speak when
    /// there is something to say, then close the turn. An empty `spoken` still
    /// completes — the act was the answer.
    func closeSkillTurn(
        spoken: String,
        exit: String,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation,
        epoch: UInt64
    ) {
        if !spoken.isEmpty {
            continuation.yield(.token(spoken))
            appendHistory(BrainTurn(role: .assistant, text: spoken), epoch: epoch)
        }
        continuation.yield(.completed(fullText: spoken))
        logTurnExit(exit)
        continuation.finish()
    }

    /// JSON for a flat string map, in the stable key order every dispatch path
    /// already used.
    static func argumentsJSON(_ arguments: [String: String]) -> String {
        (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
