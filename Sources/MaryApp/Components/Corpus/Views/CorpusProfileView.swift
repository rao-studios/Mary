//
//  CorpusProfileView.swift
//  Mary
//
//  What Mary concluded, by tier — including the tiers that have no producer
//  yet, because an experiment surface that hides what it cannot see is the
//  wrong instrument.
//
//  A conflict between what you SAID and what your code SHOWS is rendered as
//  both, side by side. The assertion wins in the brief; the disagreement is
//  the most interesting row in the pane and resolving it away would throw out
//  the reason for keeping both.
//

import MaryAmbient
import MaryFoundation
import SwiftUI
import MaryRuntime

struct CorpusProfileView: View {

    @ObservedObject var vm: CorpusViewModel

    @State private var assertingScope: String?
    @State private var draftDimension: StyleDimension = .concurrencyPrimitive
    @State private var draftValue: StyleValue = .lockBox

    var body: some View {
        VStack(alignment: .leading, spacing: .layer4) {
            ForEach(vm.abilities) { ability in
                abilitySection(ability)
            }
        }
        .padding(.horizontal, .layer4)
    }

    /// ABILITY FIRST, application beneath. The pane used to lead with Xcode,
    /// which read as though the editor were the thing being learned about. It
    /// is not: Xcode appears because an Xcode plugin is in use, and the fact
    /// worth showing is the craft — with the plugin named as the reason it is
    /// on screen at all.
    private func abilitySection(_ ability: CorpusAbilitySection) -> some View {
        VStack(alignment: .leading, spacing: .layer2) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: .layer2) {
                    Text(ability.title)
                        .font(.marySans(13, weight: .semibold))
                    Text("ability · \(ability.ability.rawValue)")
                        .font(.marySans(9))
                        .foregroundStyle(Color.maryInk.opacity(0.35))
                }
                Text(ability.providedBy)
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.5))
            }

            if ability.isUnobserved {
                MaryCard {
                    Text("No producer learns this work yet.")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.35))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if ability.sections.isEmpty {
                MaryCard {
                    Text("Nothing concluded yet — Mary needs to read more of your work.")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(ability.sections) { tier in
                    tierSection(tier, ability: ability.ability)
                }
            }
        }
    }

    private func tierSection(_ tier: CorpusTierSection, ability: AbilityID) -> some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer2) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tier.title)
                        .font(.marySans(12, weight: .medium))
                    Text(tier.subtitle)
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.5))
                }

                if tier.rows.isEmpty {
                    Text("Nothing concluded yet — Mary needs to read more of your work.")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.4))
                } else {
                    ForEach(tier.rows) { row in
                        tenetRow(row)
                    }
                }

                assertControl(tier, ability: ability)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tenetRow(_ row: CorpusTenetRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: .layer2) {
                StatusDot(color: dotColor(row))
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.sentence ?? silentDescription(row.tenet))
                        .font(.marySans(11))
                        .foregroundStyle(
                            row.sentence == nil
                                ? Color.maryInk.opacity(0.4)
                                : Color.maryInk.opacity(0.85))
                    Text("\(row.tenet.dimension.rawValue) · \(row.evidence)")
                        .font(.maryMono(9))
                        .foregroundStyle(Color.maryInk.opacity(0.4))

                    if let observed = row.conflictsWith {
                        conflict(observed)
                    }
                }
                Spacer()
                controls(row)
            }
            Divider().opacity(0.4)
        }
    }

    /// The disagreement, stated rather than settled.
    private func conflict(_ observed: StyleTenet) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8))
                .foregroundStyle(Color.maryGold)
            Text("your code mostly does the opposite — \(observed.value.rawValue), \(observed.support) times")
                .font(.marySans(9))
                .foregroundStyle(Color.maryInk.opacity(0.55))
        }
        .padding(.top, 1)
    }

    private func controls(_ row: CorpusTenetRow) -> some View {
        HStack(spacing: 4) {
            if row.tenet.provenance.isAsserted {
                Button("Retract") { retract(row) }
                    .buttonStyle(.maryQuiet)
            } else if row.isVetoed {
                Button("Unmute") { liftVeto(row) }
                    .buttonStyle(.maryQuiet)
            } else if row.sentence != nil {
                Button("Mute") { veto(row) }
                    .buttonStyle(.maryQuiet)
            }
        }
    }

    /// The closed vocabulary, offered as two pickers. There is deliberately no
    /// free-text field: prose reaching a model is what the trust model
    /// forbids, and it would forbid it no less for having been typed here.
    private func assertControl(
        _ tier: CorpusTierSection, ability: AbilityID
    ) -> some View {
        VStack(alignment: .leading, spacing: .layer2) {
            if assertingScope == tier.id {
                HStack(spacing: .layer2) {
                    Picker("", selection: $draftDimension) {
                        // ONLY WHAT THIS CRAFT CAN ACTUALLY HAVE. Every
                        // dimension used to be offered on every tier, so a
                        // manuscript's card invited an assertion about Swift
                        // concurrency — a tenet nothing could ever corroborate
                        // or contradict.
                        ForEach(
                            CorpusViewModel.assertableDimensions(
                                for: ability, producers: vm.producers),
                            id: \.self
                        ) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                    Picker("", selection: $draftValue) {
                        ForEach(draftDimension.values, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }
                .font(.maryMono(10))
                HStack(spacing: .layer2) {
                    Button("Tell Mary") { assert(tier) }
                        .buttonStyle(.mary)
                    Button("Cancel") { assertingScope = nil }
                        .buttonStyle(.maryQuiet)
                }
            } else {
                Button("Tell Mary how you work…") {
                    assertingScope = tier.id
                    draftDimension = .concurrencyPrimitive
                    draftValue = .lockBox
                }
                .buttonStyle(.maryQuiet)
            }
        }
        .onChange(of: draftDimension) { _, dimension in
            // Keep the pair legal — a value from another dimension would be
            // refused by `isMeaningful` and silently do nothing.
            if let first = dimension.values.first, !dimension.accepts(draftValue) {
                draftValue = first
            }
        }
    }

    // MARK: - Presentation helpers

    private func dotColor(_ row: CorpusTenetRow) -> Color {
        if row.isVetoed { return Color.maryInk.opacity(0.2) }
        if row.tenet.provenance.isAsserted { return .maryGold }
        if row.sentence != nil { return .maryGreen }
        return Color.maryInk.opacity(0.25)
    }

    private func silentDescription(_ tenet: StyleTenet) -> String {
        if case .imported(let origin) = tenet.provenance {
            return "\(tenet.dimension.rawValue): held from \(origin), not acted on"
        }
        if !tenet.isMeaningful {
            return "\(tenet.dimension.rawValue): from a newer version of Mary"
        }
        return "\(tenet.dimension.rawValue): not settled enough to act on"
    }

    // MARK: - Actions

    private func assert(_ tier: CorpusTierSection) {
        guard let scope = scope(for: tier) else { return }
        let dimension = draftDimension
        let value = draftValue
        assertingScope = nil
        Task {
            let notice = await MaryRuntime.assertTenet(
                dimension: dimension, value: value, scope: scope)
            await MainActor.run { vm.notice = notice; vm.refresh() }
        }
    }

    /// The section carries its own scope now. Reconstructing one from the
    /// display id was only ever possible while a scope had nothing to
    /// reconstruct.
    private func scope(for tier: CorpusTierSection) -> StyleScope? { tier.scope }

    private func retract(_ row: CorpusTenetRow) {
        let key = row.tenet.tenetKey
        Task {
            let notice = await MaryRuntime.retractTenet(tenetKey: key)
            await MainActor.run { vm.notice = notice; vm.refresh() }
        }
    }

    private func veto(_ row: CorpusTenetRow) {
        let key = row.tenet.tenetKey
        Task {
            let notice = await MaryRuntime.vetoTenet(tenetKey: key)
            await MainActor.run { vm.notice = notice; vm.refresh() }
        }
    }

    private func liftVeto(_ row: CorpusTenetRow) {
        let key = row.tenet.tenetKey
        Task {
            let notice = await MaryRuntime.liftTenetVeto(tenetKey: key)
            await MainActor.run { vm.notice = notice; vm.refresh() }
        }
    }
}
