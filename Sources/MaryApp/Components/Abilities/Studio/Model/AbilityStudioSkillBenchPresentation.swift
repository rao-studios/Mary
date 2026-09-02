//
//  AbilityStudioSkillBenchPresentation.swift
//  Mary
//
//  WHAT: What this ability can do, grouped by the ability that defines each skill.
//  IN:   Skills pane.
//  OUT:  pure over (draft, snapshot).
//  PIN:  An expertise usually owns no skills of its own — it realizes a
//        discipline's. The bench exists to make that visible rather than to
//        list what the file happens to contain.
//

import MaryBrain
import SwiftUI

struct AbilityStudioSkillTile: Identifiable, Hashable {

    /// Whose skill this is, from this package's point of view.
    enum Origin: Hashable {
        case own
        /// A discipline this expertise realizes — a required dependency.
        case extendedDiscipline(PackageID)
        /// An optional dependency, on hand when the route needs it.
        case supporting(PackageID)
    }

    /// Who actually carries it out.
    enum Realization: Hashable {
        /// This package's own macUI recipe realizes it.
        case localHands(operation: String)
        /// A compiled faculty, or another package's hands.
        case provider(title: String)
        /// A portable contract with no provider yet.
        case none
        /// Cognitive skills and recipes have nothing to bind.
        case notApplicable

        var word: String {
            switch self {
            case .localHands: return "hands here"
            case .provider(let title): return title
            case .none: return "no hands yet"
            case .notApplicable: return ""
            }
        }
    }

    let id: SkillID
    let title: String
    let summary: String
    let invocation: String?
    let kind: SkillKind
    let access: SkillAccess
    let ownerAbilityID: AbilityID
    let ownerTitle: String
    let ownerTint: String
    let origin: Origin
    let readiness: SkillReadiness?
    let realization: Realization
    let isRecipe: Bool
    /// Recipes in this draft that name it. Drives the bench↔recipe highlight.
    let usedByRecipes: [SkillID]

    var isUsedBySelectedRecipe: Bool { !usedByRecipes.isEmpty }

    /// A recipe may not call something that stops to ask the user.
    var isComposable: Bool { access != .confirm }
}

struct AbilityStudioSkillLane: Identifiable, Hashable {
    let abilityID: AbilityID
    let title: String
    let tint: String
    let note: String?
    let tiles: [AbilityStudioSkillTile]
    var isCollapsedByDefault: Bool = false

    var id: AbilityID { abilityID }
}

struct AbilityStudioSkillBench {
    let lanes: [AbilityStudioSkillLane]

    var isEmpty: Bool { lanes.allSatisfy(\.tiles.isEmpty) }

    init(
        draft: MaryAbilityPackage,
        snapshot: AbilityRuntimeSnapshot,
        selectedRecipe: SkillSchema?
    ) {
        let usedInvocations = Set(selectedRecipe?.execution.steps.map(\.operation) ?? [])
        let realizationsBySkill = Dictionary(
            (draft.plugin?.realizations ?? []).map { ($0.skillID, $0.operation) },
            uniquingKeysWith: { first, _ in first })

        func usedBy(_ invocation: String?) -> [SkillID] {
            guard let invocation,
                  usedInvocations.contains(invocation),
                  let recipe = selectedRecipe
            else { return [] }
            return [recipe.id]
        }

        // 1. This ability's own skills, recipes among them.
        let ownTiles = draft.skills.map { skill -> AbilityStudioSkillTile in
            let invocation = skill.modelExposure.invocationName
            return AbilityStudioSkillTile(
                id: skill.id,
                title: skill.title,
                summary: skill.summary,
                invocation: invocation,
                kind: skill.kind,
                access: skill.access,
                ownerAbilityID: draft.ability.id,
                ownerTitle: draft.ability.title,
                ownerTint: draft.ability.tint,
                origin: .own,
                readiness: snapshot.skill(id: skill.id)?.availability.readiness,
                realization: Self.realization(
                    for: skill,
                    localOperation: realizationsBySkill[skill.id],
                    snapshot: snapshot),
                isRecipe: skill.execution.kind == .stateMachine,
                usedByRecipes: usedBy(invocation))
        }

        var lanes: [AbilityStudioSkillLane] = []
        lanes.append(AbilityStudioSkillLane(
            abilityID: draft.ability.id,
            title: draft.ability.title,
            tint: draft.ability.tint,
            note: ownTiles.isEmpty ? "realizes what it extends" : "this ability",
            tiles: ownTiles))

        // 2. Required dependencies — the disciplines an expertise realizes.
        let required = Set(draft.extendedDisciplines.map(\.rawValue))
        // 3. Optional ones — on hand when a route calls for them.
        let optional = Set(draft.dependencies.filter(\.optional).map(\.packageID.rawValue))

        for packageID in draft.dependencies.map(\.packageID) {
            guard let record = snapshot.package(id: packageID) else { continue }
            let ability = record.package.ability
            let isRequired = required.contains(packageID.rawValue)
            guard isRequired || optional.contains(packageID.rawValue) else { continue }

            let tiles = snapshot.skills
                .filter { $0.packageID == packageID }
                .map { runtime -> AbilityStudioSkillTile in
                    let invocation = runtime.skill.modelExposure.invocationName
                    return AbilityStudioSkillTile(
                        id: runtime.skill.id,
                        title: runtime.skill.title,
                        summary: runtime.skill.summary,
                        invocation: invocation,
                        kind: runtime.skill.kind,
                        access: runtime.skill.access,
                        ownerAbilityID: ability.id,
                        ownerTitle: ability.title,
                        ownerTint: ability.tint,
                        origin: isRequired
                            ? .extendedDiscipline(packageID)
                            : .supporting(packageID),
                        readiness: runtime.availability.readiness,
                        realization: Self.realization(
                            for: runtime.skill,
                            localOperation: realizationsBySkill[runtime.skill.id],
                            snapshot: snapshot,
                            runtime: runtime),
                        isRecipe: runtime.skill.execution.kind == .stateMachine,
                        usedByRecipes: usedBy(invocation))
                }
            guard !tiles.isEmpty else { continue }
            lanes.append(AbilityStudioSkillLane(
                abilityID: ability.id,
                title: ability.title,
                tint: ability.tint,
                note: isRequired ? "extends" : "supporting",
                tiles: tiles,
                isCollapsedByDefault: !isRequired))
        }

        self.lanes = lanes
    }

    /// Local hands win over anything else: they are the reason this package
    /// exists for that skill.
    private static func realization(
        for skill: SkillSchema,
        localOperation: String?,
        snapshot: AbilityRuntimeSnapshot,
        runtime: AbilityRuntimeSkill? = nil
    ) -> AbilityStudioSkillTile.Realization {
        if let localOperation { return .localHands(operation: localOperation) }
        switch skill.execution.kind {
        case .cognitive, .stateMachine:
            return .notApplicable
        case .binding:
            if let binding = runtime?.availability.selectedBinding,
               let manifest = snapshot.adapterManifest(id: binding.adapterID) {
                return .provider(title: manifest.resolvedProvider.pluginTitle)
            }
            if let adapterID = skill.execution.bindings.first?.adapterID,
               let manifest = snapshot.adapterManifest(id: adapterID) {
                return .provider(title: manifest.resolvedProvider.pluginTitle)
            }
            return .none
        }
    }
}
