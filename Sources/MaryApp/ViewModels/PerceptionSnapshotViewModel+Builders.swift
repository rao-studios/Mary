//
//  PerceptionSnapshotViewModel+Builders.swift
//

import AppKit
import ApplicationServices
import MaryBrain
import MaryPlugin
import SwiftUI
import MaryRuntime

extension PerceptionSnapshotViewModel {

    // MARK: - Builders (pure)

    enum SectionRole { case full, ambient, absent }

    /// One card per observed place (not one compiled slot per app).
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
            // Store rows after the blindness gate (read survives quit). Tier 0 surface first.
            card.fields += surfaceFields(
                inputs.ambientSurface(for: observed.world), at: inputs.now)
            card.fields += heldFields(
                inputs.ambientFacts(for: observed.world), at: inputs.now)
            return card
        }
    }

    /// Same inputs as runtime `resolveFocus()`. Contribution results, never running checks.
    nonisolated static func leadPlace(_ inputs: Inputs) -> AmbientPlace? {
        let contributing = inputs.contributing
        // REGISTRY ORDER over whatever disciplines are actually contributing —
        // the pane mirrors runtime arbitration, so it asks the same question of
        // the same graph rather than naming two crafts.
        let ranked = AmbientCapabilityIndexProvider.current.disciplines
            .map(WorkspaceFocus.init)
        let liveDisciplines = contributing.compactMap { $0.world.place.focus }
        let ordered = ranked.filter(liveDisciplines.contains)
            + liveDisciplines.filter { !ranked.contains($0) }
        let discipline = WorkspaceFocusArbiter.lead(
            focus: inputs.effective,
            live: ordered,
            inPlay: inputs.writingInPlay
                ? nil : Set(ordered.filter { $0 != .writing }))
        guard let discipline else { return nil }
        // Named place outranks a signal. Pane has no utterance: writing place, then discipline contributor.
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

    /// Which lanes received this world. Same role as `routing`. Ambient = Ability-lane only.
    nonisolated static func delivery(role: SectionRole) -> String {
        delivery(role: role, held: false)
    }

    /// Store-held reads still reach both prompts even when the arbiter marks `.absent`.
    nonisolated static func delivery(role: SectionRole, held: Bool) -> String {
        delivery(
            // Full section → voice; ambient is Ability-only; held facts go both.
            toVoice: role == .full || held,
            // Everything the arbiter kept — full section or ambient
            // stand-in — renders in the system prompt.
            toAbilityRuntime: role != .absent || held)
    }

    /// Delivery labels; "voice only" means the lanes have diverged.
    nonisolated static func delivery(toVoice: Bool, toAbilityRuntime: Bool) -> String {
        switch (toVoice, toAbilityRuntime) {
        case (true, true): return "voice + abilities"
        case (false, true): return "abilities only"
        case (true, false): return "voice only"
        case (false, false): return "neither"
        }
    }

}
