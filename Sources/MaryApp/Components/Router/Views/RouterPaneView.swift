//
//  RouterPaneView.swift
//  Mary
//
//  WHAT: AmbientEngine decisions, newest first. 1 Hz VM; Granite stays click-scoped.
//  OUT:  RouteTraceViewModel
//

import MaryAmbient
import MaryBrain
import SwiftUI

struct RouterPaneView: View {
    @Binding var selectedTraceID: String?
    /// `AmbientIntent.rawValue`, or nil for all.
    @Binding var intentFilter: String?

    @StateObject private var vm = RouteTraceViewModel()
    /// View-local (Totems pane's Servers/Life precedent): held in the Center
    /// this flag would re-present the sheet on every panel rebuild. Closing
    /// the pane mid-sheet dismisses the sheet with it.
    @State private var showsAbilityRuns = false

    /// The filter token for unprompted remarks. Not an `AmbientIntent` —
    /// a remark answers no utterance and so has no intent to classify.

    private var visibleRows: [RouteRow] {
        guard let intentFilter, let intent = AmbientIntent(rawValue: intentFilter) else {
            return vm.rows
        }
        return vm.rows.filter { $0.intent == intent }
    }

    private var visibleEntries: [RouterEntry] {
        guard let intentFilter else { return vm.entries }
        guard let intent = AmbientIntent(rawValue: intentFilter) else { return vm.entries }
        return vm.entries.filter {
            if case .turn(let row) = $0 { return row.intent == intent }
            return false
        }
    }

