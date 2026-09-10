//
//  CorpusSchemaView.swift
//  Mary
//
//  WHAT: Behavioural schema by Ability (schema → Ability → application).
//  OUT:  visual grouping + raw export bytes (same tenets).
//

import AppKit
import MaryAmbient
import MaryFoundation
import SwiftUI

struct CorpusSchemaView: View {

    @ObservedObject var vm: CorpusViewModel
    @Binding var showsRaw: Bool
    @Binding var selectedSubject: String?

    var body: some View {
        VStack(alignment: .leading, spacing: .layer3) {
            if showsRaw {
                rawView
            } else {
                visualView
            }
        }
        .padding(.horizontal, .layer4)
    }

    // MARK: - Visual

    private var visualView: some View {
        VStack(alignment: .leading, spacing: .layer3) {
            ForEach(vm.abilities) { ability in
                abilityCard(ability)
            }
        }
    }

    private func abilityCard(_ ability: CorpusAbilitySection) -> some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer2) {
                HStack(alignment: .firstTextBaseline, spacing: .layer2) {
                    Text(ability.title.uppercased())
                        .font(.marySans(11, weight: .medium))
                        .tracking(0.8)
                    Spacer()
                    Text("ability · \(ability.ability.rawValue)")
                        .font(.maryMono(9))
                        .foregroundStyle(Color.maryInk.opacity(0.35))
                }

                if ability.isUnobserved {
                    Text(ability.providedBy)
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                    Text("Nothing watches this work yet.")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.35))
                } else {
                    ForEach(ability.sections) { section in
                        rung(section)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rung(_ section: CorpusTierSection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: .layer2) {
                Text(section.title)
                    .font(.marySans(11, weight: .medium))
                Spacer()
                Text(rungLabel(section))
                    .font(.maryMono(9))
                    .foregroundStyle(Color.maryInk.opacity(0.35))
            }
            Text(section.subtitle)
                .font(.marySans(9))
                .foregroundStyle(Color.maryInk.opacity(0.45))

            ForEach(section.rows) { row in
                HStack(alignment: .top, spacing: .layer2) {
                    StatusDot(color: dotColor(row))
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.sentence ?? "\(row.tenet.dimension.rawValue) — not acted on")
                            .font(.marySans(11))
                            .foregroundStyle(
                                row.sentence == nil
                                    ? Color.maryInk.opacity(0.4)
                                    : Color.maryInk.opacity(0.85))
                        Text(row.evidence)
                            .font(.maryMono(9))
                            .foregroundStyle(Color.maryInk.opacity(0.4))
                    }
                    Spacer()
                    Text(String(format: "%.2f", row.tenet.confidence))
                        .font(.maryMono(9))
                        .foregroundStyle(Color.maryInk.opacity(0.4))
                }
            }
            Divider().opacity(0.35)
        }
        .padding(.leading, .layer2)
    }

    private func rungLabel(_ section: CorpusTierSection) -> String {
        guard let scope = section.scope else { return "" }
        return "\(scope.kind.rawValue) · \(section.rows.count)"
    }

    private func dotColor(_ row: CorpusTenetRow) -> Color {
        if row.isVetoed { return Color.maryInk.opacity(0.2) }
        if row.tenet.provenance.isAsserted { return .maryGold }
        if row.sentence != nil { return .maryGreen }
        return Color.maryInk.opacity(0.25)
    }

    // MARK: - Raw

    private var rawView: some View {
        VStack(alignment: .leading, spacing: .layer2) {
            if vm.rawProfiles.isEmpty {
                Text("No profile yet. Mary writes one per application once she has read some of your work.")
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.5))
                    .padding(.top, .layer4)
            } else {
                if vm.rawProfiles.count > 1 {
                    FlowLayout(spacing: .layer1) {
                        ForEach(vm.rawProfiles) { profile in
                            MaryChip(
                                label: profile.title,
                                isOn: current?.subject == profile.subject,
                                action: { selectedSubject = profile.subject })
                        }
                    }
                }
                if let profile = current {
                    profileCard(profile)
                }
            }
        }
    }

    private var current: CorpusRawProfile? {
        vm.rawProfiles.first { $0.subject == selectedSubject } ?? vm.rawProfiles.first
    }

    private func profileCard(_ profile: CorpusRawProfile) -> some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer2) {
                HStack(spacing: .layer2) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(profile.title) · \(profile.tenetCount) tenets")
                            .font(.marySans(11, weight: .medium))
                        // The claim worth making: this IS the artifact.
                        Text("The same bytes an export writes, digest included.")
                            .font(.marySans(9))
                            .foregroundStyle(Color.maryInk.opacity(0.45))
                    }
                    Spacer()
                    Button {
                        copy(profile)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy profile JSON")
                }

                if let digest = profile.digest {
                    Text("sha256 \(digest.prefix(16))…")
                        .font(.maryMono(9))
                        .foregroundStyle(Color.maryInk.opacity(0.35))
                }

                Text(profile.json)
                    .font(.maryMono(10))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.layer2)
                    .background(Color.maryInk.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copy(_ profile: CorpusRawProfile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(profile.json, forType: .string)
        vm.notice = "Copied \(profile.title)'s profile — save it as .marystyle to keep it."
    }
}
