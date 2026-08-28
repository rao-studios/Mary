import MaryBrain
import SwiftUI

// MARK: - Routing fixture card

@MainActor
struct AbilityStudioFixtureCard: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage
    let fixture: AbilityFixture
    let index: Int

    private let commonDispositions = ["route", "ask-user", "abstain"]

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    AbilityStudioTextField(
                        "Fixture id",
                        path: path("id"),
                        text: Binding(
                            get: { fixture.id },
                            set: { value in mutate { $0.id = value } }),
                        monospaced: true)
                    Picker("Expected result", selection: Binding(
                        get: { fixture.expectedDisposition },
                        set: { value in mutate { $0.expectedDisposition = value } })) {
                        ForEach(dispositions, id: \.self) { disposition in
                            Text(disposition).tag(disposition)
                        }
                    }
                    .frame(width: 180)
                }
                AbilityStudioTextArea(
                    "What might the person say?",
                    path: path("utterance"),
                    text: Binding(
                        get: { fixture.utterance },
                        set: { value in mutate { $0.utterance = value } }))
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Picker("Expected Skill", selection: Binding(
                        get: { fixture.expectedSkill },
                        set: { value in mutate { $0.expectedSkill = value } })) {
                        Text("No Skill (negative example)")
                            .tag(Optional<SkillID>.none)
                        ForEach(package.skills, id: \.id) { skill in
                            Text(skill.title).tag(Optional(skill.id))
                        }
                        if let expectedSkill = fixture.expectedSkill,
                           !package.skills.contains(where: { $0.id == expectedSkill }) {
                            Text(expectedSkill.rawValue).tag(Optional(expectedSkill))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    AbilityStudioTextField(
                        "Target class (optional)",
                        path: path("targetClass"),
                        text: Binding(
                            get: { fixture.targetClass ?? "" },
                            set: { value in
                                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                mutate {
                                    $0.targetClass = trimmed.isEmpty ? nil : trimmed
                                }
                            }),
                        monospaced: true)
                }
                AbilityStudioTagEditor(
                    title: "Required interactions",
                    path: path("interactions"),
                    values: fixture.interactions.map(\.rawValue)) { values in
                    mutate { $0.interactions = values.map(InteractionID.init) }
                }
                HStack {
                    Spacer()
                    Button("Remove Test", role: .destructive) {
                        model.mutateDraftPackage { draft in
                            guard draft.fixtures.indices.contains(index) else { return }
                            draft.fixtures.remove(at: index)
                        }
                    }
                }
            }
            .padding(.top, 9)
        } label: {
            HStack {
                Image(systemName: fixture.expectedDisposition == "route"
                      ? "checkmark.circle" : "nosign")
                Text(fixture.utterance)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(fixture.expectedDisposition)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
    }

    private var dispositions: [String] {
        commonDispositions.contains(fixture.expectedDisposition)
            ? commonDispositions
            : commonDispositions + [fixture.expectedDisposition]
    }

    private func mutate(_ change: (inout AbilityFixture) -> Void) {
        model.mutateDraftPackage { draft in
            guard draft.fixtures.indices.contains(index) else { return }
            change(&draft.fixtures[index])
        }
    }

    private func path(_ tail: String) -> String { "fixtures[\(index)].\(tail)" }
}
