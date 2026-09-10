//
//  PluginCompilerModels.swift
//  MaryBrain
//
//  WHAT: Model types for PluginCompiler.
//  IN:   PluginCompiler.swift (sibling split)
//  OUT:  compilation records / availability
//
import MaryFoundation
import Foundation

/// One concrete implementation of a provider-neutral Skill.
public struct PluginSkillBindingRealization: Hashable, Sendable, Identifiable {
    public var originPackageID: PackageID
    public var skillID: SkillID
    public var binding: AdapterBindingReference
    public var provider: AdapterProviderProvenance

    public init(
        originPackageID: PackageID,
        skillID: SkillID,
        binding: AdapterBindingReference,
        provider: AdapterProviderProvenance
    ) {
        self.originPackageID = originPackageID
        self.skillID = skillID
        self.binding = binding
        self.provider = provider
    }

    public var id: String {
        "\(provider.pluginID)|\(skillID.rawValue)|\(binding.adapterID.rawValue)|\(binding.operation)"
    }
}

/// Immutable output of compiling the Dynamic Plugins in one active Ability graph. This layer contains no closures, event taps, or process handles.
public struct PluginCompilation: Sendable {
    public var adapterManifests: [InstalledAdapterManifest]
    public var skillRealizations: [PluginSkillBindingRealization]
    public var applicationProfiles: [ApplicationProfile]
    public var issues: [SchemaIssue]

    public init(
        adapterManifests: [InstalledAdapterManifest] = [],
        skillRealizations: [PluginSkillBindingRealization] = [],
        applicationProfiles: [ApplicationProfile] = [],
        issues: [SchemaIssue] = []
    ) {
        self.adapterManifests = adapterManifests
        self.skillRealizations = skillRealizations
        self.applicationProfiles = applicationProfiles
        self.issues = issues
    }

    public var isValid: Bool {
        !issues.contains { $0.severity == .error }
    }

    /// All installed providers capable of realizing this semantic Skill,
    /// ordered by preference and then stable provider identity.
    public func bindings(for skillID: SkillID) -> [AdapterBindingReference] {
        skillRealizations
            .filter { $0.skillID == skillID }
            .sorted(by: Self.realizationPrecedes)
            .map(\.binding)
    }

    public func realization(
        skillID: SkillID,
        adapterID: AdapterID,
        operation: String
    ) -> PluginSkillBindingRealization? {
        skillRealizations.first {
            $0.skillID == skillID
                && $0.binding.adapterID == adapterID
                && $0.binding.operation == operation
        }
    }

    private static func realizationPrecedes(
        _ left: PluginSkillBindingRealization,
        _ right: PluginSkillBindingRealization
    ) -> Bool {
        if left.binding.preference != right.binding.preference {
            return left.binding.preference > right.binding.preference
        }
        if left.binding.adapterID != right.binding.adapterID {
            return left.binding.adapterID.rawValue < right.binding.adapterID.rawValue
        }
        return left.binding.operation < right.binding.operation
    }
}
