//
//  PluginProvenance.swift
//  MaryFoundation
//
//  WHAT: Where a provider came from. Inventories/receipts, not authorization.
//  IN:   InstalledAdapterManifest.provider, AbilitySkillReference.provider.
//  OUT:  same capability checks either class.
//

import Foundation

/// Runtime (compiled generic) vs package (interpreted Plugin). No per-app class.
public enum PluginProviderClass: String, Codable, Hashable, Sendable, CaseIterable {
    /// A generic adapter compiled into Mary, configured by declaration.
    case runtime
    /// An adapter a Plugin package declares, interpreted rather than compiled.
    case package
}

/// Frozen provider identity used by runtime inventories, receipts, and chat
/// presentation. It is provenance, never an authorization level.
public struct AdapterProviderProvenance: Codable, Hashable, Sendable {
    public var pluginClass: PluginProviderClass
    public var pluginID: String
    public var pluginTitle: String
    public var originPackageID: PackageID?
    public var originPackageVersion: SemanticVersion?
    public var originPackageDigest: String?
    public var applicationID: String?

    public init(
        pluginClass: PluginProviderClass,
        pluginID: String,
        pluginTitle: String,
        originPackageID: PackageID? = nil,
        originPackageVersion: SemanticVersion? = nil,
        originPackageDigest: String? = nil,
        applicationID: String? = nil
    ) {
        self.pluginClass = pluginClass
        self.pluginID = pluginID
        self.pluginTitle = pluginTitle
        self.originPackageID = originPackageID
        self.originPackageVersion = originPackageVersion
        self.originPackageDigest = originPackageDigest
        self.applicationID = applicationID
    }
}
