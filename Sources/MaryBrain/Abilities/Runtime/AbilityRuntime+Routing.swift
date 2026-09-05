//
//  AbilityRuntime+Routing.swift
//  MaryBrain
//
//  WHAT: The turn's routing verdict, assembled once from the world.
//  IN:   AmbientWorld store (route, facts, handoff) + schema signals
//  OUT:  AbilityRoutingContext; the per-turn memo reset
//  PIN:  A selection the route REJECTED is not a signal. It stays on the
//        route for diagnostics and is filtered out of everything here.
//
import Foundation

extension AbilityRuntime {

    /// The immutable turn signal set after semantic route containment.
    func routedSignalSnapshot() -> SchemaSignalTurnSnapshot {
        let snapshot = SchemaSignalTurnContext.snapshot ?? .empty
        let route = world.store.route()
        guard let rejectedAttention = route?.world,
              rejectedAttention.sense == .selection,
              route?.selectionDefinesTurn != true
        else { return snapshot }
        let rejectedHandoffID = world.store.selectionHandoff(
            attention: rejectedAttention.attention)?.id
        // Code or prose — asked of the registration, not a name.
        let rejectedSchema: InteractionID =
            rejectedAttention.place.focus == .coding
            ? .codeSelection
            : .textSelection
        return SchemaSignalTurnSnapshot(
            interactions: snapshot.interactions.filter {
                if let rejectedHandoffID {
                    return $0.id != rejectedHandoffID
                }
                // Handoff identity missing: fail closed on this schema, keep the other family.
                return $0.reference.schemaID != rejectedSchema
            },
            perceptions: snapshot.perceptions)
    }

    /// Turn routing verdict. Internal (not private) so taught-app parity tests can read it.
    /// The zero-argument form reads this turn's snapshot and signals for you;
    /// an entry point that already holds them passes them in, so one turn's
    /// worth of work happens once rather than once per caller.
    func abilityRoutingContext() -> AbilityRoutingContext {
        abilityRoutingContext(
            snapshot: abilitySnapshot, signals: routedSignalSnapshot())
    }

