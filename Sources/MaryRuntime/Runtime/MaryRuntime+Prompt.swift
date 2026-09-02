//
//  MaryRuntime+Prompt.swift
//  MaryRuntime
//
//  WHAT: Prompt-assembly bodies hoisted from installBrainConfiguration.
//  OUT:  heldContext, systemPromptText, seerInstructionsText
//  PIN:  Prompt, roster, archive, retrieval all derive from the same
//        resolveFocus. Spend waterfall → RetrievalTraceLedger.
//

import MaryBrain
import MaryPlugin
import MaryTotem
import MaryVoice
import Foundation
import os

extension MaryRuntime {

        /// Render, don't recompute. Rank under the budget; losers become a
        /// one-line mention with bounds — never a silent omission.
    static func heldContext(
            _ resolved: (
                sections: WorkspaceFocusArbiter.PromptSections,
                leadOwner: String?,
                subject: DepositSubject,
                leadPlace: AmbientPlace?),
            budget: Int,
            suppressing: [String] = [],
            /// Fact keys the CO-ACTIVE section already rendered this prompt —
            /// seeded into `alreadyRendered` so a merged-worlds mention and a
            /// held-facts block never say the same fact twice.
            alsoRendered: Set<AmbientKey> = []
        ) -> AmbientRendering {
            let store = AmbientContextStore.shared
            let routed = routedHeldAmbient(
                facts: store.facts(),
                world: store.world(),
                route: store.route())
            let attention = routed.world
            var alreadyRendered: Set<AmbientKey> = alsoRendered
            // Skip facts the live block already said (one comparison: lead place).
            if let lead = resolved.leadPlace {
                alreadyRendered.formUnion(
                    routed.facts
                        .filter { $0.place == lead }
                        .filter { fact in
                            fact.slot.isPerceived && !(attention?.matches(fact) ?? false)
                        }
                        .map(\.key))
            }
            // Tier 0: lead lane's surface first (works for dynamic apps).
            // Surfaces bypass routedHeldAmbient admission — they ARE "this"/"on screen".
            let surfaces = leadFirstSurfaces(store.surfaces(), lead: resolved.leadPlace)
            return AmbientRanker.render(
                facts: routed.facts,
                utterance: store.utterance(),
                focusedPlace: resolved.leadPlace,
                world: attention,
                alreadyRendered: alreadyRendered,
                suppressingContentIn: suppressing,
                surfaces: surfaces,
                budget: budget)
        }

    /// Surfaces in reading order, lead place first. Shared by renderer and capture.
    private static func leadFirstSurfaces(
        _ surfaces: [AmbientSurface], lead: AmbientPlace?
    ) -> [AmbientSurface] {
        var surfaces = surfaces
        if let lead, let index = surfaces.firstIndex(where: { $0.place == lead }) {
            surfaces.insert(surfaces.remove(at: index), at: 0)
        }
        return surfaces
    }

    /// Tails both prompts append: ambient guidance, then ability projection.
    /// One route value so both tails describe the same route.
    private static func promptWithTails(
        render: PromptRender,
        lane: PromptLane,
        held: AmbientRendering,
        budget: Int,
        route: AmbientRoute?
    ) -> (text: String, spend: PromptSpendTrace, ambient: AmbientInjectionTrace) {
        let guidance = MaryPrompts.ambientGuidance(for: route)
        let projection = AbilityPromptProjection.render(
            snapshot: AbilityLibrary.shared.snapshot(),
            route: route)
        let text = render.text + guidance + projection
        return (
            text: text,
            spend: PromptSpendTrace(
                lane: lane,
                spend: render.spend,
                appendedChars: guidance.count + projection.count,
                totalChars: text.count),
            ambient: AmbientInjectionTrace(
                lane: lane, rendering: held, budget: budget))
    }

