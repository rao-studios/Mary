//
//  PerceptionSnapshotViewModel+Builders.swift
//

import AppKit
import ApplicationServices
import MaryBrain
import MaryAdapters
import SwiftUI
import MaryRuntime

extension PerceptionSnapshotViewModel {

    // MARK: - Builders (pure)

    enum SectionRole { case full, ambient, absent }

    /// ONE CARD PER OBSERVED PLACE.
    ///
    /// Its predecessor built five by hand — one function per compiled
    /// application, 457 lines — and then appended the taught ones. A card
    /// existed whether or not anything filled it, and a second manuscript
    /// application replaced the first rather than getting a card of its own.
    /// Here a card exists exactly when a place is observed, which is the
    /// honest reading and needs no list.
    nonisolated static func buildCards(_ inputs: Inputs) -> [PerceptionCard] {
        let lead = leadPlace(inputs)
        return inputs.observed.map { observed in
            let role = role(for: observed, lead: lead)
            var card = PerceptionCard(
                world: observed.world,
                isRunning: observed.isRunning,
                blindness: observed.blindness,
                capturedAt: observed.capturedAt,
                fields: [],
                contribution: observed.contribution,
                extraContributions: observed.extraContributions,
                pollDescription: observed.pollDescription,
                lastSuccessAt: observed.lastSuccessAt,
                lastError: observed.lastError,
                isPinned: inputs.pinned?.applicationID == observed.world.place.application,
                routing: routing(role: role),
                delivery: delivery(
                    role: role,
                    held: !inputs.ambientFacts(for: observed.world).isEmpty))
            // THE STORE'S ROWS, APPENDED AFTER the blindness gate on purpose:
            // a read survives the application quitting. "Mary can't see it any
            // more" and "Mary is still holding the passage you asked for" are
            // both true at once, and hiding the second behind the first is how
            // the pane would go back to lying about continuity.
            //
            // TIER 0 FIRST, exactly as the prompt orders it: the surface is
            // the ground, the held details stand on it.
            card.fields += surfaceFields(
                inputs.ambientSurface(for: observed.world), at: inputs.now)
            card.fields += heldFields(
                inputs.ambientFacts(for: observed.world), at: inputs.now)
            return card
        }
    }

    /// THE ROUTING MIRROR — deliberately the same inputs the runtime's own
    /// `resolveFocus()` reads, so the pane cannot say a place leads while the
    /// turn led somewhere else. Contribution RESULTS, never running checks.
    nonisolated static func leadPlace(_ inputs: Inputs) -> AmbientPlace? {
        let contributing = inputs.contributing
        let discipline = WorkspaceFocusArbiter.lead(
            focus: inputs.effective,
            hasCoding: contributing.contains { $0.world.place.focus == .coding },
            hasWriting: contributing.contains { $0.world.place.focus == .writing },
            writingInPlay: inputs.writingInPlay)
        guard let discipline else { return nil }
        // A named place outranks a signal; the pane has no utterance, so the
        // strongest thing it can mirror is the writing place the tracker
        // settled on, then the first contributor of the right discipline.
        if discipline == .writing, let writing = inputs.writingPlace,
           contributing.contains(where: { $0.world.place == writing }) {
            return writing
        }
        return contributing.first { $0.world.place.focus == discipline }?.world.place
    }

    nonisolated static func role(
        for observed: Inputs.Observed, lead: AmbientPlace?
    ) -> SectionRole {
        if observed.world.place == lead { return .full }
        return observed.contribution == nil ? .absent : .ambient
    }

    /// The surface row, rendered with `AmbientSurface.surfaceLine` — the SAME
    /// function the prompt's tier-0 line comes from, so the pane and the
    /// prompt render one surface rather than two that agree today.
    nonisolated static func surfaceFields(
        _ surface: AmbientSurface?, at now: Date
    ) -> [PerceptionCard.Field] {
        guard let surface else { return [] }
        return [.init(label: "surface", value: surface.surfaceLine(at: now))]
    }

    /// One row per held fact, rendered with `AmbientFact.mentionLine` — the
    /// same shared call, for the same reason.
    nonisolated static func heldFields(
        _ facts: [AmbientFact], at now: Date
    ) -> [PerceptionCard.Field] {
        facts.map { .init(label: $0.slot.token, value: $0.mentionLine(at: now)) }
    }

    /// The pane's focus block.
    nonisolated static func buildFocus(_ inputs: Inputs) -> FocusSummary {
        FocusSummary(
            ambient: inputs.ambient,
            effective: inputs.effective,
            writingPlace: inputs.writingPlace,
            pinned: inputs.pinned,
            overrideActive: inputs.overrideActive,
            writingInPlay: inputs.writingInPlay,
            readDelivery: inputs.readDelivery,
            heldReads: inputs.facts.filter { $0.slot.isRead },
            rankingMode: inputs.rankingMode)
    }

    nonisolated static func routing(role: SectionRole) -> String {
        switch role {
        case .full: return "leads — full context"
        case .ambient: return "ambient line only"
        case .absent: return "absent this turn"
        }
    }

    /// WHICH LANES received this world this turn — the row that would have
    /// made the sync bug self-evident. Mary speaks on two lanes: the SEER
    /// voice (Lane A, `seerInstructionsProvider` → `seerInstructions`) and
    /// the orchestrator that runs Ability Skills (Lane B, `systemPromptProvider`
    /// → `system`). Until Slice 1, `seerInstructions` was handed
    /// `codingContext` ONLY, so a Pages turn's full section reached Lane B
    /// and stopped — the voice answered about the document from owner-wide
    /// retrieval, and read "abilities only" here. It reads "voice + abilities" now.
    ///
    /// Derived from the SAME role as `routing`, deliberately: an ambient line
    /// is a routing stand-in that only the system prompt renders, so it is
    /// Ability-lane-only by construction, and an absent world reaches nobody.
    nonisolated static func delivery(role: SectionRole) -> String {
        delivery(role: role, held: false)
    }

    /// …AND WHAT THE STORE ADDS. `role` alone answered "what did the ARBITER
    /// do with this world's live contribution this turn" — which was the whole
    /// truth while the live section was the only channel. It no longer is: a
    /// world the arbiter marked `.absent` (Pages quit, its watcher dark) still
    /// reaches BOTH prompts when the store holds a read of it, because both
    /// providers render the held facts. A card that said "neither" over a
    /// passage the model is holding would be the same class of quiet lie the
    /// `delivery` row was added to kill.
    nonisolated static func delivery(role: SectionRole, held: Bool) -> String {
        delivery(
            // Only the FULL section rides `liveWork` into the voice's
            // instructions; ambient lines are routing advice for the Ability
            // lane, never something to talk about. A HELD fact rides the
            // held-facts block into both.
            toVoice: role == .full || held,
            // Everything the arbiter kept — full section or ambient
            // stand-in — renders in the system prompt.
            toAbilityRuntime: role != .absent || held)
    }

    /// The four-value vocabulary. "voice only" is unreachable by
    /// construction today (every section the voice gets comes from the same
    /// `resolveFocus()` sections the system prompt renders), and it stays in
    /// the mapping precisely for that reason: a card showing it means the
    /// lanes have diverged, which is the exact bug class this row exists to
    /// catch.
    nonisolated static func delivery(toVoice: Bool, toAbilityRuntime: Bool) -> String {
        switch (toVoice, toAbilityRuntime) {
        case (true, true): return "voice + abilities"
        case (false, true): return "abilities only"
        case (true, false): return "voice only"
        case (false, false): return "neither"
        }
    }

}
