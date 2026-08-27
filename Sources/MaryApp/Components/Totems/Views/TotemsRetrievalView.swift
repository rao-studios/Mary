//
//  TotemsRetrievalView.swift
//  Mary
//
//  Why the panel exists: per-turn rows of what retrieval was asked and what
//  came back — route → plan → sent scope → contribution → ambient injection
//  → prompt-spend waterfall — with the builder's warnings on top. Partial
//  rows render their NAMED state and stay; a dropped row would hide exactly
//  the turn worth explaining.
//

import MaryBrain
import SwiftUI

struct TotemsRetrievalView: View {

    @ObservedObject var vm: TotemExplorerViewModel
    @Binding var selectedExchangeID: String?
    /// The retrieval→library deep link — the pane view owns the tab switch.
    var onOpenDocument: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: .layer3) {
            if vm.retrievalRows.isEmpty {
                Text("No turns yet. Speak or type, and each exchange's retrieval story lands here.")
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.5))
                    .padding(.top, .layer4)
            }
            ForEach(vm.retrievalRows) { row in
                turnCard(row)
            }
        }
        .padding(.horizontal, .layer4)
    }

    // MARK: - Turn card

    private func turnCard(_ row: TotemRetrievalTurnRow) -> some View {
        let isOpen = selectedExchangeID == row.id
        return MaryCard(padding: 12) {
            VStack(alignment: .leading, spacing: .layer2) {
                Button {
                    selectedExchangeID = isOpen ? nil : row.id
                } label: {
                    header(row, isOpen: isOpen)
                }
                .buttonStyle(.plain)

                if isOpen {
                    Divider()
                    detail(row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ row: TotemRetrievalTurnRow, isOpen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: .layer2) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.maryInk.opacity(0.4))
                if let utterance = row.utterance {
                    Text(utterance)
                        .font(.marySerif(12, weight: .light, italic: true))
                        .foregroundStyle(Color.maryInk)
                        .lineLimit(2)
                } else {
                    Text("(no utterance)")
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                }
                Spacer()
                if !row.warnings.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.maryError.opacity(0.8))
                }
                Text(row.date, style: .relative)
                    .font(.maryMono(9))
                    .foregroundStyle(Color.maryInk.opacity(0.4))
            }
            if let routeLine = row.routeLine {
                Text(routeLine)
                    .font(.maryMono(9))
                    .foregroundStyle(Color.maryInk.opacity(0.5))
            }
            if let state = row.state {
                // A named partial state is content, not an error.
                Text(state)
                    .font(.marySans(9))
                    .foregroundStyle(Color.maryGold)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private func detail(_ row: TotemRetrievalTurnRow) -> some View {
        ForEach(row.warnings) { warning in
            Text(warning.message)
                .font(.marySans(10))
                .foregroundStyle(Color.maryError)
        }

        if let plan = row.plan {
            planSection(plan)
        }

        ForEach(row.requests) { request in
            requestSection(request)
        }

        if let contribution = row.contribution {
            contributionSection(contribution)
        }

        ForEach(Array(row.ambient.enumerated()), id: \.offset) { _, injection in
            ambientSection(injection)
        }

        ForEach(Array(row.promptSpend.enumerated()), id: \.offset) { _, trace in
            spendSection(trace)
        }
    }

    // MARK: Plan

    private func planSection(_ plan: TotemMemoryPlanRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel("Plan")
            line("Lanes", plan.lanes.joined(separator: " · "))
            if !plan.lanePriority.isEmpty {
                line("Priority", plan.lanePriority.joined(separator: " → "))
            }
            if !plan.applicationIDs.isEmpty {
                line("Applications", plan.applicationIDs.joined(separator: ", "))
            }
            if !plan.relationshipHints.isEmpty {
                line("Hints", plan.relationshipHints.joined(separator: ", "))
            }
        }
    }

    // MARK: Requests

    private func requestSection(_ request: TotemRetrievalRequestRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel("Sent scope")
            HStack(spacing: .layer2) {
                Text(request.transport.rawValue)
                    .font(.maryMono(9))
                    .foregroundStyle(Color.maryInk.opacity(0.6))
                Text(request.aggregate ? "aggregate" : "\(request.groups.count) groups")
                    .font(.marySans(9))
                    .foregroundStyle(Color.maryInk.opacity(0.5))
                if request.isAnswered {
                    HStack(spacing: 2) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 8))
                        Text("answered")
                            .font(.marySans(9))
                    }
                    .foregroundStyle(Color.maryGreen)
                }
                Spacer()
            }
            Text(request.id)
                .font(.maryMono(8))
                .foregroundStyle(Color.maryInk.opacity(0.35))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if !request.groups.isEmpty {
                FlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(request.groups) { group in
                        groupTag(group)
                    }
                }
            }
            if !request.relationshipHints.isEmpty {
                line("Hints", request.relationshipHints.joined(separator: ", "))
            }
        }
        .padding(.top, .layer1)
    }

    private func groupTag(_ group: TotemScopeGroupTag) -> some View {
        HStack(spacing: 3) {
            Text(group.label.isEmpty ? group.id : group.label)
                .font(.maryMono(9))
                .foregroundStyle(Color.maryInk.opacity(0.7))
            Text(group.familyTitle.uppercased())
                .font(.marySans(7, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.maryGold)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.maryInk.opacity(0.06)))
    }

    // MARK: Contribution

    private func contributionSection(_ contribution: SeerContributionTrace) -> some View {
        VStack(alignment: .leading, spacing: .layer2) {
            SectionLabel("Contribution")
            if contribution.owners.isEmpty {
                Text("Came back empty — no owner was credited.")
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.5))
            }
            ForEach(contribution.owners) { owner in
                ownerRow(owner)
            }
        }
        .padding(.top, .layer1)
    }

    private func ownerRow(_ owner: SeerContributionTrace.OwnerTrace) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: .layer2) {
                Text("Totem \(owner.totemID)")
                    .font(.maryMono(9))
                    .foregroundStyle(Color.maryInk.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(String(format: "%.0f%% · %d spans · %d chars",
                            owner.royalty * 100, owner.spanCount, owner.creditedChars))
                    .font(.marySans(9))
                    .foregroundStyle(Color.maryInk.opacity(0.55))
            }
            // The influence capsule, ContributionInspector's idiom.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.maryInk.opacity(0.08))
                    Capsule()
                        .fill(Color.maryGold.opacity(0.6))
                        .frame(width: max(2, geo.size.width * min(1, owner.royalty)))
                }
            }
            .frame(height: 3)
            ForEach(owner.documentIDs, id: \.self) { documentID in
                Button {
                    // Deep link: this document, opened where documents live.
                    onOpenDocument(documentID)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 8))
                        Text(documentID)
                            .font(.maryMono(9))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let influence = owner.influence[documentID] {
                            Text(String(format: "%.0f%%", influence * 100))
                                .font(.marySans(8))
                        }
                    }
                    .foregroundStyle(Color.maryInk.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Ambient

    private func ambientSection(_ injection: AmbientInjectionTrace) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel("Ambient · \(injection.lane.rawValue)")
            line("Mode", injection.mode.rawValue)
            line(
                "Rendered",
                "\(injection.keys.count) keys → \(injection.blockCount) blocks + \(injection.mentionCount) mentions")
            line("Budget", "\(injection.blockChars) / \(injection.budget) chars")
            if !injection.keys.isEmpty {
                Text(injection.keys.map(\.id).joined(separator: "  "))
                    .font(.maryMono(8))
                    .foregroundStyle(Color.maryInk.opacity(0.4))
                    .lineLimit(3)
            }
        }
        .padding(.top, .layer1)
    }

    // MARK: Prompt spend

    private func spendSection(_ trace: PromptSpendTrace) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel("Prompt · \(trace.lane.rawValue)")
            ForEach(trace.spend, id: \.id) { spend in
                HStack(spacing: .layer2) {
                    Text(spend.id.rawValue)
                        .font(.maryMono(9))
                        .foregroundStyle(Color.maryInk.opacity(
                            spend.outcome == .rendered ? 0.7 : 0.35))
                    if spend.outcome != .rendered {
                        Text(spend.outcome.rawValue)
                            .font(.marySans(8))
                            .foregroundStyle(Color.maryInk.opacity(0.35))
                    }
                    Spacer()
                    Text("\(spend.chars)")
                        .font(.maryMono(9))
                        .foregroundStyle(Color.maryInk.opacity(0.5))
                }
                .help(spend.rationale)
            }
            HStack(spacing: .layer2) {
                Text("appended")
                    .font(.maryMono(9))
                    .foregroundStyle(Color.maryInk.opacity(0.5))
                Spacer()
                Text("\(trace.appendedChars)")
                    .font(.maryMono(9))
                    .foregroundStyle(Color.maryInk.opacity(0.5))
            }
            HStack(spacing: .layer2) {
                Text("total")
                    .font(.maryMono(9))
                    .foregroundStyle(Color.maryInk.opacity(0.7))
                Spacer()
                Text("\(trace.totalChars)")
                    .font(.maryMono(9))
                    .foregroundStyle(Color.maryInk.opacity(0.7))
            }
        }
        .padding(.top, .layer1)
    }

    // MARK: - Bits

    private func line(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: .layer2) {
            Text(name.uppercased())
                .font(.maryMono(8))
                .foregroundStyle(Color.maryInk.opacity(0.35))
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.marySans(10))
                .foregroundStyle(Color.maryInk.opacity(0.7))
        }
    }
}