    func abilityRoutingContext(
        snapshot: AbilityRuntime.Snapshot,
        signals: SchemaSignalTurnSnapshot
    ) -> AbilityRoutingContext {
        // ONE READ of the application roster: `current` takes a lock and hands
        // back a struct copy, and this used to ask for it three times.
        let applicationIndex = AmbientApplicationIndexProvider.current
        let route = world.store.route()
        let windowIntent = windowManagementTurnIntent(
            route: route, index: applicationIndex)
        let diagnosticAttention = route?.world
        // Keep the source packet on AmbientRoute for diagnostics and event ordering
        let excludesDiagnosticSelection = diagnosticAttention?.sense == .selection
            && route?.selectionDefinesTurn != true
        let attention = excludesDiagnosticSelection ? nil : diagnosticAttention
        let facts = world.store.facts()
        let handoff = attention.flatMap {
            world.store.routedSelectionHandoff(attention: $0.attention)
        }
        var interactions: Set<InteractionID> = []
        let signalSnapshot = signals
        let routingInteractions = signalSnapshot.interactions
        interactions.formUnion(routingInteractions.map { $0.reference.schemaID })
        var interactionEvidenceRanks: [InteractionID: Int] = [:]
        for interaction in routingInteractions {
            let id = interaction.reference.schemaID
            interactionEvidenceRanks[id] = max(
                interactionEvidenceRanks[id] ?? 0,
                interaction.evidenceRank)
        }
        // Selection becomes a routable Interaction only after the schema bridge validates it.
        var perceptions = signalSnapshot.perceptionIDs
        if let lead = route?.leadPlace {
            // Native lead earns focus perception for leading — same as before.
            if lead.placeClass == .workspace {
                perceptions.insert(.workspaceFocus)
                perceptions.insert(.projectFocus)
            }
            if lead.focus == .coding {
                perceptions.insert(.codeWorkspaceFocus)
            }
        }
        if attention?.applicationID != nil
            || route?.leadApplicationID != nil
            || !(route?.gate.applications.isEmpty ?? true) {
            perceptions.insert(.applicationFocus)
        }
        if handoff?.scope.windowID != nil { perceptions.insert(.windowFocus) }
        // No producer mints a hover world yet; the correspondence is declared
        // on AmbientSense.perception.
        if attention?.sense == .hover { perceptions.insert(.hover) }
        if facts.contains(where: { $0.slot == .viewport }) {
            perceptions.insert(.viewport)
        }

        // Source resolution is the most specific fact this turn can prove.
        func rank(_ value: SourceResolution) -> Int {
            switch value {
            case .unresolved: return 0
            case .device: return 1
            case .application: return 2
            case .window: return 3
            case .workspace: return 4
            case .document: return 5
            }
        }
        var sourceResolution = handoff?.scope.resolution
            ?? ((attention?.applicationID != nil || route?.leadApplicationID != nil)
                ? .application : .unresolved)
        func promote(_ candidate: SourceResolution) {
            if rank(candidate) > rank(sourceResolution) { sourceResolution = candidate }
        }
        for interaction in routingInteractions {
            promote(interaction.reference.scope.resolution)
        }
        for perception in signalSnapshot.perceptions {
            promote(perception.reference.scope.resolution)
        }
        if let lead = route?.leadPlace, lead.placeClass == .workspace {
            promote(.workspace)
            // `$0.place == lead`, NOT `$0.world == lead`.
            let leadFacts = facts.filter { $0.place == lead }
            if leadFacts.contains(where: {
                $0.slot == .file && $0.subject?.isEmpty == false
            }) {
                promote(.document)
            }
        } else if route?.leadApplicationID != nil
            || !(route?.gate.applications.isEmpty ?? true) {
            promote(.application)
        }
        // Workspace family is the lead place's ability — not an inline two-value switch.
        let workspaceFamily: String? = route?.leadPlace?.ability?.rawValue
        let capabilities = Set(
            snapshot.bindings
                .filter { $0.adapter.isAvailable }
                .flatMap { $0.adapter.capabilities })
        let grantedPermissions = Set(
            snapshot.adapterManifests
                .filter(\.isAvailable)
                .flatMap(\.grantedPermissions))
        var targets = Set(route?.namedPlaces.map(\.token) ?? [])
        targets.formUnion(windowIntent.targetClasses)
        if let lead = route?.leadPlace {
            targets.insert(lead.token)
            targets.insert(lead.placeClass.rawValue)
            // Lead's target classes come from its package.
            // PIN: Used to be a switch over compiled worlds.
            if let registration = applicationIndex.registration(place: lead) {
                targets.formUnion(registration.profile.targetClasses)
            }
        }
        if attention?.selectionEditability == .editable,
           attention?.place.focus != .coding {
            targets.insert("editable-prose-surface")
        }
        if let writingTarget = route?.writingTarget?.rawValue {
            targets.insert(writingTarget)
        }
        // Taught workspace classes come from its package.
        if let leadApplicationID = route?.leadApplicationID,
           let registration = applicationIndex.registration(id: leadApplicationID) {
            targets.formUnion(registration.profile.targetClasses)
        }
        // World class from the lead place. The block above stays keyed on `route.lead`.
        if let leadPlace = route?.leadPlace {
            targets.insert(leadPlace.placeClass.rawValue)
        }
        var namedApplications = Set(route?.gate.applications ?? [])
        if let id = route?.leadPlace?.application { namedApplications.insert(id) }
        if let leadApplicationID = route?.leadApplicationID {
            namedApplications.insert(leadApplicationID)
        }
        if let applicationID = attention?.applicationID {
            namedApplications.insert(applicationID)
        }
        let normalizedApplicationIDs = Set(namedApplications.map { $0.lowercased() })
        for profile in applicationProfiles where
            normalizedApplicationIDs.contains(profile.id.lowercased())
                || !Set(profile.applicationIdentifiers.map { $0.lowercased() })
                    .isDisjoint(with: normalizedApplicationIDs) {
            targets.formUnion(profile.targetClasses)
        }
        // One vectorization for the whole turn — scorer is called per Skill across passes.
        let query = world.store.routingQuery()
        // ONE READ, TWO MAPS. The gating map is what the floor admitted; the
        // scores are every Skill the index scored, for the trace alone.
        let scored = semanticSkillScores(for: query)
        return AbilityRoutingContext(
            utterance: query,
            intent: route?.intent.rawValue,
            namedApplications: namedApplications,
            targetClasses: targets,
            interactions: interactions,
            interactionEvidenceRanks: interactionEvidenceRanks,
            perceptions: perceptions,
            capabilities: capabilities,
            grantedPermissions: grantedPermissions,
            sourceResolution: sourceResolution,
            workspaceFamily: workspaceFamily,
            semanticSkillAffinity: scored.filter {
                $0.value >= SemanticSkillRequestIndex.defaultThreshold
            },
            semanticSkillScores: scored,
            usesEmbeddingRoster: snapshot.semanticSkillIndex != nil,
            // COMPUTED ONLY WHEN IT WILL BE READ. With a Skill index in hand
            // the roster is affinity-gated and this is never consulted, so a
            // second lexical scan of every Ability's triggers would be pure
            // waste on the path that matters.
            requestedAbilities: snapshot.semanticSkillIndex == nil
                ? snapshot.requestedAbilities(in: query) : [])
    }

