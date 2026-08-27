//
//  AbilityRosterSkillKey+Runtime.swift
//
//  The key is a trace value and lives in MaryAmbient. Minting one from a
//  live AbilityRuntimeSkill needs the frozen registry, so that half stays
//  here with the registry it reads.
//

import Foundation

extension AbilityRosterSkillKey {
    init(_ runtime: AbilityRuntimeSkill) {
        self.init(
            packageID: runtime.packageID,
            abilityID: runtime.ability.id,
            skillID: runtime.skill.id)
    }
}
