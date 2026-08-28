//
//  AbilityBadgeRow.swift
//  Mary
//
//  The chip row under a reply — the realm capsules and one Ability | Skill
//  badge per Skill the turn used. Lifted whole out of UtteranceView for two
//  reasons.
//
//  FIRST, THE CHIPS NOW CARRY STATE. The receipt under a chip has always
//  known whether its call was still running, had failed, or had been refused
//  — `TranscriptOps` writes the `.unsettled` row the moment the invocation is
//  announced and replaces it when it settles — and the chip rendered none of
//  it. A person watching an action they asked for had no way to tell "still
//  going" from "quietly failed" except by tapping through to the sheet.
//
//  SECOND, AND WORSE: the chips did not exist while the turn ran.
//  ConversationPageView swaps the whole row out for StreamingUtteranceView
//  until the turn goes idle, so the badges appeared only once everything they
//  described was already over. Living in their own view, they can be rendered
//  under the streaming reply as well — which is the one moment their state is
//  worth anything.
//

import MaryAmbient
import MaryBrain
import MaryFoundation
import SwiftUI
import MaryRuntime

struct AbilityBadgeRow: View {
    let badges: [AbilitySkillReference]
    /// One row per CALL, unlike `badges`, which dedupes to one per Skill.
    let actions: [BehavioralActionRecord]
    var realmLensEntry: RealmLensEntry? = nil
    var onOpenRoutes: (() -> Void)? = nil
    var onInspect: ((AbilitySkillReference, [BehavioralActionRecord]) -> Void)? = nil

    var body: some View {
        FlowLayout(spacing: .layer2) {
            if let place = realmLensEntry?.leadPlace {
                realmCapsule(place)
            }
            // THE MERGED-WORLDS CHIP: the places co-active beside the lead at
            // exchange time — "with: Sketch, Safari (glanced)". At most two,
            // matching the compact section's own restraint.
            if let entry = realmLensEntry, !entry.coActivePlaces.isEmpty {
                coActiveCapsule(entry)
            }
            ForEach(Array(badges.enumerated()), id: \.offset) { _, reference in
                let presentation = AbilityBadgePresentation(reference: reference)
                let runs = actions.filter { $0.action.skill == reference }
                Button {
                    onInspect?(reference, runs)
                } label: {
                    badgeLabel(
                        reference: reference,
                        presentation: presentation,
                        runs: runs)
                }
                .buttonStyle(.plain)
                .disabled(onInspect == nil)
                .help(helpText(runs))
            }
        }
    }

    private func helpText(_ runs: [BehavioralActionRecord]) -> String {
        guard let state = AbilityRunPresentation.stateWord(runs) else {
            return "Show this Skill's calls — arguments, receipts, status"
        }
        return "\(state) — tap for arguments, receipts, status"
    }

