import MaryBrain
import SwiftUI

// MARK: - Projection card

@MainActor
struct AbilityStudioProjectionCard: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage
    let projection: TotemProjectionSchema
    let index: Int

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    AbilityStudioTextField(
                        "Projection id",
                        path: path("id"),
                        text: Binding(
                            get: { projection.id.rawValue },
                            set: { value in rename(ProjectionID(value)) }),
                        monospaced: true)
                    Picker("Purpose", selection: Binding(
                        get: { projection.purpose },
                        set: { value in mutate { $0.purpose = value } })) {
                        ForEach(TotemProjectionPurpose.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Persistence", selection: Binding(
                        get: { projection.persistence },
                        set: { value in mutate { $0.persistence = value } })) {
                        ForEach(ProjectionPersistence.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                AbilityStudioTagEditor(
                    title: "Skills (empty means every Skill)",
                    path: path("skills"),
                    values: projection.skills.map(\.rawValue)) { values in
                    mutate { $0.skills = values.map(SkillID.init) }
                }
                HStack {
                    Toggle("Redact content", isOn: Binding(
                        get: { projection.redactContent },
                        set: { value in mutate { $0.redactContent = value } }))
                    AbilityStudioTextField(
                        "Retention seconds (optional)",
                        path: path("retentionSeconds"),
                        text: Binding(
                            get: { projection.retentionSeconds.map { String($0) } ?? "" },
                            set: { value in mutate { $0.retentionSeconds = Double(value) } }),
                        monospaced: true)
                }
                HStack {
                    AbilityStudioTagEditor(
                        title: "Include fields",
                        path: path("include"),
                        values: projection.include) { values in mutate { $0.include = values } }
                    AbilityStudioTagEditor(
                        title: "Exclude fields",
                        path: path("exclude"),
                        values: projection.exclude) { values in mutate { $0.exclude = values } }
                }
                HStack {
                    Spacer()
                    Button("Remove Projection", role: .destructive, action: remove)
                }
            }
            .padding(.top, 9)
        } label: {
            HStack {
                Image(systemName: "archivebox")
                Text(projection.id.rawValue).font(.callout.monospaced())
                Spacer()
                Text("\(projection.purpose.rawValue) · \(projection.persistence.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
    }

    private func rename(_ next: ProjectionID) {
        model.mutateDraftPackage { draft in
            guard draft.totemProjections.indices.contains(index) else { return }
            let previous = draft.totemProjections[index].id
            draft.totemProjections[index].id = next
            draft.ability.totemProjections = draft.ability.totemProjections.map {
                $0 == previous ? next : $0
            }
            for interactionIndex in draft.interactions.indices
            where draft.interactions[interactionIndex].totemProjection == previous {
                draft.interactions[interactionIndex].totemProjection = next
            }
        }
    }

    private func remove() {
        model.mutateDraftPackage { draft in
            guard draft.totemProjections.indices.contains(index) else { return }
            let id = draft.totemProjections[index].id
            draft.totemProjections.remove(at: index)
            draft.ability.totemProjections.removeAll { $0 == id }
            for interactionIndex in draft.interactions.indices
            where draft.interactions[interactionIndex].totemProjection == id {
                draft.interactions[interactionIndex].totemProjection = nil
            }
        }
    }

    private func mutate(_ change: (inout TotemProjectionSchema) -> Void) {
        model.mutateDraftPackage { draft in
            guard draft.totemProjections.indices.contains(index) else { return }
            change(&draft.totemProjections[index])
        }
    }

    private func path(_ tail: String) -> String { "totemProjections[\(index)].\(tail)" }
}
