//
//  UtteranceView.swift
//  Mary
//
//  A finalized utterance. Assistant replies carry Gita's PassageView look
//  verbatim (the plainParagraphs path): serif 18 light italic, primary@0.75,
//  lineSpacing 7, kerning 0.3, "\n\n" paragraph split, HistoryDepth fade.
//  User utterances read smaller (note2, upright) behind a 2pt gold rule so
//  the page reads as a dialogue without breaking the ink-on-paper feel.
//

import MaryBrain
import SwiftUI
import MaryRuntime

/// Pure, frozen presentation derived only from the receipt retained by the
/// conversation. Rendering never consults the active Ability registry, so a
/// provider rename, package edit, or uninstall cannot rewrite an old chip.
struct AbilityBadgePresentation: Equatable {
    let abilityTitle: String
    let providerTitle: String?
    let invocationName: String
    let showsAbilityProviderIndicator: Bool
    /// HOW this Skill was implemented, or nil when the frozen receipt cannot
    /// say (a legacy transcript, a cognitive Skill, the runtime fallback).
    ///
    /// REALIZATION, NOT PARADIGM, and deliberately: a chip is rendered from
    /// the retained receipt and must never consult the live registry, so the
    /// Ability's ROLE — discipline, application expertise — is not available
    /// here and is shown in Ability Studio and the run inspector instead. The
    /// chip already carries the composition in its own way: "Design · Sketch"
    /// says the craft and the tool that performed it.
    let realization: AbilityRealizationPresentation?

    init(reference: AbilitySkillReference) {
        let title = reference.abilityTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        abilityTitle = title.isEmpty ? reference.abilityID.rawValue : title
        let provider = reference.provider?.pluginTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
        providerTitle = provider?.isEmpty == false ? provider : nil
        invocationName = reference.invocationName
        showsAbilityProviderIndicator = reference.provider?.pluginClass == .package
        realization = reference.provider.map {
            AbilityRealizationPresentation($0.pluginClass)
        }
    }

    var dynamicProviderHelp: String? {
        guard showsAbilityProviderIndicator, let providerTitle else { return nil }
        return "\(providerTitle) is a Dynamic Plugin installed by an Ability, not built into Mary."
    }

    /// A chip is Equatable for diffing; the presentation structs are value
    /// types over an enum, so this stays cheap.
    static func == (lhs: AbilityBadgePresentation, rhs: AbilityBadgePresentation) -> Bool {
        lhs.abilityTitle == rhs.abilityTitle
            && lhs.providerTitle == rhs.providerTitle
            && lhs.invocationName == rhs.invocationName
            && lhs.showsAbilityProviderIndicator == rhs.showsAbilityProviderIndicator
    }

    var accessibilityLabel: String {
        var components = ["\(abilityTitle) Ability"]
        if let providerTitle {
            components.append(showsAbilityProviderIndicator
                ? "\(providerTitle), Ability-provided Dynamic Plugin"
                : "\(providerTitle), Native Plugin")
        }
        components.append("\(invocationName) tool")
        return components.joined(separator: ", ")
    }
}

struct UtteranceView: View {
    let utterance: Utterance
    /// Focus fade — 1.0 for the focal (latest) utterance, lower for history.
    let inkOpacity: Double
    let blurRadius: CGFloat
    /// The place that led this exchange, resolved LIVE by `RealmLensProvider`
    /// from the trace log — never persisted with the transcript. Nil for
    /// restored conversations and rows older than the trace ring; the badge
    /// row then renders exactly as before.
    var realmLensEntry: RealmLensEntry? = nil
    /// Tap-through to the Routes pane (Home's existing header toggle). Nil
    /// renders the capsule non-interactive.
    var onOpenRoutes: (() -> Void)? = nil

    /// A tapped brushstroke's owner — presents the totem inspector.
    @State private var inspectedOwner: SeerContribution.Owner?

    /// A tapped ability chip — presents that Skill's run log for this reply
    /// (arguments, receipt summaries, status), the silo the machine
    /// summaries moved into.
    @State private var inspectedRuns: InspectedAbilityRuns?

    var body: some View {
        Group {
            switch utterance.role {
            case .assistant:
                assistantBody
            case .user:
                userBody
            }
        }
        .frame(maxWidth: Paper.measure, alignment: .leading)
        .modifier(HistoryDepth(inkOpacity: inkOpacity, blurRadius: blurRadius))
        .sheet(item: $inspectedOwner) { owner in
            ContributionInspectorSheet(owner: owner, responseText: utterance.text)
        }
        .sheet(item: $inspectedRuns) { inspected in
            AbilityRunInspectorSheet(inspected: inspected)
        }
    }

    // MARK: - Assistant (Gita passage; brushstroke highlights when the reply
    // carries contribution spans)

    private var contributionSpans: [ContributionTextSpan] {
        guard let contribution = utterance.contribution else { return [] }
        return ContributionSpans.makeSpans(text: utterance.text, contribution: contribution)
    }

