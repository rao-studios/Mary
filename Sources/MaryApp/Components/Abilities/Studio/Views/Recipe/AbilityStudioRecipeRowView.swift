//
//  AbilityStudioRecipeRowView.swift
//  Mary
//
//  WHAT: One recipe row — the skill it calls, whether it will run, its hands.
//  IN:   AbilityStudioRecipePane.
//  OUT:  addWorkflowStep / updateWorkflowStep / moveWorkflowStep / removeWorkflowStep
//  PIN:  The dot is the only warning a cross-package step gets before Save —
//        the validator does not check step targets across packages.
//

import MaryBrain
import SwiftUI

@MainActor
struct AbilityStudioRecipeRowView: View {
    @ObservedObject var model: AbilityStudioViewModel
    let row: AbilityStudioRecipeRow
    let recipeID: SkillID
    let catalog: AbilityStudioInvocationCatalog
    let isLast: Bool
    let canReorder: Bool
    @Binding var expandedStepID: String?

    @State private var typed: String = ""
    @State private var showsSuggestions = false
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var isExpanded: Bool { expandedStepID == row.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: .layer2) {
                Text("\(row.index + 1)")
                    .font(.maryMono(10))
                    .foregroundStyle(Color.maryInk.opacity(0.35))
                    .frame(width: 13, alignment: .trailing)

                StudioPill(isAlarmed: row.status.isAlarming) {
                    TextField("name a skill…", text: $typed)
                        .textFieldStyle(.plain)
                        .font(.maryMono(12))
                        .foregroundStyle(Color.maryInk)
                        .focused($focused)
                        .onSubmit(commit)
                        .onChange(of: typed) { _, _ in
                            showsSuggestions = focused && !typed.isEmpty
                        }
                        .onChange(of: focused) { _, isFocused in
                            if isFocused {
                                showsSuggestions = !typed.isEmpty
                            } else {
                                showsSuggestions = false
                                commit()
                            }
                        }

                    Spacer(minLength: .layer1)

                    if let ownerTitle = row.ownerTitle {
                        Button(action: revealSkill) {
                            StudioOwnerChip(
                                title: ownerTitle,
                                tint: Color.maryAbilityTint(row.ownerTint ?? "", fallback: .maryGold))
                        }
                        .buttonStyle(.plain)
                        .help(revealHelp)
                    }
                    glyphs
                    Circle()
                        .fill(row.status.color)
                        .frame(width: 8, height: 8)
                        .help(row.status.word)
                    if row.hands != nil {
                        Button {
                            expandedStepID = isExpanded ? nil : row.id
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Color.maryInk.opacity(0.4))
                                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        }
                        .buttonStyle(.plain)
                        .help("Show the steps that do this here")
                    }
                }

