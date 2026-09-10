//
//  PerceptionInspectorView.swift
//  Mary
//
//  WHAT: Drill-in for one watched world (snapshot, blindness, next prompt, pin).
//  IN:   one PerceptionCard (same as tile captions)
//

import SwiftUI
import MaryRuntime

struct PerceptionInspectorView: View {
    let card: PerceptionCard
    let focus: FocusSummary
    let onTogglePin: () -> Void
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: .layer3) {
            header
            metaCard
            if let blindness = card.blindness {
                blindnessCard(blindness)
            }
            if !card.fields.isEmpty {
                fieldsCard
            }
            contributionCard
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: .layer2) {
            StatusDot(color: card.blindness == nil ? .maryGreen : .maryError)
            Text(card.world.displayName)
                .font(.marySans(13, weight: .medium))
                .foregroundStyle(Color.maryInk)
            if card.isPinned {
                Text("PINNED")
                    .font(.marySans(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.maryGold)
                    .padding(.horizontal, .layer2)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().strokeBorder(Color.maryGold.opacity(0.45), lineWidth: 1)
                    )
            }
            Spacer()
            if card.world.hasLiveObserver {
                Button(card.isPinned ? "Unpin" : "Pin") { onTogglePin() }
                    .buttonStyle(.maryQuiet)
            } else {
                Text("UNAVAILABLE")
                    .font(.marySans(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.maryError)
            }
            Button("Copy") { onCopy() }
                .buttonStyle(.mary)
        }
    }

    // MARK: - Meta

    private var metaCard: some View {
        MaryCard(padding: 12) {
            VStack(alignment: .leading, spacing: .layer3) {
                HStack(alignment: .top, spacing: .layer4) {
                    stat("Poll", card.pollDescription)
                    stat("Age", age(of: card.capturedAt))
                    stat("Last success", age(of: card.lastSuccessAt))
                }
                stat("Routing", card.routing)
                // Stacked, not side by side: the pane's content floor is
                // ~268pt and both values are phrases, not numbers.
                stat("Delivery", card.delivery)
                // Watcher's contribution (not Skill results).
                stat("Last read", focus.readDelivery?.summary ?? "none this session")
                // Held facts (eyeless worlds too), not live contribution.
                stat(
                    "Holding",
                    focus.heldReads.isEmpty
                        ? "nothing held"
                        : "\(focus.heldReads.count) fact\(focus.heldReads.count == 1 ? "" : "s") — ranked by \(focus.rankingMode.rawValue)")
                if let error = card.lastError {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last error")
                            .font(.marySans(10))
                            .foregroundStyle(Color.maryInk.opacity(0.5))
                        Text(error)
                            .font(.maryMono(10))
                            .foregroundStyle(Color.maryError)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Blindness

    private func blindnessCard(_ blindness: PerceptionCard.Blindness) -> some View {
        MaryCard(padding: 12) {
            VStack(alignment: .leading, spacing: .layer2) {
                HStack(spacing: .layer2) {
                    StatusDot(color: .maryError)
                    Text(blindness.label)
                        .font(.maryMono(11))
                        .foregroundStyle(Color.maryError)
                }
                Text(blindness.remedy)
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Fields

    private var fieldsCard: some View {
        MaryCard(padding: 12) {
            VStack(alignment: .leading, spacing: .layer2) {
                SectionLabel("Snapshot")
                ForEach(card.fields, id: \.label) { field in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(field.label)
                            .font(.marySans(9, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(Color.maryInk.opacity(0.45))
                        Text(field.value)
                            .font(.marySans(11))
                            .foregroundStyle(Color.maryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Contribution

    private var contributionCard: some View {
        MaryCard(padding: 12) {
            VStack(alignment: .leading, spacing: .layer2) {
                SectionLabel("Next turn receives")
                if let contribution = card.contribution {
                    Text(contribution)
                        .font(.maryMono(10))
                        .foregroundStyle(Paper.graphite)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Text("Nothing — this watcher contributes no section right now.")
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk.opacity(0.5))
                }
                ForEach(card.extraContributions, id: \.label) { extra in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(extra.label)
                            .font(.marySans(9, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(Color.maryInk.opacity(0.45))
                        Text(extra.value)
                            .font(.maryMono(10))
                            .foregroundStyle(Paper.graphite)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Helpers

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.marySans(11, weight: .medium))
                .foregroundStyle(Color.maryInk)
            Text(label)
                .font(.marySans(10))
                .foregroundStyle(Color.maryInk.opacity(0.5))
        }
    }

    private func age(of date: Date?) -> String {
        guard let date else { return "never" }
        return PerceptionReport.ageString(Date().timeIntervalSince(date))
    }
}
