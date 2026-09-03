//
//  AbilityTotemProjectionPlan.swift
//  MaryBrain
//
//  WHAT: Frozen Totem projection plan for a package result.
//  IN:   package schema
//  OUT:  depositor-enforced plan (or nil = machine-local only)
//
import MaryFoundation
import Foundation

/// One package-authored Totem projection resolved against the exact Ability registry revision used to execute a Skill.
public struct ResolvedTotemProjection: Sendable, Equatable, Identifiable {
    public var id: ProjectionID
    public var purpose: TotemProjectionPurpose
    public var persistence: ProjectionPersistence
    public var includedFields: Set<String>
    public var excludedFields: Set<String>
    public var redactContent: Bool
    public var retentionSeconds: Double?

    public init(
        id: ProjectionID,
        purpose: TotemProjectionPurpose,
        persistence: ProjectionPersistence,
        includedFields: Set<String>,
        excludedFields: Set<String>,
        redactContent: Bool,
        retentionSeconds: Double?
    ) {
        self.id = id
        self.purpose = purpose
        self.persistence = persistence
        self.includedFields = includedFields
        self.excludedFields = excludedFields
        self.redactContent = redactContent
        self.retentionSeconds = retentionSeconds
    }

    public var permitsDurableStorage: Bool {
        persistence == .durable
    }

    /// Exclusion is always authoritative, even if a malformed package somehow
    /// reaches a runtime snapshot without passing validation.
    public func includes(_ field: String) -> Bool {
        includedFields.contains(field) && !excludedFields.contains(field)
    }
}

/// Frozen persistence instructions for one executed Skill.
public struct AbilityTotemProjectionPlan: Sendable, Equatable {
    public var packageID: PackageID
    public var packageVersion: SemanticVersion
    public var packageDigest: String?
    public var abilityID: AbilityID
    public var skillID: SkillID
    public var paradigm: AbilityParadigm
    public var abilityTargets: [AbilityTotemTarget]
    public var receipts: [ResolvedTotemProjection]
    public var content: [ResolvedTotemProjection]

    public init(
        packageID: PackageID,
        packageVersion: SemanticVersion,
        packageDigest: String?,
        abilityID: AbilityID,
        skillID: SkillID,
        paradigm: AbilityParadigm,
        abilityTargets: [AbilityTotemTarget],
        receipts: [ResolvedTotemProjection],
        content: [ResolvedTotemProjection]
    ) {
        self.packageID = packageID
        self.packageVersion = packageVersion
        self.packageDigest = packageDigest
        self.abilityID = abilityID
        self.skillID = skillID
        self.paradigm = paradigm
        self.abilityTargets = abilityTargets
        self.receipts = receipts.sorted { $0.id.rawValue < $1.id.rawValue }
        self.content = content.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public static func denied(for reference: AbilitySkillReference) -> Self {
        Self(
            packageID: reference.packageID,
            packageVersion: reference.packageVersion,
            packageDigest: reference.packageDigest,
            abilityID: reference.abilityID,
            skillID: reference.skillID,
            paradigm: .discipline,
            abilityTargets: [],
            receipts: [],
            content: [])
    }

    public var durableReceipts: [ResolvedTotemProjection] {
        receipts.filter(\.permitsDurableStorage)
    }

    public var durableContent: [ResolvedTotemProjection] {
        content.filter(\.permitsDurableStorage)
    }

    public var permitsDurableStorage: Bool {
        !durableReceipts.isEmpty || !durableContent.isEmpty
    }

    public func matches(_ reference: AbilitySkillReference) -> Bool {
        reference.source == .package
            && packageID == reference.packageID
            && packageVersion == reference.packageVersion
            && packageDigest == reference.packageDigest
            && abilityID == reference.abilityID
            && skillID == reference.skillID
    }
}

public extension AbilityRuntime.Snapshot {
    /// Resolves Totem policy against this exact registry revision. `nil`
    /// means the reference did not come from a package in the snapshot;
    /// `.denied` means it claimed to, but its identity or policy did not match.
    func totemProjectionPlan(
        for reference: AbilitySkillReference
    ) -> AbilityTotemProjectionPlan? {
        guard reference.source == .package else { return nil }
        guard let record = package(id: reference.packageID),
              record.package.ability.id == reference.abilityID,
              record.package.package.version == reference.packageVersion,
              record.package.ability.skills.contains(reference.skillID),
              let skill = record.package.skills.first(where: {
                  $0.id == reference.skillID
              }),
              (skill.invocationName ?? skill.id.rawValue) == reference.invocationName
        else { return .denied(for: reference) }

        let actualDigest = record.package.integrity?.digest
            ?? (try? AbilityPackageCodec.digest(of: record.package))
        guard let expectedDigest = reference.packageDigest,
              let actualDigest,
              expectedDigest == actualDigest
        else {
            return .denied(for: reference)
        }

        let selectedIDs = Set(record.package.ability.totemProjections)
        let selected = record.package.totemProjections.filter { schema in
            selectedIDs.contains(schema.id)
                && (schema.skills.isEmpty || schema.skills.contains(reference.skillID))
                && schema.purpose != .interaction
        }
        let resolved = selected.map(Self.resolveTotemProjection)

        return AbilityTotemProjectionPlan(
            packageID: reference.packageID,
            packageVersion: reference.packageVersion,
            packageDigest: actualDigest,
            abilityID: reference.abilityID,
            skillID: reference.skillID,
            paradigm: record.package.paradigm,
            abilityTargets: record.package.abilityTotemTargets { id in
                package(id: id)?.package.paradigm
            },
            receipts: resolved.filter { $0.purpose == .receipt },
            content: resolved.filter { $0.purpose == .content })
    }

    private static func resolveTotemProjection(
        _ schema: TotemProjectionSchema
    ) -> ResolvedTotemProjection {
        ResolvedTotemProjection(
            id: schema.id,
            purpose: schema.purpose,
            persistence: schema.persistence,
            includedFields: Set(schema.include),
            excludedFields: Set(schema.exclude),
            redactContent: schema.redactContent,
            retentionSeconds: schema.retentionSeconds)
    }
}
