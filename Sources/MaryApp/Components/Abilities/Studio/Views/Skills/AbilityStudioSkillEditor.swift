//
//  AbilityStudioSkillEditor.swift
//  Mary
//
//  WHAT: Edit a skill this package owns — what it is called, what it asks for,
//        how much rope it gets.
//  IN:   AbilityStudioSkillDetail, for own skills only.
//  OUT:  updateSkill through the authoring document; kind via transitionSkillKind.
//  PIN:  A step is a skill usage; the skill is edited here, not on the row. A
//        skill another package owns is not this one's to change — the detail
//        offers "Open <owner>" instead.
//

import MaryBrain
import SwiftUI

@MainActor
struct AbilityStudioSkillEditor: View {
    @ObservedObject var model: AbilityStudioViewModel
    let skill: SkillSchema
    let package: MaryAbilityPackage

    @State private var showsNewParameter = false
    @State private var newParameterName = ""
    @State private var newParameterType = "string"
    @State private var newParameterRequired = true
    @State private var newParameterComposed = false

    private var isRecipe: Bool { skill.execution.kind == .stateMachine }

    /// A contract imported from an installed faculty is provenance, not
    /// something this package may reshape.
    private var isPinned: Bool {
        AbilityStudioEditorIntegrity.hasExternalInstalledFacultyContract(
            skill, in: package, snapshot: model.snapshot)
    }

    private static let parameterTypes = ["string", "boolean", "number", "integer"]

