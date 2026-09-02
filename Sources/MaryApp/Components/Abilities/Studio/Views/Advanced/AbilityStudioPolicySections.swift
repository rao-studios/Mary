//
//  AbilityStudioPolicySections.swift
//  Mary
//
//  WHAT: Projections, routing rehearsals, operating-policy prose, eligibility.
//  IN:   Advanced drawer.
//  OUT:  mutateDraftPackage / addFixture.
//  PIN:  A fixture is the one lever that moves the skill embedding tier — the
//        Tune pane's phrases only reach the ability tier.
//

import MaryBrain
import SwiftUI

// MARK: - Totem projections

@MainActor
struct AbilityStudioProjectionsSection: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage

    var body: some View {
        if package.totemProjections.isEmpty {
            StudioNote("None. A projection decides which of a skill's fields Mary is allowed to remember afterwards.")
        }
        ForEach(Array(package.totemProjections.enumerated()), id: \.element.id) { index, projection in
            AbilityStudioDeclarationCard(identifier: projection.id.rawValue) {
                AbilityStudioFactLine(label: "Keeps", value: projection.purpose.rawValue)
                AbilityStudioFactLine(label: "For how long", value: persistence(projection))
                if !projection.skills.isEmpty {
                    AbilityStudioFactLine(
                        label: "From",
                        value: projection.skills.map(\.rawValue).joined(separator: ", "))
                }
                Toggle(isOn: Binding(
                    get: { projection.redactContent },
                    set: { next in
                        model.mutateDraftPackage {
                            $0.totemProjections[index].redactContent = next
                        }
                    })) {
                    Text("Redact the content itself")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.7))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Color.maryGold)
            }
        }
    }

    private func persistence(_ projection: TotemProjectionSchema) -> String {
        switch projection.persistence {
        case .none: return "not kept"
        case .session: return "this session"
        case .durable:
            guard let seconds = projection.retentionSeconds else { return "kept" }
            return "kept for \(Int(seconds / 86_400)) days"
        }
    }
}

// MARK: - Fixtures

@MainActor
struct AbilityStudioFixturesSection: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage

    @State private var pending = ""

    var body: some View {
        StudioNote(
            "Whole sentences this ability should answer. They are also the only lever that moves how Mary matches a SKILL — an ability's phrases reach the ability tier only.")

        ForEach(Array(package.fixtures.enumerated()), id: \.element.id) { index, fixture in
            AbilityStudioDeclarationCard(identifier: fixture.id) {
                Button {
                    model.mutateDraftPackage { $0.fixtures.remove(at: index) }
                } label: {
                    EmptyView()
                }
                .hidden()
                .frame(width: 0, height: 0)

                Text("“\(fixture.utterance)”")
                    .font(.marySerif(11, italic: true))
                    .foregroundStyle(Color.maryInk.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: .layer2) {
                    if let skill = fixture.expectedSkill {
                        AbilityStudioFactLine(label: "Should reach", value: skill.rawValue)
                    } else {
                        AbilityStudioFactLine(label: "Should", value: fixture.expectedDisposition)
                    }
                }
                Button("Remove") {
                    model.mutateDraftPackage { $0.fixtures.remove(at: index) }
                }
                .buttonStyle(.plain)
                .font(.marySans(9.5))
                .foregroundStyle(Color.maryInk.opacity(0.4))
            }
        }

        HStack(spacing: .layer2) {
            StudioField(
                value: pending,
                placeholder: "something someone would say…"
            ) { pending = $0 }
            Button("Add", action: add)
                .buttonStyle(.maryQuiet)
                .font(.marySans(10))
                .disabled(pending.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(pending.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
        }
    }

    private func add() {
        let utterance = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty else { return }
        let accepted = model.mutateAuthoringDocument { document in
            // A fixture without an expected skill still widens ability recall.
            try document.addFixture(
                utterance: utterance,
                expectedSkill: model.selectedRecipe?.id)
        }
        if accepted { pending = "" }
    }
}

// MARK: - Operating policy

@MainActor
struct AbilityStudioOperatingPolicySection: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage

    private var policy: AbilityOperatingPolicy { package.ability.operatingPolicy }

    var body: some View {
        // "Notes" would read as an application name to the doctrine test that
        // keeps app names out of Swift; say it another way.
        StudioNote("Written for whoever reads this package later. Mary's own behaviour comes from the guardrail chips in Tune, not from this prose.")
        StudioStringListEditor(
            label: "Phases",
            values: policy.phases,
            placeholder: "resolve-workspace"
        ) { next in
            model.mutateDraftPackage { $0.ability.operatingPolicy.phases = next }
        }
        StudioStringListEditor(
            label: "Guardrails",
            values: policy.guardrails,
            placeholder: "never…"
        ) { next in
            model.mutateDraftPackage { $0.ability.operatingPolicy.guardrails = next }
        }
        StudioStringListEditor(
            label: "Signs it worked",
            values: policy.successSignals,
            placeholder: "the transport reports the requested state"
        ) { next in
            model.mutateDraftPackage { $0.ability.operatingPolicy.successSignals = next }
        }
        StudioStringListEditor(
            label: "Stop when",
            values: policy.stopConditions,
            placeholder: "user stop"
        ) { next in
            model.mutateDraftPackage { $0.ability.operatingPolicy.stopConditions = next }
        }
    }
}

