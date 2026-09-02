//
//  AbilityStudioRecipeRowPresentation.swift
//  Mary
//
//  WHAT: One recipe row — what a step points at, and whether it will run.
//  IN:   Recipe pane, cost estimate.
//  OUT:  pure over (draft, snapshot); no writes.
//  PIN:  The dot mirrors SkillExecutionAvailabilityEvaluator.finalize. If the
//        draft and the saved verdict ever disagree, this file is wrong, not
//        the runtime.
//

import MaryBrain
import SwiftUI

struct AbilityStudioRecipeRow: Identifiable, Hashable {

    /// What the step's name resolves to. The draft wins over the registry: the
    /// registry still holds the last SAVED copy of this same package.
    enum Target: Hashable {
        case draftSkill(SkillSchema)
        case installed(AbilityRuntimeSkill)
        case primitive(WorkflowPrimitiveDescriptor)

        var kind: SkillKind? {
            switch self {
            case .draftSkill(let skill): return skill.kind
            case .installed(let runtime): return runtime.skill.kind
            case .primitive: return nil
            }
        }
    }

    enum Status: Hashable {
        /// Resolves and will run.
        case ready
        /// Resolves to a cognitive skill — this step asks the model.
        case modelCall
        /// Resolves, but the runtime cannot confirm it is ready right now.
        case partial(reason: String)
        /// Resolves and will be refused.
        case blocked(reason: String)
        /// No installed skill answers to this name.
        case unresolved
        /// View state: a row being typed, not yet committed.
        case pending

        var isAlarming: Bool {
            switch self {
            case .blocked, .unresolved: return true
            case .ready, .modelCall, .partial, .pending: return false
            }
        }

        var color: Color {
            switch self {
            case .ready: return .maryGreen
            case .modelCall, .partial: return .maryGold
            case .blocked, .unresolved: return .maryError
            case .pending: return Color.maryInk.opacity(0.25)
            }
        }

        /// Plain words, in the vocabulary the transcript already uses.
        var word: String {
            switch self {
            case .ready: return "ready"
            case .modelCall: return "asks the model"
            case .partial(let reason): return reason
            case .blocked(let reason): return reason
            case .unresolved: return "nothing answers to this name"
            case .pending: return "name a skill to add this step"
            }
        }
    }

    /// A local macUI operation realizing the step's skill — the row can open it.
    struct Hands: Hashable {
        let operation: String
        let operationIndex: Int
        let title: String
    }

    let id: String
    let index: Int
    let step: WorkflowStepSchema
    let target: Target?
    let ownerTitle: String?
    let ownerTint: String?
    let status: Status
    let hands: Hands?

    var invocation: String { step.operation }

    var accessSymbol: String? {
        switch target {
        case .draftSkill(let skill): return AbilityStudioLabels.accessSymbol(skill.access)
        case .installed(let runtime): return AbilityStudioLabels.accessSymbol(runtime.skill.access)
        case .primitive, nil: return nil
        }
    }

    var kindSymbol: String {
        switch target {
        case .draftSkill(let skill): return AbilityStudioLabels.kindSymbol(skill.kind)
        case .installed(let runtime): return AbilityStudioLabels.kindSymbol(runtime.skill.kind)
        case .primitive: return "brain"
        case nil: return "questionmark"
        }
    }
}

/// Resolves step names the way the runtime does, against the draft rather than
/// the saved package, so the pane can say what Save will conclude.
struct AbilityStudioRecipeResolver {
    /// The runtime refuses to nest workflows deeper than this.
    static let maximumDepth = 8

    private let draft: MaryAbilityPackage
    private let snapshot: AbilityRuntimeSnapshot
    private let primitives: [String: WorkflowPrimitiveDescriptor]
    private let draftByInvocation: [String: SkillSchema]

    init(draft: MaryAbilityPackage, snapshot: AbilityRuntimeSnapshot) {
        self.draft = draft
        self.snapshot = snapshot
        primitives = Dictionary(
            CognitivePrimitiveCatalog
                .workflowPrimitives(for: draft.ability.id)
                .map { ($0.operation, $0) },
            uniquingKeysWith: { first, _ in first })
        draftByInvocation = Dictionary(
            draft.skills.compactMap { skill in
                skill.modelExposure.invocationName.map { ($0, skill) }
            },
            uniquingKeysWith: { first, _ in first })
    }

    func target(for operation: String) -> AbilityStudioRecipeRow.Target? {
        if let skill = draftByInvocation[operation] {
            return .draftSkill(skill)
        }
        // The snapshot still carries the last saved copy of this same package;
        // the draft in hand is newer, so ignore it.
        if let runtime = snapshot.skill(invocationName: operation),
           runtime.packageID != draft.package.id {
            return .installed(runtime)
        }
        if let primitive = primitives[operation] {
            return .primitive(primitive)
        }
        return nil
    }

    func rows(for recipe: SkillSchema) -> [AbilityStudioRecipeRow] {
        recipe.execution.steps.enumerated().map { index, step in
            row(step: step, index: index, recipe: recipe)
        }
    }

    func row(
        step: WorkflowStepSchema,
        index: Int,
        recipe: SkillSchema
    ) -> AbilityStudioRecipeRow {
        let resolved = target(for: step.operation)
        return AbilityStudioRecipeRow(
            id: step.id,
            index: index,
            step: step,
            target: resolved,
            ownerTitle: ownerTitle(resolved),
            ownerTint: ownerTint(resolved),
            status: status(for: step, target: resolved, recipe: recipe),
            hands: hands(for: resolved))
    }