    private var assistantBody: some View {
        let spans = contributionSpans
        return VStack(alignment: .leading, spacing: 16) {
            if spans.isEmpty {
                ForEach(
                    Array(utterance.text.components(separatedBy: "\n\n").enumerated()),
                    id: \.offset
                ) { _, chunk in
                    Text(chunk)
                        .font(.system(size: 18, weight: .light, design: .serif))
                        .italic()
                        .kerning(0.3)
                        .lineSpacing(7)
                        .foregroundStyle(Color.primary.opacity(0.75))
                }
            } else {
                ContributionHighlightText(
                    text: utterance.text,
                    spans: spans,
                    onTapOwner: { owner in inspectedOwner = owner }
                )
            }
            // Detached-routine narration merged into this bubble — always
            // the plain italic-serif look (even when the main body is
            // contribution-highlighted); slightly lighter ink marks it as
            // later narration. Spans keep indexing `text` only — no drift.
            if let followUp = utterance.followUpText, !followUp.isEmpty {
                ForEach(
                    Array(followUp.components(separatedBy: "\n\n").enumerated()),
                    id: \.offset
                ) { _, chunk in
                    Text(chunk)
                        .font(.system(size: 18, weight: .light, design: .serif))
                        .italic()
                        .kerning(0.3)
                        .lineSpacing(7)
                        .foregroundStyle(Color.primary.opacity(0.65))
                }
            }
            if !utterance.abilityBadges.isEmpty {
                abilityBadges
            }
        }
    }

    // MARK: - User (dialogue line)

    private var userBody: some View {
        HStack(alignment: .top, spacing: .layer3) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.maryGold.opacity(0.55))
                .frame(width: 2)
                .padding(.vertical, 2)
            Text.note2(utterance.text)
                .lineSpacing(6)
                .kerning(0.2)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Ability | Skill badges

    private var abilityBadges: some View {
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
            ForEach(Array(utterance.abilityBadges.enumerated()), id: \.offset) { _, reference in
                let presentation = AbilityBadgePresentation(reference: reference)
                Button {
                    inspectedRuns = InspectedAbilityRuns(
                        reference: reference,
                        runs: utterance.actions.filter { $0.action.skill == reference })
                } label: {
                    badgeLabel(reference: reference, presentation: presentation)
                }
                .buttonStyle(.plain)
                .help("Show this Skill's calls — arguments, receipts, status")
            }
        }
    }

    /// The Ability | Skill badge's own label — split out from `abilityBadges`
    /// so the type checker isn't asked to solve one Button+HStack expression
    /// per ForEach iteration in a single pass (SE cannot resolve that in
    /// reasonable time once enough sibling overloads are in scope).
    @ViewBuilder
    private func badgeLabel(
        reference: AbilitySkillReference,
        presentation: AbilityBadgePresentation
    ) -> some View {
        HStack(spacing: 5) {
            Text(presentation.abilityTitle)
                .foregroundStyle(Color.maryAbilityTint(reference.abilityTint))
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
                .foregroundStyle(Color.maryAbilityTint(reference.abilityTint))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(
                        Color.maryAbilityTint(reference.abilityTint).opacity(0.12))
                )
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
        .background(
            Capsule().fill(
                Color.maryAbilityTint(reference.abilityTint).opacity(0.07))
        )
        .overlay(
            Capsule().strokeBorder(
                Color.maryAbilityTint(reference.abilityTint).opacity(0.34),
                lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
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

/// The fade/blur of older utterances. The padding pair keeps the Gaussian's
/// bleed from hard-clipping at the row's edge.
///
/// ONE UNCONDITIONAL TREE, and that is load-bearing. This was
/// `if blurRadius > 0 { …drawingGroup() } else { … }`, which SwiftUI compiles
/// to `_ConditionalContent` — so crossing the blur threshold is a BRANCH
/// CHANGE, not a value change, and SwiftUI answers it by tearing the row's
/// whole subtree down and rebuilding it inside a brand-new `.drawingGroup()`
/// Metal layer. A layer that has not rasterized yet draws NOTHING, which is
/// why the wall went blank until a scroll forced it to redraw. And it fired
/// on every new message: `appendExchange` adds two rows at once, so every
/// existing row's distance-from-focus jumps by 2 and clears the `>= 2`
/// threshold in a single step.
///
/// `.drawingGroup()` is gone with it. It was a scroll-perf hedge against a
/// long lazy list — a live `.blur` is a per-frame offscreen Gaussian — but
/// the page is bounded to the Settings context window now, so there is no
/// long list left to amortize, and rasterizing was the thing that blanked.
/// A blur radius of 0 is already a no-op on the focal rows.
struct HistoryDepth: ViewModifier {
    let inkOpacity: Double
    let blurRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(inkOpacity)
            .padding(3)
            .blur(radius: blurRadius)
            .padding(-3)
    }
}
