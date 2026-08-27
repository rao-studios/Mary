//
//  AbilitySkillReference.swift
//  MaryFoundation
//
//  A resolved pointer to a Skill in the installed graph, and the receipt one
//  run of it produces. Both are runtime views over the declarations above.
//

import Foundation

/// Frozen identity and presentation for one invoked skill. Conversation rows
/// retain this snapshot so editing or uninstalling a package never rewrites
/// history.
public enum AbilityReferenceSource: String, Codable, Hashable, Sendable, CaseIterable {
    case package
    case adapterFallback
    case runtime
}

public struct AbilitySkillReference: Codable, Hashable, Sendable, Identifiable {
    public var packageID: PackageID
    public var packageVersion: SemanticVersion
    public var packageDigest: String?
    public var abilityID: AbilityID
    public var abilityTitle: String
    public var abilityTint: String
    public var skillID: SkillID
    public var skillTitle: String
    public var invocationName: String
    public var adapterID: AdapterID?
    public var bindingOperation: String?
    public var source: AbilityReferenceSource
    /// Frozen implementation provenance. Nil means a legacy/native provider.
    public var provider: AdapterProviderProvenance?

    public init(
        packageID: PackageID,
        packageVersion: SemanticVersion,
        packageDigest: String? = nil,
        abilityID: AbilityID,
        abilityTitle: String,
        abilityTint: String,
        skillID: SkillID,
        skillTitle: String,
        invocationName: String,
        adapterID: AdapterID? = nil,
        bindingOperation: String? = nil,
        source: AbilityReferenceSource = .package,
        provider: AdapterProviderProvenance? = nil
    ) {
        self.packageID = packageID
        self.packageVersion = packageVersion
        self.packageDigest = packageDigest
        self.abilityID = abilityID
        self.abilityTitle = abilityTitle
        self.abilityTint = abilityTint
        self.skillID = skillID
        self.skillTitle = skillTitle
        self.invocationName = invocationName
        self.adapterID = adapterID
        self.bindingOperation = bindingOperation
        self.source = source
        self.provider = provider
    }

    public var id: String { "\(abilityID.rawValue)|\(skillID.rawValue)" }
    public var displayLabel: String { "\(abilityID.rawValue) | \(invocationName)" }
}

public enum SkillRunStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case requested
    case running
    case succeeded
    case failed
    case blocked
    case deferred
    case cancelled
}

public struct SkillRunReceipt: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var reference: AbilitySkillReference
    public var status: SkillRunStatus
    public var startedAt: Date
    public var finishedAt: Date?
    public var effect: CapabilityEffect
    public var targetScope: SourceScope?
    public var inputTypes: [ValueTypeID]
    public var outputTypes: [ValueTypeID]
    public var consumedInteractions: [InteractionInstanceReference]
    /// True when execution completed normally but the requested source value
    /// did not exist. Route diagnostics retain this bounded outcome instead
    /// of the result prose, which may contain selected text or source code.
    public var foundNothing: Bool

    public init(
        id: UUID = UUID(),
        reference: AbilitySkillReference,
        status: SkillRunStatus,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        effect: CapabilityEffect = .none,
        targetScope: SourceScope? = nil,
        inputTypes: [ValueTypeID] = [],
        outputTypes: [ValueTypeID] = [],
        consumedInteractions: [InteractionInstanceReference] = [],
        foundNothing: Bool = false
    ) {
        self.id = id
        self.reference = reference
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.effect = effect
        self.targetScope = targetScope
        self.inputTypes = inputTypes
        self.outputTypes = outputTypes
        self.consumedInteractions = consumedInteractions
        self.foundNothing = foundNothing
    }
}
