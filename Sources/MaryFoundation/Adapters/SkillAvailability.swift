//
//  SkillAvailability.swift
//  MaryFoundation
//
//  Whether a declared Skill can actually run right now: an adapter is present,
//  the permissions are granted, and nothing is missing. This is the answer the
//  runtime and the inspector both read.
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