                rowActions
            }
            .popover(isPresented: $showsSuggestions, arrowEdge: .bottom) {
                suggestions
            }

            if row.status.isAlarming {
                Text(row.status.word)
                    .font(.marySans(9.5))
                    .foregroundStyle(Color.maryError.opacity(0.9))
                    .padding(.leading, 21)
                    .padding(.top, 3)
            }

            if isExpanded, let hands = row.hands {
                AbilityStudioHandsEditor(
                    model: model,
                    operationIndex: hands.operationIndex,
                    operation: hands.operation)
                .padding(.leading, 19)
                .padding(.top, .layer2)
            }
        }
        .onHover { hovering = $0 }
        .onAppear { typed = row.step.operation }
        .onChange(of: row.step.operation) { _, next in
            if !focused { typed = next }
        }
    }

    @ViewBuilder
    private var glyphs: some View {
        if row.target != nil {
            Image(systemName: row.kindSymbol)
                .font(.system(size: 9))
                .foregroundStyle(Color.maryInk.opacity(0.4))
            if let access = row.accessSymbol {
                Image(systemName: access)
                    .font(.system(size: 9))
                    .foregroundStyle(
                        access == "hand.raised.fill"
                            ? Color.maryError
                            : Color.maryInk.opacity(0.4))
            }
        }
    }

    /// Reordering and removal appear on hover so a resting recipe reads as a
    /// list of intentions rather than a toolbar.
    @ViewBuilder
    private var rowActions: some View {
        HStack(spacing: 2) {
            if hovering {
                if canReorder {
                    iconButton("chevron.up", help: "Move up", enabled: row.index > 0) {
                        move(to: row.index - 1)
                    }
                    iconButton("chevron.down", help: "Move down", enabled: !isLast) {
                        move(to: row.index + 1)
                    }
                }
                iconButton("minus.circle", help: "Remove this step", enabled: true) {
                    model.mutateAuthoringDocument { document in
                        try document.removeWorkflowStep(row.id, from: recipeID)
                    }
                }
            }
        }
        .frame(width: canReorder ? 54 : 20, alignment: .leading)
    }

    private func iconButton(
        _ symbol: String,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(Color.maryInk.opacity(enabled ? 0.35 : 0.12))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private var suggestions: some View {
        let matches = catalog.matches(typed)
        return VStack(alignment: .leading, spacing: 1) {
            if matches.isEmpty {
                Text("Nothing installed answers to that.")
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.5))
                    .padding(.horizontal, .layer2)
                    .padding(.vertical, .layer2)
            }
            ForEach(matches) { entry in
                suggestion(entry)
            }
        }
        .padding(5)
        .frame(width: 330)
        .background(Paper.page)
    }

    private func suggestion(_ entry: AbilityStudioInvocationCatalog.Entry) -> some View {
        Button {
            accept(entry)
        } label: {
            HStack(spacing: .layer2) {
                Text(entry.invocation)
                    .font(.maryMono(11))
                    .foregroundStyle(Color.maryInk)
                    .lineLimit(1)
                Spacer(minLength: .layer1)
                if !entry.isComposable {
                    MaryBadge(text: "asks first", color: .maryError)
                } else if entry.shadowsInstalled {
                    MaryBadge(text: "shadows", color: .maryGold)
                }
                StudioOwnerChip(
                    title: entry.ownerTitle,
                    tint: Color.maryAbilityTint(entry.ownerTint ?? "", fallback: .maryGold))
                if let readiness = entry.readiness {
                    Circle()
                        .fill(AbilityStudioLabels.readinessColor(readiness))
                        .frame(width: 6, height: 6)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .disabled(!entry.isComposable)
        .opacity(entry.isComposable ? 1 : 0.45)
        .help(entry.isComposable
              ? entry.summary
              : "A recipe cannot call a skill that stops to ask the user.")
    }

    // MARK: - To the skill

    /// A step is a usage; the skill is edited on the bench. This is the path
    /// from one to the other.
    private var revealHelp: String {
        switch row.target {
        case .draftSkill: return "Show this skill on the bench"
        case .installed(let runtime): return "Show \(runtime.ability.title)'s skill on the bench"
        case .primitive: return "One of Mary's own — nothing to edit"
        case nil: return "Nothing answers to this name yet"
        }
    }

    private func revealSkill() {
        switch row.target {
        case .draftSkill(let skill):
            model.selectedSkillID = skill.id
        case .installed(let runtime):
            model.selectedSkillID = runtime.skill.id
        case .primitive, nil:
            break
        }
    }

    // MARK: - Writes

    private func accept(_ entry: AbilityStudioInvocationCatalog.Entry) {
        typed = entry.invocation
        showsSuggestions = false
        focused = false
        commit()
    }

    private func commit() {
        let next = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard next != row.step.operation else { return }
        guard !next.isEmpty else {
            typed = row.step.operation
            return
        }
        // Reaching another package declares an optional dependency in the same
        // transaction, so the recipe still means something wherever it lands.
        let owner = model.ownerPackage(forInvocation: next)
        let accepted = model.mutateAuthoringDocument { document in
            try document.retargetWorkflowStep(
                row.id, in: recipeID, to: next, ownerPackage: owner)
        }
        if !accepted { typed = row.step.operation }
    }

    private func move(to destination: Int) {
        model.mutateAuthoringDocument { document in
            try document.moveWorkflowStep(row.id, in: recipeID, to: destination)
        }
    }
}
