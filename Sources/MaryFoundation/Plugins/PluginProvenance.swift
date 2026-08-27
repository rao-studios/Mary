//
//  PluginProvenance.swift
//  MaryFoundation
//
//  WHERE A PROVIDER CAME FROM. This is provenance for inventories and
//  receipts, never an authorization level — both classes below are subject to
//  exactly the same capability checks.
//

import Foundation

/// The two ways a provider can exist.
///
/// Note what is NOT here: an "application plugin" class. Mary compiles in no
/// knowledge of any particular application. A RUNTIME provider is generic by
/// construction — the typer, the prose surface, window management — and a
/// PACKAGE provider is an adapter a Plugin declares and Mary's managed-UI
/// engine interprets. Which application either one is serving at a given
/// moment is a fact about the turn, not about the provider.
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
