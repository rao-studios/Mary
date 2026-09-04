//
//  AbilitySkillBench.swift
//  MaryBrain
//
//  WHAT: What one Ability can do, grouped by the Ability that DEFINES each skill.
//  IN:   a package + the activated snapshot
//  OUT:  lanes of tiles — Ability Studio lays them out, Sand runs them
//  PIN:  AN EXPERTISE USUALLY OWNS NOTHING. It realizes a discipline's skills,
//        so listing only what its own file contains answers "Apple Music can
//        open the player" when the truth is that it can do everything
//        multimedia declares. This derivation is the forward read of that edge:
//        the package's required dependencies are the disciplines it extends,
//        its optional ones are on hand when a route calls for them, and
//        `plugin.realizations` says which of those skills THIS package's own
//        hands carry out.
//        IN MARYBRAIN BECAUSE TWO APPS READ IT. This lived in MaryApp, where
//        Ability Studio's Skills pane lays it out. Sand's bench RUNS the same
//        lanes, and one executable target cannot import another — MaryBrain is
//        the highest layer both stand on, so the derivation moved here and the
//        Studio kept its old names as typealiases. A copy in Sand would drift
//        from the one the authoring tool shows, which is the one that decides
//        what an author believes their package can do.
//

import Foundation

public struct AbilitySkillTile: Identifiable, Hashable {

    /// Whose skill this is, from this package's point of view.
    public enum Origin: Hashable {
        case own
        /// A discipline this expertise realizes — a required dependency.
        case extendedDiscipline(PackageID)
        /// An optional dependency, on hand when the route needs it.
        case supporting(PackageID)
    }

    /// Who actually carries it out.
    public enum Realization: Hashable {
        /// This package's own macUI recipe realizes it.
        case localHands(operation: String)
        /// A compiled faculty, or another package's hands.
        case provider(title: String)
        /// A portable contract with no provider yet.
        case none
        /// Cognitive skills and recipes have nothing to bind.
        case notApplicable

        public var word: String {
            switch self {
            case .localHands: return "hands here"
            case .provider(let title): return title
            case .none: return "no hands yet"
            case .notApplicable: return ""
            }
        }
    }

    public let id: SkillID
    public let title: String
    public let summary: String
    public let invocation: String?
    public let kind: SkillKind
    public let access: SkillAccess
    public let ownerAbilityID: AbilityID
    public let ownerTitle: String
    public let ownerTint: String
    public let origin: Origin
    public let readiness: SkillReadiness?
    public let realization: Realization
    public let isRecipe: Bool
    /// Recipes in this draft that name it. Drives the bench↔recipe highlight.
    public let usedByRecipes: [SkillID]

    public var isUsedBySelectedRecipe: Bool { !usedByRecipes.isEmpty }

    /// A recipe may not call something that stops to ask the user.
    public var isComposable: Bool { access != .confirm }
}

public struct AbilitySkillLane: Identifiable, Hashable {
    public let abilityID: AbilityID
    public let title: String
    public let tint: String
    public let note: String?
    public let tiles: [AbilitySkillTile]
    public var isCollapsedByDefault: Bool = false

    public var id: AbilityID { abilityID }
}

public struct AbilitySkillBench {
    public let lanes: [AbilitySkillLane]

    public var isEmpty: Bool { lanes.allSatisfy(\.tiles.isEmpty) }

    public init(
        package draft: MaryAbilityPackage,
        snapshot: AbilityRuntime.Snapshot,
        selectedRecipe: SkillSchema? = nil
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
        let ownTiles = draft.skills.map { skill -> AbilitySkillTile in
            let invocation = skill.modelExposure.invocationName
            return AbilitySkillTile(
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

        var lanes: [AbilitySkillLane] = []
        lanes.append(AbilitySkillLane(
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
                .map { runtime -> AbilitySkillTile in
                    let invocation = runtime.skill.modelExposure.invocationName
                    return AbilitySkillTile(
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
            lanes.append(AbilitySkillLane(
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
        snapshot: AbilityRuntime.Snapshot,
        runtime: AbilityRuntimeSkill? = nil
    ) -> AbilitySkillTile.Realization {
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
