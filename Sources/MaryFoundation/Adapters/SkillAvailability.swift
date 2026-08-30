//
//  SkillAvailability.swift
//  MaryFoundation
//
//  WHAT: Whether a declared Skill can run now (adapter, permissions, gaps).
//  IN:   AbilityRuntime inventory join.
//  OUT:  inspector, roster.
//

import Foundation

public enum SkillReadiness: String, Codable, Hashable, Sendable, CaseIterable {
    case ready
    case partial
    case blocked
}

public struct SkillAvailability: Codable, Hashable, Sendable, Identifiable {
    public var skillID: SkillID
    public var readiness: SkillReadiness
    public var selectedBinding: InstalledAdapterBinding?
    public var missingCapabilities: [CapabilityID]
    public var reasons: [String]

    public init(
        skillID: SkillID,
        readiness: SkillReadiness,
        selectedBinding: InstalledAdapterBinding? = nil,
        missingCapabilities: [CapabilityID] = [],
        reasons: [String] = []
    ) {
        self.skillID = skillID
        self.readiness = readiness
        self.selectedBinding = selectedBinding
        self.missingCapabilities = missingCapabilities
        self.reasons = reasons
    }

    public var id: SkillID { skillID }
}
