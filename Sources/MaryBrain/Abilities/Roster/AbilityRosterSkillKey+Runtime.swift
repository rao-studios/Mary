//
//  AbilityRosterSkillKey+Runtime.swift
//  MaryBrain
//
//  WHAT: Mint AbilityRosterSkillKey from a live AbilityRuntimeSkill.
//  IN:   frozen registry
//  OUT:  trace key (type lives in MaryAmbient)
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
