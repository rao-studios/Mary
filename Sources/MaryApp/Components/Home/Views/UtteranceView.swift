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

    /// The row itself lives in `AbilityBadgeRow` so the streaming reply can
    /// render it too — see that file's header.
    private var abilityBadges: some View {
        AbilityBadgeRow(
            badges: utterance.abilityBadges,
            actions: utterance.actions,
            realmLensEntry: realmLensEntry,
            onOpenRoutes: onOpenRoutes,
            onInspect: { reference, runs in
                inspectedRuns = InspectedAbilityRuns(
                    reference: reference,
                    runs: runs,
                    turnID: utterance.turnID)
            })
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
