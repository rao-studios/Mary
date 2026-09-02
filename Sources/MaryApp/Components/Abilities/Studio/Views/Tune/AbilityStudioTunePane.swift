//
//  AbilityStudioTunePane.swift
//  Mary
//
//  WHAT: What Mary listens for, and how it chooses this ability over another.
//  IN:   AbilityStudioView.
//  OUT:  mutateDraftPackage for vocabulary; mutateAuthoringDocument where the
//        graph is involved (supporting abilities pull in a dependency).
//  PIN:  Preference is a SORT KEY, not a weight — it orders the skills handed to
//        the model, and never decides a conflict. The caption says so because
//        the number looks like a weight and is not one.
//

import MaryBrain
import SwiftUI

@MainActor
struct AbilityStudioTunePane: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage
    @Environment(\.maryLayoutClass) private var layoutClass

    /// The intent keys shipped packages actually use.
    private static let intentKeys = ["operate", "perceive", "compose", "ask"]
    @State private var intentKey = "operate"
    @State private var showsRehearsal = false

    private var ability: AbilitySchema { package.ability }

    var body: some View {
        StudioPane("Tune", fills: false) {
            EmptyView()
        } content: {
            // Tune grows with an ability's vocabulary; capping it keeps the
            // bench on screen instead of pushing it off the bottom. The cap
            // itself shrinks with the window so the bench keeps its share
            // at the Studio's floor.
            ScrollView(.vertical) {
                knobs.padding(.trailing, 2)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: Paper.Layout.tuneCap[layoutClass] ?? 280)
        }
        .sheet(isPresented: $showsRehearsal) {
            AbilityStudioRehearsalSheet(model: model, package: package)
        }
    }

    private var knobs: some View {
        VStack(alignment: .leading, spacing: .layer2) {
            summary
            Divider().overlay(Color.maryBorder)
            vocabulary
            Divider().overlay(Color.maryBorder)
            routing
            Divider().overlay(Color.maryBorder)
            guardrails
            worksWith
            if package.plugin != nil || !(ability.applications ?? []).isEmpty {
                Divider().overlay(Color.maryBorder)
                AbilityStudioApplicationCard(model: model, package: package)
            }
        }
    }

    // MARK: - Summary

    private var summary: some View {
        knob("Summary") {
            StudioField(
                value: ability.summary,
                placeholder: "What is this ability for?",
                font: .marySerif(12, italic: true),
                quiet: true
            ) { next in
                model.mutateDraftPackage { draft in
                    draft.ability.summary = next
                    draft.package.summary = next
                }
            }
            .id(package.package.id)
        }
    }

    // MARK: - Vocabulary

    private var vocabulary: some View {
        VStack(alignment: .leading, spacing: .layer2) {
            knob("Listens for") {
                StudioChipEditor(values: ability.triggers.tokens) { next in
                    model.mutateDraftPackage { $0.ability.triggers.tokens = next }
                }
            }
            knob("Phrases") {
                StudioChipEditor(values: ability.triggers.phrases) { next in
                    model.mutateDraftPackage { $0.ability.triggers.phrases = next }
                }
            }
            knob("Not when") {
                StudioChipEditor(
                    values: ability.triggers.negativeTokens,
                    tint: .maryError
                ) { next in
                    model.mutateDraftPackage { $0.ability.triggers.negativeTokens = next }
                }
            }
            knob("Also called") {
                StudioChipEditor(values: ability.aliases) { next in
                    model.mutateDraftPackage { $0.ability.aliases = next }
                }
            }
            knob("Rehearse") {
                HStack(spacing: .layer2) {
                    Button {
                        showsRehearsal = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform")
                                .font(.system(size: 9))
                            Text("Say it and see").font(.marySans(10))
                        }
                        .foregroundStyle(Color.maryGold)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.maryGold.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    StudioNote("Run a sentence through the real matcher and see who answers.")
                }
            }
            knob("Sounds like") {
                VStack(alignment: .leading, spacing: .layer2) {
                    HStack(spacing: .layer1) {
                        ForEach(Self.intentKeys, id: \.self) { key in
                            MaryChip(label: key, isOn: key == intentKey) { intentKey = key }
                        }
                    }
                    StudioChipEditor(
                        values: ability.triggers.intentExemplars[intentKey] ?? [],
                        placeholder: "a whole sentence someone would say…"
                    ) { next in
                        model.mutateDraftPackage { draft in
                            if next.isEmpty {
                                draft.ability.triggers.intentExemplars[intentKey] = nil
                            } else {
                                draft.ability.triggers.intentExemplars[intentKey] = next
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Routing

    private var routing: some View {
        knob("Routing") {
            VStack(alignment: .leading, spacing: .layer2) {
                HStack(spacing: .layer2) {
                    StudioIntField(
                        "Order",
                        value: ability.routing.preference,
                        range: 0...300
                    ) { next in
                        model.mutateDraftPackage { $0.ability.routing.preference = next }
                    }
                }
                HStack(spacing: .layer2) {
                    StudioLabel("Competes in")
                    StudioField(
                        value: ability.routing.conflictGroup ?? "",
                        placeholder: "none",
                        mono: true
                    ) { next in
                        let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.mutateDraftPackage {
                            $0.ability.routing.conflictGroup = trimmed.isEmpty ? nil : trimmed
                        }
                    }
                    .frame(width: 110)
                    .id(package.package.id)
                }
                StudioMenuPicker(
                    label: "Settled by",
                    value: ability.routing.conflictPolicy,
                    options: RoutingConflictPolicy.allCases,
                    title: Self.policyWord
                ) { next in
                    model.mutateDraftPackage { $0.ability.routing.conflictPolicy = next }
                }
                StudioNote(routingExplanation)
            }
        }
    }

    private var routingExplanation: String {
        let group = ability.routing.conflictGroup ?? ""
        let rivals = group.isEmpty ? [] : model.snapshot.records
            .filter {
                $0.package.ability.routing.conflictGroup == group
                    && $0.package.ability.id != ability.id
            }
            .map(\.package.ability.title)
            .sorted()
        let arena = rivals.isEmpty
            ? "Nothing else competes for the same requests."
            : "Competes with \(rivals.prefix(3).joined(separator: ", "))\(rivals.count > 3 ? " and \(rivals.count - 3) more" : "")."
        return "\(arena) Order is a sort key, not a weight — it decides which skills Mary offers the model first, never who wins a conflict. Evidence settles that."
    }

    private static func policyWord(_ policy: RoutingConflictPolicy) -> String {
        switch policy {
        case .highestEvidence: return "the strongest evidence"
        case .preferDirectInteraction: return "what the user just touched"
        case .preferFocusedWorkspace: return "the app in front"
        case .askUser: return "asking the user"
        case .abstain: return "standing down"
        }
    }

    // MARK: - Guardrails

    private var guardrails: some View {
        knob("Careful about") {
            VStack(alignment: .leading, spacing: .layer2) {
                FlowLayout(spacing: .layer1) {
                    ForEach(GuardrailCategory.allCases, id: \.self) { category in
                        MaryChip(
                            label: Self.guardrailWord(category),
                            isOn: ability.operatingPolicy.guardrailCategories.contains(category)
                        ) {
                            toggle(category)
                        }
                    }
                }
            }
        }
    }

    private static func guardrailWord(_ category: GuardrailCategory) -> String {
        switch category {
        case .domainMismatch: return "wrong surface"
        case .unscopedTarget: return "only the named target"
        case .staleState: return "read it live"
        case .noFocusSteal: return "don't steal focus"
        case .nativeCommandOnly: return "the app's own command"
        case .irreversibleAction: return "cannot be undone"
        }
    }

    private func toggle(_ category: GuardrailCategory) {
        model.mutateDraftPackage { draft in
            var categories = draft.ability.operatingPolicy.guardrailCategories
            if let index = categories.firstIndex(of: category) {
                categories.remove(at: index)
            } else {
                categories.append(category)
            }
            draft.ability.operatingPolicy.guardrailCategories = categories
        }
    }

    // MARK: - Works with

    /// Not the dependency list. These are the abilities Mary must have on hand
    /// before this one may act: a missing one blocks the skill at dispatch, so
    /// only installed abilities are offered and the dependency is written too.
    private var worksWith: some View {
        let supporting = ability.operatingPolicy.defaultSupportingAbilities
        let realized = Set(package.extendedDisciplines.map(\.rawValue))
        return knob("Works with") {
            VStack(alignment: .leading, spacing: .layer2) {
                FlowLayout(spacing: .layer1) {
                    ForEach(package.extendedDisciplines, id: \.rawValue) { disciplineID in
                        pinnedChip(disciplineID)
                    }
                    ForEach(supporting.filter { !realized.contains($0.rawValue) }, id: \.rawValue) { abilityID in
                        removableChip(abilityID)
                    }
                    addSupportingMenu(supporting)
                }
                StudioNote(
                    "The abilities Mary must have on hand for this one to act. A named ability that is not installed blocks the skill, so only installed ones are offered. What this expertise realizes is pinned.")
            }
        }
    }

    private func pinnedChip(_ abilityID: AbilityID) -> some View {
        let tint = model.snapshot.records
            .first { $0.package.ability.id == abilityID }?
            .package.ability.tint ?? ""
        return HStack(spacing: 4) {
            Image(systemName: "lock")
                .font(.system(size: 7, weight: .semibold))
            Text(abilityID.rawValue).font(.maryMono(10))
        }
        .foregroundStyle(Color.maryAbilityTint(tint))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.maryAbilityTint(tint).opacity(0.12)))
        .help("Required — the discipline this expertise realizes.")
    }

    private func removableChip(_ abilityID: AbilityID) -> some View {
        let tint = model.snapshot.records
            .first { $0.package.ability.id == abilityID }?
            .package.ability.tint ?? ""
        return HStack(spacing: 4) {
            Text(abilityID.rawValue).font(.maryMono(10))
            Button {
                setSupporting(
                    ability.operatingPolicy.defaultSupportingAbilities
                        .filter { $0 != abilityID })
            } label: {
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Color.maryAbilityTint(tint))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.maryAbilityTint(tint).opacity(0.12)))
    }

    @ViewBuilder
    private func addSupportingMenu(_ supporting: [AbilityID]) -> some View {
        let taken = Set(supporting.map(\.rawValue))
            .union(package.extendedDisciplines.map(\.rawValue))
        let options = model.snapshot.records
            .filter {
                $0.package.ability.id != ability.id
                    && !taken.contains($0.package.ability.id.rawValue)
            }
        if !options.isEmpty {
            Menu {
                ForEach(options) { record in
                    Button(record.package.ability.title) {
                        add(record)
                    }
                }
            } label: {
                Text("add…")
                    .font(.maryMono(10))
                    .foregroundStyle(Color.maryInk.opacity(0.45))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(
                                Color.maryGold.opacity(0.45),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func add(_ record: AbilityPackageRecord) {
        let abilityID = record.package.ability.id
        model.mutateAuthoringDocument { document in
            try document.updateAbility { ability in
                if !ability.operatingPolicy.defaultSupportingAbilities.contains(abilityID) {
                    ability.operatingPolicy.defaultSupportingAbilities.append(abilityID)
                }
            }
            // Optional, not required: promoting one would change which
            // disciplines this expertise claims to extend.
            try document.declareSupportingDependency(on: record.package)
        }
    }

    private func setSupporting(_ next: [AbilityID]) {
        model.mutateDraftPackage {
            $0.ability.operatingPolicy.defaultSupportingAbilities = next
        }
    }

    // MARK: - Layout

    private func knob<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: .layer2) {
            StudioLabel(label)
                .frame(width: 78, alignment: .leading)
                .padding(.top, 4)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