    // MARK: - Status

    private func status(
        for step: WorkflowStepSchema,
        target: AbilityStudioRecipeRow.Target?,
        recipe: SkillSchema
    ) -> AbilityStudioRecipeRow.Status {
        guard !step.operation.isEmpty else { return .pending }
        if AbilityStudioInvocationName.isReserved(step.operation) {
            return .blocked(reason: "\(step.operation) belongs to Mary and cannot be composed")
        }
        guard let target else { return .unresolved }

        switch target {
        case .primitive:
            // Workflow-only primitives are deterministic transformations, not
            // model calls, and are always available to their own ability.
            return .ready

        case .installed(let runtime):
            if runtime.skill.access == .confirm {
                return .blocked(reason: "asks the user first, which a recipe cannot do")
            }
            if runtime.skill.kind == .cognitive { return .modelCall }
            switch runtime.availability.readiness {
            case .ready: return .ready
            case .partial:
                return .partial(reason: runtime.availability.reasons.first ?? "not ready right now")
            case .blocked:
                return .blocked(reason: runtime.availability.reasons.first ?? "cannot run right now")
            }

        case .draftSkill(let skill):
            if skill.id == recipe.id {
                return .blocked(reason: "this recipe calls itself")
            }
            if skill.access == .confirm {
                return .blocked(reason: "asks the user first, which a recipe cannot do")
            }
            switch skill.execution.kind {
            case .cognitive:
                return .modelCall
            case .stateMachine:
                return nestedStatus(skill, from: recipe)
            case .binding:
                return draftBindingStatus(skill)
            }
        }
    }

    /// A recipe naming another recipe. Depth and cycles are the runtime's two
    /// refusals, so they are checked here rather than discovered on Save.
    private func nestedStatus(
        _ skill: SkillSchema,
        from recipe: SkillSchema
    ) -> AbilityStudioRecipeRow.Status {
        var visited: Set<SkillID> = [recipe.id]
        var frontier = [(skill: skill, depth: 1)]
        while let current = frontier.popLast() {
            if current.depth > Self.maximumDepth {
                return .blocked(reason: "recipes nest more than \(Self.maximumDepth) deep")
            }
            guard visited.insert(current.skill.id).inserted else {
                return .blocked(reason: "these recipes call each other in a loop")
            }
            for step in current.skill.execution.steps {
                guard case .draftSkill(let next)? = target(for: step.operation) else { continue }
                if next.id == recipe.id {
                    return .blocked(reason: "these recipes call each other in a loop")
                }
                if next.execution.kind == .stateMachine {
                    frontier.append((skill: next, depth: current.depth + 1))
                }
            }
        }
        return .ready
    }

    /// A binding skill in the draft has no runtime verdict yet — it has never
    /// been saved. Its own package's hands are the evidence available.
    private func draftBindingStatus(_ skill: SkillSchema) -> AbilityStudioRecipeRow.Status {
        if let realization = draft.plugin?.realizations.first(where: { $0.skillID == skill.id }) {
            guard let plugin = draft.plugin,
                  let operation = plugin.operations.first(where: {
                      $0.operation == realization.operation
                  }),
                  let adapter = plugin.adapter(for: operation)
            else {
                return .blocked(reason: "its hands are missing")
            }
            let manifest = snapshot.adapterManifest(id: adapter.id)
            if let manifest, !manifest.isAvailable {
                return .partial(reason: manifest.unavailableReason ?? "its application is not available")
            }
            return .ready
        }
        // Not realized here: fall back to whatever the registry knows.
        if let runtime = snapshot.skill(id: skill.id) {
            switch runtime.availability.readiness {
            case .ready: return .ready
            case .partial:
                return .partial(reason: runtime.availability.reasons.first ?? "not ready right now")
            case .blocked:
                return .blocked(reason: runtime.availability.reasons.first ?? "cannot run right now")
            }
        }
        if skill.execution.realizationPolicy == .pluginRealizations {
            return .blocked(reason: "no hands have been given to this skill yet")
        }
        return .partial(reason: "unsaved — its provider is confirmed on save")
    }

    // MARK: - Attribution

    private func ownerTitle(_ target: AbilityStudioRecipeRow.Target?) -> String? {
        switch target {
        case .draftSkill: return draft.ability.title
        case .installed(let runtime): return runtime.ability.title
        case .primitive: return "Mary"
        case nil: return nil
        }
    }

    private func ownerTint(_ target: AbilityStudioRecipeRow.Target?) -> String? {
        switch target {
        case .draftSkill: return draft.ability.tint
        case .installed(let runtime): return runtime.ability.tint
        case .primitive, nil: return nil
        }
    }

    /// The package's own macUI operation realizing this step's skill, if any.
    /// Looked up by realization rather than by name: a dependency's skill can be
    /// realized here under a differently named local operation.
    private func hands(for target: AbilityStudioRecipeRow.Target?) -> AbilityStudioRecipeRow.Hands? {
        let skillID: SkillID
        switch target {
        case .draftSkill(let skill): skillID = skill.id
        case .installed(let runtime): skillID = runtime.skill.id
        case .primitive, nil: return nil
        }
        guard let plugin = draft.plugin,
              let realization = plugin.realizations.first(where: { $0.skillID == skillID }),
              let index = plugin.operations.firstIndex(where: {
                  $0.operation == realization.operation
              }),
              plugin.adapter(for: plugin.operations[index])?.engine == .macUI
        else { return nil }
        return .init(
            operation: realization.operation,
            operationIndex: index,
            title: plugin.operations[index].title)
    }
}
