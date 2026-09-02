//
//  UtteranceView.swift
//  Mary
//
//  WHAT: Finalized utterance. Assistant: serif 18 light italic. User: note2 + gold rule.
//  OUT:  AbilityBadgeRow / ContributionHighlightText
//

import MaryBrain
import SwiftUI
import MaryRuntime

/// Frozen presentation from the receipt. Never consults the live Ability registry.
struct AbilityBadgePresentation: Equatable {
    let abilityTitle: String
    let providerTitle: String?
    let invocationName: String
    let showsAbilityProviderIndicator: Bool
    /// Realization (not paradigm), or nil when the frozen receipt cannot say.
    /// Chip never consults the live registry.
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
    /// Lead place from RealmLensProvider (live trace). Nil for restored/old rows.
    var realmLensEntry: RealmLensEntry? = nil
    /// Tap-through to the Routes pane (Home's existing header toggle). Nil
    /// renders the capsule non-interactive.
    var onOpenRoutes: (() -> Void)? = nil

    /// A tapped brushstroke's owner — presents the totem inspector.
    @State private var inspectedOwner: SeerContribution.Owner?

    /// Tapped chip → AbilityRunInspectorSheet for this reply.
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
            // Detached-routine narration: plain italic-serif, lighter ink. Spans index `text` only.
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
            if !utterance.abilityBadges.isEmpty || !utterance.ownReads.isEmpty {
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
            ownReads: utterance.ownReads,
            realmLensEntry: realmLensEntry,
            onOpenRoutes: onOpenRoutes,
            onInspect: { reference, runs in
                inspectedRuns = InspectedAbilityRuns(
                    reference: reference,
                    runs: runs,
                    turnID: utterance.turnID)
            },
            onInspectOwnReads: { runs in
                inspectedRuns = InspectedAbilityRuns(
                    ownReads: runs, turnID: utterance.turnID)
            })
    }

}

/// History fade/blur. Unconditional tree (not if/else `.drawingGroup()` — that blanked on branch change).
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
