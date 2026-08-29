//
//  MaryRuntime+Prompt.swift
//  Mary
//
//  Moved from MaryRuntime.swift's installBrainConfiguration (phase 3): the
//  prompt-assembly bodies that ran inside `brain.set*` closures, hoisted to
//  named statics so the install function reads as wiring:
//
//    heldContext(_:budget:suppressing:)        HOISTED nested closure. It
//                                              captured nothing, so the
//                                              signature is the closure's
//                                              own, verbatim.
//    systemPromptText(plugins:projects:deps:)  the setSystemPromptProvider body
//    seerInstructionsText(pass:deps:)          the setSeerInstructionsProvider body
//
//  Bodies are byte-verbatim (original indentation kept so the move stays
//  verbatim); the only edits are the two `resolveFocus(...)` calls, which
//  now pass `deps:` — the capture boundary — and the swap of the `.text`
//  wrappers for `systemRender`/`seerRender`, whose returned text is
//  byte-identical (the wrappers ARE those renders' `.text`) and whose spend
//  waterfall now reaches `RetrievalTraceLedger` instead of being thrown
//  away. The invariant that survives: prompt, roster, archive and retrieval
//  all derive from the SAME resolveFocus decision; nothing here recomputes
//  it.
//

import MaryBrain
import MaryPlugin
import MaryTotem
import MaryVoice
import Foundation
import os

extension MaryRuntime {