    /// See `semanticSkillAffinityCache`. One vectorization and one library scan per turn.
    ///
    /// SCORED WITH NO FLOOR, then filtered by the caller. The gate and the trace
    /// want the same numbers cut in two different places, and asking the index
    /// twice would vectorize the utterance twice for one turn.
    private func semanticSkillScores(for utterance: String) -> [SkillID: Float] {
        if let cached = semanticSkillAffinityCache.withLock({ $0 }),
           cached.utterance == utterance {
            return cached.affinities
        }
        // THE INJECTED STORE, not `.shared` — `setRoutingHabitStoreForTesting`
        // only isolates a test if every read honours it.
        let computed = abilitySnapshot.semanticSkillIndex?
            .affinities(
                in: utterance,
                habits: routingHabitStore.withLock { $0 },
                floor: 0) ?? [:]
        semanticSkillAffinityCache.withLock { $0 = (utterance, computed) }
        return computed
    }

    /// The window-classifier's view of the turn.
    private func windowManagementTurnIntent(
        route: AmbientRoute?,
        index: any AmbientApplicationIndex
    ) -> WindowManagementTurnIntent {
        let referent = world.store.referent()

        // Document-holding place that leads: referent, then lead, then named.
        let candidates: [AmbientPlace] = [
            referent?.place, route?.leadPlace,
        ].compactMap { $0 } + Array(route?.namedPlaces ?? [])

        let place = candidates.first { candidate in
            index.registration(place: candidate)?.observesDocuments == true
        }
        let documentPlace = place.flatMap { candidate -> WindowManagementDocumentPlace? in
            guard let id = candidate.application else { return nil }
            return WindowManagementDocumentPlace(
                applicationID: id,
                documentNoun: index.registration(place: candidate)?
                    .documentNoun ?? "document",
                isReferent: referent?.place == candidate)
        }
        return WindowManagementTurnClassifier.classify(
            utterance: world.store.utterance(),
            documentPlace: documentPlace)
    }

    public func beginTurn() {
        pendingStore.beginTurn()
        // Matcher memo is this turn's leading world. See `resolutions`.
        resolutions.withLock { $0.removeAll() }
        // Provider choices are this turn's named/interaction/focused signals.
        providerSelection.withLock { $0 = nil }
        // Embedding memo is this turn's utterance. See `semanticSkillAffinityCache`.
        semanticSkillAffinityCache.withLock { $0 = nil }
        MaryEmbeddings.endTurn()
        // Surface referent for this turn — same lifetime as the other memos.
        surfaceReferent.withLock { $0 = .currentLiveSelection }
        // WHERE THIS TURN'S SEARCHES ALREADY LANDED. Same lifetime, same reason: a page
        // is not still the page it was, and a search repeated within one turn cannot
        // prove itself because nothing about the browser changes the second time.
        BrowserTurnMemo.shared.beginTurn()
        // Demoted, not dropped — see `TurnOfferLedger`. Detached routines dispatch across this boundary.
        offerLedger.withLock {
            $0.previous = $0.current
            $0.current = []
            $0.projected = !$0.previous.isEmpty
        }
        codingRosterLogged.withLock { $0 = false }
    }

    func executionContext() -> AbilityExecutionContext {
        var context = contextProvider()
        context.surfaceReferent = surfaceReferent.withLock { $0 }
        // Utterance provenance for adapters. Set here — the injected provider is built once.
        context.utterance = world.store.utterance()
        return context
    }
}