    /// The setSystemPromptProvider body — the Skill lane's per-turn prompt.
    static func systemPromptText(
        plugins: [any MaryAdapter],
        projects: [String: String],
        deps: FocusResolutionContext
    ) -> String {
            // The provider is synchronous; support plugins read lock-guarded
            // boxes, so the live focus reaches the prompt every turn.
            let resolved = resolveFocus(deps: deps)
            let sections = resolved.sections
            // Merged worlds: compact mentions beside the lead. Keys seed heldContext dedup.
            let signal = WorkspaceFocusTracker.shared.signal()
            let coActive = AmbientRanker.coActiveLines(
                places: signal.coActive
                    .filter { $0 != resolved.leadPlace }
                    .map { ($0, signal.glanced.contains($0)) },
                facts: AmbientContextStore.shared.facts())
            // Orchestrator gets the smaller budget — it acts, does not recite.
            let held = heldContext(
                resolved, budget: AmbientRanker.abilityBudget,
                alsoRendered: coActive.keys)
            // Rival writing fragments stand down. Suppressed = other writers minus
            // admittedPlaceMentions. Naming a sibling restores its fragment this turn.
            let standingDownFragmentOwners: Set<String> = {
                guard let lead = resolved.leadPlace, lead.focus == .writing
                else { return [] }
                let store = AmbientContextStore.shared
                var admitted = AmbientRanker.admittedPlaceMentions(
                    route: store.route(),
                    referent: store.referent(),
                    utterance: store.utterance())
                admitted.insert(lead)
                return Set(
                    AmbientApplicationIndexProvider.current.all
                        .filter {
                            $0.place.focus == .writing && !admitted.contains($0.place)
                        }
                        .map(\.id))
            }()
            // systemRender is .system's body; render form keeps the spend waterfall.
            let render = MaryPrompts.systemRender(
                plugins: plugins, projects: projects,
                leadContext: sections.leadContext,
                ambientNotes: sections.ambientNotes,
                // Tier 0 leads: accessibility surface first. Prepended so MaryPrompts stays untouched.
                heldFacts: held.surfaceLines + held.blocks,
                heldMentions: held.mentions,
                leadPlace: sections.leadPlace,
                coActiveContext: coActive.lines,
                standingDownFragmentOwners: standingDownFragmentOwners)
            let assembled = promptWithTails(
                render: render, lane: .system, held: held,
                budget: AmbientRanker.abilityBudget,
                route: AmbientContextStore.shared.route())
            let text = assembled.text
            // Staged, not booked — turn loop claims the stage after this returns.
            RetrievalTraceLedger.shared.stageSystemPrompt(
                spend: assembled.spend,
                ambient: assembled.ambient)
            // Input half of the episode. Turn loop claims it — see BehavioralAssembler.
            let now = Date()
            brainWiring.behavior.stageCapture(
                AmbientCaptureBuilder.capture(
                    facts: AmbientContextStore.shared.facts(at: now),
                    surfaces: leadFirstSurfaces(
                        AmbientContextStore.shared.surfaces(at: now), lead: resolved.leadPlace),
                    rendering: held,
                    selection: AmbientContextStore.shared.routedSelectionHandoff(at: now),
                    lead: resolved.leadPlace,
                    realm: AmbientContextStore.shared.route()?.realm,
                    at: now))
            return text
    }

    /// The setSeerInstructionsProvider body — the voice lane's per-turn
    /// instructions.
    static func seerInstructionsText(
        pass: SeerPass,
        deps: FocusResolutionContext
    ) -> String {
            let resolved = resolveFocus(assertedFocus: pass.assertedFocus, deps: deps)
            let sections = resolved.sections
            // One capability line from MaryPrompts.capabilityLine, asked of the lead place.
            let capability: String? = sections.leadPlace.flatMap { place in
                place.application.map {
                    MaryPrompts.capabilityLine(
                        for: PinnedWorld(
                            applicationID: $0, focus: place.focus ?? .writing))
                }
            }
            if let place = sections.leadPlace, let app = place.application {
                let kind = place.focus == .coding ? "pair-coding" : "co-writing"
                let line = "persona — \(kind) in \(app)"
                MaryBrain.turnLog.info("\(line, privacy: .public)")
            } else {
                MaryBrain.turnLog.info("persona — none (no lead place with an application)")
            }
            // Live work itself — arbiter grants exactly one place a full section.
            let liveWork = sections.leadContext
            // readPassages rides separately (end of live block). suppressing: this
            // turn's fetch-first passage — one text, one claim.
            let held = heldContext(
                resolved, budget: AmbientRanker.voiceBudget,
                suppressing: pass.readPassages + pass.awareness)
            // `seerRender` is `.seerInstructions`'s own body (the wrapper
            // returns `seerRender(...).text`), so the returned text is
            // byte-identical; the render form keeps the spend waterfall.
            let render = MaryPrompts.seerRender(
                capability: capability,
                groundedResults: pass.groundedResults,
                liveWork: liveWork,
                // Stated by the arbiter, not re-derived here.
                liveWorkWorld: LiveWorkWorld.claim(
                    arbiter: sections.liveWorld,
                    machine: AmbientContextStore.shared.world()),
                // TIER 0 LEADS — see the Skill lane's note above; both lanes
                // present the surface before the details it supports.
                heldFacts: held.surfaceLines + held.blocks,
                heldMentions: held.mentions,
                readPassages: pass.readPassages,
                readReport: pass.readReport,
                conversational: pass.conversational,
                runningActions: pass.runningActionLabels,
                lookUnderway: pass.lookUnderway,
                inspiredSight: pass.inspiredSight,
                perceiving: pass.perceiving,
                awareness: pass.awareness)
            let assembled = promptWithTails(
                render: render, lane: .seerInstructions, held: held,
                budget: AmbientRanker.voiceBudget,
                route: AmbientContextStore.shared.route())
            // Booked directly — unlike the system provider, the pass names
            // its exchange. A nil exchange (ambient remark, detached routine
            // follow-up) books nothing, by `SeerPass.exchangeID`'s contract.
            if let exchange = pass.exchangeID {
                RetrievalTraceLedger.shared.notePromptSpend(
                    assembled.spend, forExchange: exchange)
                RetrievalTraceLedger.shared.noteAmbientInjection(
                    assembled.ambient, forExchange: exchange)
            }
            return assembled.text
    }
}