        /// RENDER, DON'T RECOMPUTE. Ask the store for the current facts, rank
        /// them under the user's three-way budget rule, render. Everything
        /// that loses the budget degrades to a one-line mention WITH ITS
        /// BOUNDS — never a silent omission, because silence is what taught
        /// Mary to say a passage wasn't in the document.
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
                attention: store.attention(),
                route: store.route())
            let attention = routed.attention
            var alreadyRendered: Set<AmbientKey> = alsoRendered
            // WHAT THE LIVE BLOCK ALREADY SAID.
            //
            // The lead place's facts are in front of the model as live work;
            // repeating them under "Still in hand" says the same thing twice
            // with a DIFFERENT freshness claim, which is the two-contradicting
            // -authorities hazard in miniature.
            //
            // ONE COMPARISON NOW. This was two branches — a compiled world
            // matched on `fact.world`, a taught application on `fact.place` —
            // and the second existed because the first answered nil for every
            // taught application, so the dedup set came out empty and the same
            // facts rendered twice. The lane IS the lead place; there was only
            // ever one question.
            if let lead = resolved.leadPlace {
                alreadyRendered.formUnion(
                    routed.facts
                        .filter { $0.place == lead }
                        .filter { fact in
                            fact.slot.isPerceived && !(attention?.matches(fact) ?? false)
                        }
                        .map(\.key))
            }
            // TIER 0, ORDERED HERE. The lead lane's surface leads, because
            // this is the side holding `leadPlace` — it works for a dynamic
            // application lead as well as a native world, which the ranker's
            // native-only `focusedWorld` signal cannot express.
            //
            // Surfaces deliberately bypass `routedHeldAmbient`'s fact
            // admission: the surface IS what "this" and "on screen" point
            // at, so gating it behind the route's fact filter would withhold
            // the foundation exactly when deixis needs it. The budget still
            // bounds it, and the ranker drops what does not fit.
            let surfaces = leadFirstSurfaces(store.surfaces(), lead: resolved.leadPlace)
            return AmbientRanker.render(
                facts: routed.facts,
                utterance: store.utterance(),
                focusedPlace: resolved.leadPlace,
                attention: attention,
                alreadyRendered: alreadyRendered,
                suppressingContentIn: suppressing,
                surfaces: surfaces,
                budget: budget)
        }

    /// Surfaces in reading order, except the lead place moves to the front.
    ///
    /// The lead lane's surface leads because it works for a dynamic
    /// application lead as well as a native world, which the ranker's
    /// native-only `focusedWorld` signal cannot express. Shared by the
    /// renderer and the behavioral capture so both describe the same order.
    private static func leadFirstSurfaces(
        _ surfaces: [AmbientSurface], lead: AmbientPlace?
    ) -> [AmbientSurface] {
        var surfaces = surfaces
        if let lead, let index = surfaces.firstIndex(where: { $0.place == lead }) {
            surfaces.insert(surfaces.remove(at: index), at: 0)
        }
        return surfaces
    }

    /// The tails both per-turn prompts append to their plan render: ambient
    /// guidance, then the ability projection — same texts, same order for
    /// both lanes. Takes ONE route value because guidance and projection
    /// each used to read the store themselves, leaving a window where the
    /// two tails of a single prompt described different routes.
    /// `appendedChars` counts the tails separately so the spend waterfall
    /// stays honest about what it does not itemize.
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
            // THE MERGED WORLDS: places with fresh evidence beside the lead
            // (the responder-layer signal) render compact mention-grade
            // lines. Their keys seed heldContext's dedup so a fact never
            // renders twice in one prompt. Single-place turns produce
            // nothing here — the byte-parity rule.
            let signal = WorkspaceFocusTracker.shared.signal()
            let coActive = AmbientRanker.coActiveLines(
                places: signal.coActive
                    .filter { $0 != resolved.leadPlace }
                    .map { ($0, signal.glanced.contains($0)) },
                facts: AmbientContextStore.shared.facts())
            // The orchestrator lane gets the SMALLER budget: it acts, it does
            // not recite, and its prompt already carries every plugin's
            // fragment. It still gets the facts — a lane that knows the
            // passage is already in hand does not go and read it again.
            let held = heldContext(
                resolved, budget: AmbientRanker.abilityBudget,
                alsoRendered: coActive.keys)
            // RIVAL WRITING FRAGMENTS STAND DOWN on a writing-led turn.
            //
            // A fragment describes tools; describing a rival editor's tools
            // while the schema list carries this one's is how the model gets
            // steered into an application the user is not in. Suppressed =
            // every OTHER place that writes, minus the ones this turn
            // admitted — read from `admittedPlaceMentions`, the same ladder
            // the roster scope applies, rather than a hand-copied twin of it.
            //
            // Naming a sibling place, or resolving a referent in one,
            // restores its fragment on exactly that turn.
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
            // `systemRender` is `.system`'s own body — `.system` is a thin
            // wrapper returning `systemRender(...).text` — so the text below
            // is byte-identical to the wrapper call it replaces; the render
            // form just keeps the spend waterfall the wrapper threw away.
            let render = MaryPrompts.systemRender(
                plugins: plugins, projects: projects,
                leadContext: sections.leadContext,
                ambientNotes: sections.ambientNotes,
                // TIER 0 LEADS: the accessibility surface is the ground the
                // held details stand on, so it is the first thing this
                // section says. Prepended rather than assembled separately
                // so `MaryPrompts` stays untouched — the assembly, and
                // therefore its golden digests, is unchanged.
                heldFacts: held.surfaceLines + held.blocks,
                heldMentions: held.mentions,
                leadPlace: sections.leadPlace,
                coActiveContext: coActive.lines,
                standingDownFragmentOwners: standingDownFragmentOwners)
            let assembled = promptWithTails(
                render: render, lane: .system, held: held,
                budget: AmbientRanker.abilityBudget,
                route: AmbientContextStore.shared.route())
            let abilityMemory = abilityMemoryBriefBox.withLock { $0 }
            let text = abilityMemory.isEmpty
                ? assembled.text
                : assembled.text + abilityMemory
            // STAGED, NOT BOOKED: this provider is zero-arg by design and
            // cannot name its exchange; the turn loop claims the stage onto
            // the row it opens a few statements after this returns, on the
            // same actor.
            RetrievalTraceLedger.shared.stageSystemPrompt(
                spend: assembled.spend,
                ambient: assembled.ambient)
            // THE INPUT HALF OF THE EPISODE, staged from the same inputs the
            // render above used. The turn loop claims this a few statements
            // after this provider returns — see `BehavioralAssembler`.
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
            // The three capability lines come from ONE function now
            // (MaryPrompts.capabilityLine), because hand-written here they
            // drifted apart and the drift was the bug: Scrivener's said
            // "write and revise the manuscript directly", Xcode's said "edit
            // the code directly", and Pages' said "your hands type at their
            // cursor" — a voice told its only power is typing where the caret
            // sits, on the very turn the user asked for a section to be
            // replaced. All three name the same two acts in the same order.
            // ONE CAPABILITY LINE, from one function.
            //
            // Three were once hand-written here and drifted apart, and the
            // drift WAS the bug: one said "write and revise the manuscript
            // directly", one said "edit the code directly", and one said
            // "your hands type at their cursor" — a voice told its only power
            // is typing where the caret sits, on the very turn the user asked
            // for a section to be replaced.
            //
            // ASKED OF THE LEAD PLACE, so a taught application gets its own
            // name in the sentence rather than borrowing another's.
            let capability: String? = sections.leadPlace.flatMap { place in
                place.application.map {
                    MaryPrompts.capabilityLine(
                        for: PinnedWorld(
                            applicationID: $0, focus: place.focus ?? .writing))
                }
            }
            // THE LIVE WORK ITSELF, not just the boolean above.
            //
            // Only the coding half was ever passed, and every writing branch
            // of the arbiter hard-set it empty — so a writing turn's speaking
            // lane got the persona, the date, one sentence, and every factual
            // claim about the document came from owner-wide retrieval. That
            // is how Mary described a paragraph the user had already deleted
            // while the debugger showed her reading the live one.
            //
            // ONE SECTION NOW, so there is nothing to concatenate and nothing
            // to forget: the arbiter grants exactly one place a full section.
            let liveWork = sections.leadContext
            // `readPassages` rides SEPARATELY from `liveWork`, not appended to
            // it: MaryPrompts renders it at the very END of the live block,
            // under a sentence that names it the authority for the question.
            // Concatenating here would put a freshly-read passage and a stale
            // ambient excerpt side by side with nothing ranking them — and the
            // ambient one is the excerpt the user had already scrolled away
            // from when she denied the passage existed.
            // THE AMBIENT CONTEXT STORE, read by the voice. `suppressing:`
            // is this turn's own fetch-first passage: the dispatcher already
            // registered it as a fact on the way through, and rendering the
            // same text twice — once as a held fact carrying an age, once
            // under "I read this just now, it IS the authority" — is exactly
            // the two-contradicting-authorities hazard the block's ordering
            // exists to close. One text, one claim.
            let held = heldContext(
                resolved, budget: AmbientRanker.voiceBudget,
                suppressing: pass.readPassages)
            // `seerRender` is `.seerInstructions`'s own body (the wrapper
            // returns `seerRender(...).text`), so the returned text is
            // byte-identical; the render form keeps the spend waterfall.
            let render = MaryPrompts.seerRender(
                capability: capability,
                groundedResults: pass.groundedResults,
                liveWork: liveWork,
                // STATED BY THE ARBITER, not re-derived here. This used to be
                // `codingContext.isEmpty ? .writing(sections.writingApp) :
                // .coding` — a two-valued test for a four-valued question,
                // reading a field four of the arbiter's five return paths never
                // assigned. On a browser-led turn both native sections are
                // empty, so the test said "writing" and the unassigned field
                // said "Scrivener": the live "I'm looking at the live text in
                // front of you in Scrivener right now", answering a question
                // about Chrome. The capability ladder above already had this
                // right — explicit checks, honest nil — and this line now
                // agrees with it by construction.
                liveWorkWorld: sections.liveWorld,
                // TIER 0 LEADS — see the Skill lane's note above; both lanes
                // present the surface before the details it supports.
                heldFacts: held.surfaceLines + held.blocks,
                heldMentions: held.mentions,
                readPassages: pass.readPassages,
                readReport: pass.readReport,
                conversational: pass.conversational,
                runningActions: pass.runningActionLabels,
                lookUnderway: pass.lookUnderway)
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
