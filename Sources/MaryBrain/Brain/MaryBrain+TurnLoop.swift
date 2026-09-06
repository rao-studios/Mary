//
//  MaryBrain+TurnLoop.swift
//  MaryBrain
//
//  WHAT: runTurn / runTurnBody — supersede, route, embedding dispatch, gates.
//  IN:   LanguageResponder.startTurn
//  OUT:  seerTurn or localTurn
//  PIN:  Both functions moved whole; never split a function.
//
import MaryPlugin
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

        // After the utterance is published so Ability Totem search can use
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
        // pay for; under Seer's it is the only way the tier works at all.
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
        let triage = TurnTriage.verdict(
            query: routingQuery,
            registry: turnRegistry,
            offeredNames: offeredNames)
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
            let applicationID = route.gate.applications.count == 1
                ? route.gate.applications.first : nil
            let filled = EmbeddingRouting.filledArguments(
                for: skill, utterance: userText, applicationID: applicationID,
                applicationProfiles: applicationProfiles)
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

        var seerReady = false
        if let seerChat { seerReady = await seerChat.isReady() }

        guard seerReady, let seerChat else {
            await localTurn(
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

        // Seer mode with a deterministic decision already executed: the
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

        await seerTurn(
            userText: userText,
            originUserTurnID: userTurn.id,
            systemPrompt: systemPrompt,
            route: route,
            target: located,
            acceptedOffer: acceptedOffer != nil,
            worldVetoArming: worldVetoArming,
            traceID: traceID,
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
