//
//  AbilityTestFixtures.swift
//  MaryBrainTests
//
//  WHAT: Shared AbilitySkillReference for Brain tests.
//  OUT:  fixtureAbilityReference
//

import MaryBrain

/// Stable package identity for event assertions. Tests that care about the
/// operation inspect `invocationName`; tests that care about frozen identity
/// compare the complete value.
func fixtureAbilityReference(
    _ invocationName: String,
    abilityID: AbilityID = .writing,
    tint: String = "#7C5CFC"
) -> AbilitySkillReference {
    let skillID = invocationName
        .lowercased()
        .replacingOccurrences(of: "_", with: "-")
    return AbilitySkillReference(
        packageID: PackageID("tests.\(abilityID.rawValue)"),
        packageVersion: "1.0.0",
        packageDigest: "test-digest-\(abilityID.rawValue)",
        abilityID: abilityID,
        abilityTitle: abilityID.rawValue.capitalized,
        abilityTint: tint,
        skillID: SkillID(skillID),
        skillTitle: invocationName,
        invocationName: invocationName,
        adapterID: AdapterID("tests"),
        bindingOperation: invocationName,
        source: .runtime)
}
