//
//  AbilityTestFixtures.swift
//  MaryBrainTests
//
//  DOCUMENTED DUPLICATION ([Reorg] test phase 4): this file has twins at
//  Tests/BonnieTests/AbilityTestFixtures.swift and
//  Tests/BonnieRuntimeTests/AbilityTestFixtures.swift. SwiftPM test targets
//  cannot import other test targets, and no new targets are allowed
//  (PackageLayeringTests reads the manifests), so the fixtures exist three
//  times by design. EDIT IN LOCKSTEP: any change here must land in both
//  twins too.
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