    var body: some View {
        VStack(alignment: .leading, spacing: .layer3) {
            Divider().overlay(Color.maryBorder)

            if isPinned {
                StudioNote("This skill's contract comes from an installed faculty, so its shape is not this ability's to change. Its title and summary are.")
            }

            HStack(alignment: .top, spacing: .layer3) {
                StudioField("Called", value: skill.title) { next in
                    let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    update { $0.title = trimmed }
                }
                .id("\(skill.id.rawValue)/title")
                invocationField
            }

            StudioTextArea("Summary", value: skill.summary, minHeight: 40) { next in
                update { $0.summary = next.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            .id("\(skill.id.rawValue)/summary")

            HStack(spacing: .layer4) {
                if !isRecipe, !isPinned { kindMenu }
                accessMenu
                stageToggle
                if isRecipe { timeoutField }
            }

            parameters
        }
    }

    // MARK: - Identity

    /// The name the model calls this by. Checked against the closed grammar and
    /// against the registry, because snapshot lookup is first-wins and a
    /// duplicate would silently shadow an installed skill.
    private var invocationField: some View {
        let current = skill.modelExposure.invocationName ?? ""
        let shadows = model.reservedInvocations.contains(current)
        return VStack(alignment: .leading, spacing: .layer1) {
            StudioField(
                "Asked for as",
                value: current,
                placeholder: "snake_case_name",
                mono: true,
                isEditable: !isPinned
            ) { next in
                let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
                guard AbilityStudioInvocationName.isValid(trimmed),
                      !AbilityStudioInvocationName.isReserved(trimmed)
                else {
                    model.status = "\(trimmed) is not a callable name — lower-case words joined by underscores."
                    return
                }
                update { $0.modelExposure.invocationName = trimmed }
            }
            .id("\(skill.id.rawValue)/invocation")
            if shadows {
                HStack(spacing: 4) {
                    MaryBadge(text: "shadows", color: .maryGold)
                    StudioNote("An installed skill already answers to this name; whichever is registered first wins.")
                }
            }
        }
    }

    // MARK: - Kind, access, stage, timeout

    private var kindMenu: some View {
        StudioMenuPicker(
            label: "It",
            value: skill.kind,
            options: AbilityStudioEditorIntegrity.visuallyAuthorableKinds(for: skill)
                .filter {
                    AbilityStudioEditorIntegrity.canTransitionSkillKind(
                        in: package, skillID: skill.id, to: $0)
                },
            title: AbilityStudioLabels.kindWord
        ) { next in
            // A kind change reshapes execution, so it goes through the cascade
            // and the graph validator, not the fast path.
            model.mutateValidatedEditorPackage { draft in
                try AbilityStudioEditorIntegrity.transitionSkillKind(
                    in: &draft, skillID: skill.id, to: next)
            }
        }
    }

    /// A recipe may not stop to ask — the runtime refuses to cross a
    /// confirmation boundary mid-workflow — so that option is not offered.
    private var accessMenu: some View {
        StudioMenuPicker(
            label: "And it",
            value: skill.access,
            options: isRecipe ? [.seamless, .reversible] : SkillAccess.allCases,
            title: AbilityStudioLabels.accessWord
        ) { next in
            update { $0.access = next }
        }
    }

    private var stageToggle: some View {
        Toggle(isOn: Binding(
            get: { skill.usesStage },
            set: { next in update { $0.usesStage = next } })) {
            Text("owns the stage")
                .font(.marySans(10.5))
                .foregroundStyle(Color.maryInk.opacity(0.7))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Color.maryGold)
        .help("Whether Mary must hold the focused application for this to run.")
    }

    private var timeoutField: some View {
        HStack(spacing: .layer2) {
            StudioLabel("Gives up after")
            StudioField(
                value: AbilityStudioDoubleField.text(skill.timeoutSeconds ?? 60),
                mono: true
            ) { next in
                guard let seconds = Double(next.trimmingCharacters(in: .whitespaces)) else { return }
                update { $0.timeoutSeconds = min(max(seconds, 5), 600) }
            }
            .frame(width: 54)
            .id("\(skill.id.rawValue)/timeout")
            Text("s")
                .font(.marySans(10))
                .foregroundStyle(Color.maryInk.opacity(0.45))
        }
    }

    // MARK: - Parameters

    /// What the model must supply when it asks for this skill. For a binding
    /// skill these mirror the operation's inputs and are kept in step by
    /// `synchronizeLocalModelContract`; for a recipe they are its own.
    private var parameters: some View {
        VStack(alignment: .leading, spacing: .layer2) {
            HStack(spacing: .layer2) {
                StudioLabel("Asks for")
                Spacer()
                if !isPinned {
                    StudioAddButton(title: "Parameter") {
                        newParameterName = ""
                        newParameterType = "string"
                        newParameterRequired = true
                        newParameterComposed = false
                        showsNewParameter = true
                    }
                }
            }
            if skill.modelExposure.parameters.isEmpty {
                StudioNote(isRecipe
                           ? "Nothing — this recipe runs on its own. Add a parameter when a step needs something said, like a playlist name."
                           : "Nothing.")
            } else {
                FlowLayout(spacing: .layer1) {
                    ForEach(skill.modelExposure.parameters, id: \.name) { parameter in
                        parameterChip(parameter)
                    }
                }
            }
        }
        .popover(isPresented: $showsNewParameter, arrowEdge: .bottom) {
            newParameterForm
        }
    }

    private func parameterChip(_ parameter: ModelParameterSchema) -> some View {
        HStack(spacing: 4) {
            Text(parameter.name)
                .font(.maryMono(10))
            Text("· \(parameter.type)")
                .font(.maryMono(9))
                .opacity(0.7)
            if parameter.required {
                Text("· required")
                    .font(.marySans(9))
                    .opacity(0.7)
            }
            if parameter.requiresComposition {
                Image(systemName: "brain")
                    .font(.system(size: 8))
                    .help("The model composes this rather than passing it through — it counts as a model call.")
            }
            if !isPinned {
                Button {
                    update { $0.modelExposure.parameters.removeAll { $0.name == parameter.name } }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
                .opacity(0.55)
            }
        }
        .foregroundStyle(Color.maryInk.opacity(0.75))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.maryInk.opacity(0.06)))
        .help(parameter.summary)
    }

    private var newParameterForm: some View {
        let name = newParameterName.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = skill.modelExposure.parameters.contains { $0.name == name }
        let canAdd = AbilityStudioInvocationName.isValid(name) && !taken
        return VStack(alignment: .leading, spacing: .layer3) {
            Text("New parameter")
                .font(.marySerif(15, weight: .light, italic: true))
                .foregroundStyle(Color.maryInk)
            StudioField("Name", value: newParameterName, placeholder: "playlist", mono: true, live: true) {
                newParameterName = $0
            }
            StudioMenuPicker(
                label: "Type",
                value: newParameterType,
                options: Self.parameterTypes,
                title: { $0 }
            ) { newParameterType = $0 }
            Toggle(isOn: $newParameterRequired) {
                Text("required").font(.marySans(10.5))
            }
            .toggleStyle(.switch).controlSize(.mini).tint(Color.maryGold)
            Toggle(isOn: $newParameterComposed) {
                Text("the model composes it").font(.marySans(10.5))
            }
            .toggleStyle(.switch).controlSize(.mini).tint(Color.maryGold)
            StudioNote("A composed parameter is written by the model rather than lifted from what was said. It counts as a model call.")
            if taken {
                StudioNote("Already a parameter of this skill.")
            }
            HStack {
                Spacer()
                Button("Cancel") { showsNewParameter = false }.buttonStyle(.maryQuiet)
                Button("Add") {
                    update {
                        $0.modelExposure.parameters.append(.init(
                            name: name,
                            type: newParameterType,
                            summary: "",
                            required: newParameterRequired,
                            enumValues: [],
                            requiresComposition: newParameterComposed))
                    }
                    showsNewParameter = false
                }
                .buttonStyle(.mary)
                .disabled(!canAdd)
                .opacity(canAdd ? 1 : 0.4)
            }
        }
        .padding(.layer4)
        .maryPopover()
        .background(Paper.page)
    }

    // MARK: - Write

    private func update(_ transform: @escaping (inout SkillSchema) -> Void) {
        model.mutateAuthoringDocument { document in
            try document.updateSkill(skill.id, transform)
        }
    }
}