// MARK: - Eligibility

@MainActor
struct AbilityStudioEligibilitySection: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage

    /// One line of a flattened predicate tree. Flattened rather than rendered
    /// recursively: a recursive `some View` cannot infer its own type.
    private struct Line: Identifiable {
        let id: Int
        let depth: Int
        let kind: String
        let value: String?
    }

    var body: some View {
        StudioNote("A rule Mary checks before this ability may answer at all. Empty means it is always eligible and routing decides on evidence.")
        if let predicate = package.ability.routing.eligibility {
            ForEach(Self.flatten(predicate)) { line in
                HStack(spacing: 5) {
                    Text(line.kind)
                        .font(.maryMono(9.5))
                        .foregroundStyle(Color.maryGold)
                    if let value = line.value {
                        Text(value)
                            .font(.maryMono(9.5))
                            .foregroundStyle(Color.maryInk.opacity(0.7))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(line.depth) * 10)
            }
            Button("Remove the rule") {
                model.mutateDraftPackage { $0.ability.routing.eligibility = nil }
            }
            .buttonStyle(.plain)
            .font(.marySans(9.5))
            .foregroundStyle(Color.maryInk.opacity(0.4))
        } else {
            Text("Always eligible.")
                .font(.marySans(10.5))
                .foregroundStyle(Color.maryInk.opacity(0.55))
        }
    }

    /// Read-only: the predicate language is a closed tree, and editing one in a
    /// sidebar invites a broken rule. The raw schema is the way in.
    private static func flatten(_ predicate: RoutingPredicate) -> [Line] {
        var lines: [Line] = []
        var next = 0
        func walk(_ node: RoutingPredicate, depth: Int) {
            lines.append(Line(id: next, depth: depth, kind: node.kind.rawValue, value: node.value))
            next += 1
            for child in node.children { walk(child, depth: depth + 1) }
        }
        walk(predicate, depth: 0)
        return lines
    }
}

// MARK: - Corpus

/// Read-only. A corpus describes an application's project shape on disk; it is
/// authored alongside the recipes that read it, not tuned in a sidebar.
struct AbilityStudioCorpusSection: View {
    let package: MaryAbilityPackage

    private var corpus: PluginCorpusSchema? {
        package.corpus ?? package.plugin?.corpus
    }

    var body: some View {
        if let corpus {
            AbilityStudioFactLine(label: "Notation", value: corpus.notation)
            if !corpus.include.isEmpty {
                AbilityStudioFactLine(
                    label: "Reads",
                    value: corpus.include.map { ".\($0)" }.joined(separator: ", "))
            }
            if !corpus.exclude.isEmpty {
                AbilityStudioFactLine(
                    label: "Skips",
                    value: corpus.exclude.joined(separator: ", "))
            }
            if !corpus.projectMarkers.isEmpty {
                AbilityStudioFactLine(
                    label: "Root is",
                    value: corpus.projectMarkers.joined(separator: ", "))
            }
            AbilityStudioFactLine(
                label: "At most",
                value: "\(corpus.budgets.maximumFiles) files · \(corpus.budgets.maximumEdges) links")
            StudioNote("A sixty-file crawl is a worse answer than eight, so the budget is part of the declaration.")
        }
    }
}