    private var actions: [SkillRunReceipt] { vm.rows.flatMap(\.skillRuns) }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .layer4) {
                if vm.entries.isEmpty {
                    EmptyHero(
                        title: "No decisions yet",
                        subtitle: "Say something to Mary — or let her notice something on her own — and the route she took will show up here.")
                        .padding(.top, .layer5)
                } else {
                    registrySummary
                    ForEach(visibleEntries) { entry in
                        switch entry {
                        case .turn(let row): rowCard(row)
                        }
                    }
                }
            }
            .padding(.layer4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Its own backing, or it blends into the conversation column.
        .background(Paper.page)
        .safeAreaInset(edge: .top) { filterBar }
        .sheet(isPresented: $showsAbilityRuns) { AbilityExecutionLogSheet() }
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: .layer2) {
            HStack(spacing: .layer2) {
                Text("Routes")
                    .font(.marySerif(15, weight: .light, italic: true))
                    .foregroundStyle(Paper.ink.opacity(0.85))
                Button {
                    showsAbilityRuns = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                        .foregroundStyle(Paper.ink.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ability runs")
                Spacer()
                Button {
                    copyReport()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(Paper.ink.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy routing report")
                Button {
                    AmbientTraceLog.shared.clear()
                    // Both ledgers, or the pane half-clears and the
                    // remaining rows look like a bug.
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Paper.ink.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear routes")
            }
            // Word chips at intrinsic width (FlowLayout). Adaptive grid mid-word-wraps labels.
            FlowLayout(spacing: .layer1, lineSpacing: .layer1) {
                intentChip(nil, label: "all")
                ForEach(AmbientIntent.allCases, id: \.self) { intent in
                    intentChip(intent, label: intent.rawValue)
                }
            }
        }
        .padding(.horizontal, .layer4)
        .padding(.vertical, .layer2)
        .background(Paper.page)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.maryBorder).frame(height: 1)
        }
    }


    private func intentChip(_ intent: AmbientIntent?, label: String) -> some View {
        let token = intent?.rawValue
        // "all" is the nil filter, and selecting the active chip clears it —
        // so the bar always has exactly one thing lit.
        let isOn = intentFilter == token
        return MaryChip(label: label, isOn: isOn) {
            intentFilter = isOn ? nil : token
        }
    }

    // MARK: - Ability registry summary

    private var registrySummary: some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer1) {
                SectionLabel("Ability routing")
                Text("\(vm.rows.count) turns · \(actions.count) skill runs · \(Set(vm.rows.map(\.registryRevision)).count) registry revisions")
                    .font(.marySans(11))
                    .foregroundStyle(Paper.ink.opacity(0.7))
                Text("Each turn retains its package revision, structured Skill receipts, and privacy-safe Interaction references.")
                    .font(.marySans(10))
                    .foregroundStyle(Paper.ink.opacity(0.45))
            }
        }
    }

    // MARK: - One turn

    private func rowCard(_ row: RouteRow) -> some View {
        let isOpen = selectedTraceID == row.id.uuidString
        return MaryCard {
            VStack(alignment: .leading, spacing: .layer2) {
                Button {
                    selectedTraceID = isOpen ? nil : row.id.uuidString
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: .layer1) {
                            Text(row.intent.rawValue)
                                .font(.maryMono(10))
                                .foregroundStyle(Paper.ink)
                            Text("via \(row.decidedBy.rawValue)")
                                .font(.maryMono(9))
                                .foregroundStyle(Paper.ink.opacity(0.5))
                            Spacer()
                            if row.skillRuns.contains(where: { $0.status == .failed || $0.status == .blocked }) {
                                StatusDot(color: .maryError)
                            }
                            Text(RouteReport.ageString(row.age(at: Date())))
                                .font(.maryMono(9))
                                .foregroundStyle(Paper.ink.opacity(0.4))
                        }
                        Text(row.utterance)
                            .font(.marySans(11))
                            .foregroundStyle(Paper.ink.opacity(0.8))
                            .lineLimit(isOpen ? nil : 2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)

                if isOpen { detail(row) }
            }
        }
    }

    @ViewBuilder
    private func detail(_ row: RouteRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider().opacity(0.4)
            leadField(row)
            field("named", row.namedPlaces.map(\.displayName).joined(separator: ", "))
            field("worlds", row.candidateAttentions.map(\.rawValue).joined(separator: ", "))
            field("ranking", row.rankingMode.rawValue)
            if let attention = row.world {
                field("attention", attentionDescription(attention))
            }
            if let writingTarget = row.writingTarget {
                field("writing target", writingTarget.rawValue)
            }
            if let supportingContext = row.supportingContext {
                field("writing context", supportingContext)
            }
            field("questions", row.gate.questions.map(\.rawValue).sorted().joined(separator: ", "))
            field("abilities", row.gate.requestedAbilities.map(\.rawValue).sorted().joined(separator: ", "))
            field("totems", row.gate.memory.lanes.map(\.rawValue).sorted().joined(separator: ", "))
            field("needs", needsPhrase(row))
            field("prompt", "\(row.systemPromptChars) chars")
            field("registry", String(row.registryRevision.uuidString.prefix(12)))
            field("packages", row.packageIDs.map(\.rawValue).joined(separator: ", "))
            field("skills", "\(row.exposedSkillCount) exposed")
            if !row.abilityRoster.decisions.isEmpty {
                field(
                    "roster",
                    "\(row.abilityRoster.selected.count) selected · \(row.abilityRoster.decisions.count) evaluated")
                ForEach(row.abilityRoster.decisions) { decision in
                    field(
                        "candidate",
                        "\(decision.reference.displayLabel) · \(decision.disposition.rawValue)",
                        tint: decisionTint(decision))
                    let group = decision.conflictGroup ?? "none"
                    field(
                        "arbitration",
                        "group \(group) · \(decision.policy.rawValue) · typed evidence \(decision.evidence.total) / direct \(decision.evidence.directInteraction) / focus \(decision.evidence.focusedWorkspace) · declared preference \(decision.evidence.preference)")
                    field("reason", decision.reason)
                    if let alternative = decision.selectedAlternative {
                        field("selected", alternative.displayLabel)
                    }
                    if let primary = decision.fallbackFor {
                        field("fallback for", primary.displayLabel)
                    }
                }
            }
            ForEach(row.skillRuns) { run in
                field(
                    "skill",
                    "\(run.reference.displayLabel) · \(run.status.rawValue) · \(run.effect.rawValue)",
                    tint: run.status == .failed || run.status == .blocked
                        ? .maryError
                        : Color.maryAbilityTint(run.reference.abilityTint))
                if let adapterID = run.reference.adapterID,
                   let operation = run.reference.bindingOperation {
                    field("binding", "\(adapterID.rawValue)/\(operation)")
                }
                if !run.inputTypes.isEmpty {
                    field("inputs", run.inputTypes.map(\.rawValue).joined(separator: ", "))
                }
                if !run.outputTypes.isEmpty {
                    field("outputs", run.outputTypes.map(\.rawValue).joined(separator: ", "))
                }
                if let target = run.targetScope {
                    field("target scope", target.resolution.rawValue)
                }
                ForEach(run.consumedInteractions) { interaction in
                    field(
                        "interaction",
                        "\(interaction.schemaID.rawValue) · \(interaction.scope.resolution.rawValue) · \(interaction.completeness.rawValue)")
                }
                if run.foundNothing {
                    field("outcome", "no matching source value")
                }
            }
            Divider().opacity(0.4)
            field("effectful turn", row.verdicts.actionTurn ? "yes" : "no")
            field("edit", row.verdicts.editShape?.rawValue ?? "none")
            field("named part", row.verdicts.namedPart ?? "none")
            field("ambient source", row.verdicts.namesAmbientSource ? "yes" : "no")
            field("deictic", row.verdicts.isDeictic ? "yes" : "no")
            field("transform", row.verdicts.namesTransform ? "yes" : "no")
            field("override", row.verdicts.focusOverride.map(focusToken) ?? "none")
        }
        .textSelection(.enabled)
    }

    /// The lead as its REALM — display name plus a small class capsule — with
    /// a distinct accent when a Dynamic application led. Falls back to the
    /// plain field for rows recorded before places existed.
    @ViewBuilder
    private func leadField(_ row: RouteRow) -> some View {
        if let place = row.leadPlace {
            let accent: Color = place.isApplication ? .maryGreen : .maryGold
            HStack(alignment: .top, spacing: .layer1) {
                Text("lead")
                    .font(.maryMono(9))
                    .foregroundStyle(Paper.ink.opacity(0.45))
                    .frame(width: 88, alignment: .leading)
                HStack(spacing: .layer1) {
                    Text(place.displayName)
                        .font(.maryMono(9))
                        .foregroundStyle(place.isApplication ? accent : Paper.ink.opacity(0.75))
                    Text(place.placeClass.rawValue)
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(accent.opacity(0.12)))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            field("lead", row.lead?.rawValue ?? "none")
        }
    }

    private func field(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        HStack(alignment: .top, spacing: .layer1) {
            Text(label)
                .font(.maryMono(9))
                .foregroundStyle(Paper.ink.opacity(0.45))
                .frame(width: 88, alignment: .leading)
            Text(value.isEmpty ? "none" : value)
                .font(.maryMono(9))
                .foregroundStyle(tint ?? Paper.ink.opacity(0.75))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func needsPhrase(_ row: RouteRow) -> String {
        var needs: [String] = []
        if row.needsLocate { needs.append("locate") }
        if row.needsPreRead { needs.append("pre-read") }
        if row.needsExecution { needs.append("ability execution") }
        return needs.isEmpty ? "nothing" : needs.joined(separator: ", ")
    }

    private func focusToken(_ focus: WorkspaceFocus) -> String {
        switch focus {
        case .coding: return "coding"
        case .writing: return "writing"
        }
    }

    private func decisionTint(_ decision: AbilityRosterDecision) -> Color? {
        switch decision.disposition {
        case .selected:
            return Color.maryAbilityTint(decision.reference.abilityTint)
        case .clarificationRequired, .abstained, .ineligible:
            return .maryError
        case .inactiveAbility, .fallbackStandby, .conflictLost:
            return nil
        }
    }

    private func attentionDescription(_ attention: AmbientWorld) -> String {
        [attention.tier.displayName, attention.attention.displayName, attention.subject]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func copyReport() {
        let text = RouteReport.serialize(rows: vm.rows, at: Date())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

}