    /// The Ability | Skill badge's own label — split out from the row so the
    /// type checker isn't asked to solve one Button+HStack expression per
    /// ForEach iteration in a single pass (SE cannot resolve that in
    /// reasonable time once enough sibling overloads are in scope).
    @ViewBuilder
    private func badgeLabel(
        reference: AbilitySkillReference,
        presentation: AbilityBadgePresentation,
        runs: [BehavioralActionRecord]
    ) -> some View {
        let tint = Color.maryAbilityTint(reference.abilityTint)
        let state = AbilityRunPresentation.chipState(runs)
        // A chip that needs attention borrows the error colour for its EDGE
        // only. Recolouring the Ability's name would cost the row the one
        // thing it is for — telling Abilities apart at a glance — and a failed
        // call is still a call by that Ability.
        let edge: Color = state == .attention ? .maryError : tint
        HStack(spacing: 5) {
            if state.isRunning {
                RunningPulse(tint: tint)
            }
            Text(presentation.abilityTitle)
                .foregroundStyle(tint)
            if let providerTitle = presentation.providerTitle {
                Text("·")
                    .foregroundStyle(Color.primary.opacity(0.32))
                Text(providerTitle)
                    .foregroundStyle(Color.primary.opacity(0.7))
            }
            if let realization = presentation.realization {
                HStack(spacing: 2) {
                    Image(systemName: realization.symbol)
                    Text(realization.badgeWord)
                }
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Capsule().fill(tint.opacity(0.12)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(realization.label)
                .help(realization.help)
            }
            Text("|")
                .foregroundStyle(Color.primary.opacity(0.32))
            Text(presentation.invocationName)
                .foregroundStyle(Color.primary.opacity(0.7))
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .padding(.horizontal, .layer2)
        .padding(.vertical, 4)
        .background(Capsule().fill(edge.opacity(0.07)))
        .overlay(
            Capsule().strokeBorder(
                edge.opacity(state == .attention ? 0.55 : 0.34),
                lineWidth: 1)
        )
        // A RUNNING CHIP IS DIMMER, NOT BUSIER. It has not finished saying
        // what it did, and printing it at full weight beside settled chips
        // claims a result it does not have yet.
        .opacity(state.isRunning ? 0.72 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(presentation, runs))
    }

    private func accessibilityLabel(
        _ presentation: AbilityBadgePresentation,
        _ runs: [BehavioralActionRecord]
    ) -> String {
        guard let state = AbilityRunPresentation.stateWord(runs) else {
            return presentation.accessibilityLabel
        }
        return "\(presentation.accessibilityLabel), \(state)"
    }

    // MARK: - Place capsule (the lens)

    /// `with: Sketch, Safari (glanced)` — the responder-layer signal beside
    /// the lead chip. Capped at two names; a longer tail says how many more.
    @ViewBuilder
    private func coActiveCapsule(_ entry: RealmLensEntry) -> some View {
        let names = entry.coActivePlaces.prefix(2).map { place -> String in
            entry.glancedPlaces.contains(place)
                ? "\(place.displayName) (glanced)"
                : place.displayName
        }
        let overflow = entry.coActivePlaces.count - names.count
        let label = names.joined(separator: ", ")
            + (overflow > 0 ? " +\(overflow)" : "")
        HStack(spacing: 5) {
            Text("with:")
                .foregroundStyle(Color.primary.opacity(0.45))
            Text(label)
                .foregroundStyle(Color.primary.opacity(0.7))
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .padding(.horizontal, .layer2)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .overlay(
            Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Also in play: \(label)")
        .help("Places with fresh evidence beside the lead when this turn ran")
    }

    /// `led: Sketch · dynamic` / `led: Pages · workspace` — which place led
    /// the turn these chips ran under. Same capsule family as the badges
    /// beside it; a subtle green tint marks a Dynamic application, the
    /// warm gold stays for native worlds.
    @ViewBuilder
    private func realmCapsule(_ place: AmbientPlace) -> some View {
        let accent: Color = place.isApplication ? .maryGreen : .maryGold
        let classWord = place.isApplication ? "dynamic" : place.worldClass.rawValue
        let capsule = HStack(spacing: 5) {
            Text("led:")
                .foregroundStyle(Color.primary.opacity(0.45))
            Text(place.displayName)
                .foregroundStyle(accent)
            Text("·")
                .foregroundStyle(Color.primary.opacity(0.32))
            Text(classWord)
                .foregroundStyle(Color.primary.opacity(0.7))
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .padding(.horizontal, .layer2)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(accent.opacity(place.isApplication ? 0.1 : 0.07))
        )
        .overlay(
            Capsule().strokeBorder(accent.opacity(0.34), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Led by \(place.displayName), \(classWord) place")
        if let onOpenRoutes {
            Button(action: onOpenRoutes) { capsule }
                .buttonStyle(.plain)
                .help("Which place led this turn — open the Routes pane")
        } else {
            capsule
                .help("Which place led this turn")
        }
    }
}
