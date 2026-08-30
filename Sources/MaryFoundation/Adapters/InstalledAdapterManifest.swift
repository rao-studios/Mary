//
//  InstalledAdapterManifest.swift
//  MaryFoundation
//
//  WHAT: Installed provider claims — transport, operations, Capability/Interaction coverage.
//  IN:   adapter handshake at install.
//  OUT:  AdapterManifestValidator, SkillAvailability, AbilityRuntime.
//

import Foundation

/// Dispatch boundary. `.native` = compiled provider; AdapterProviderProvenance.pluginClass says compiled vs Plugin data.
public enum AdapterTransport: String, Codable, Hashable, Sendable, CaseIterable {
    /// Direct dispatch into a compiled provider. Not "native frameworks only".
    case native
    /// Closed Accessibility interaction boundary.
    case accessibility
    /// Fixed Apple Event / Automation boundary.
    case automation
    /// Bluetooth device boundary.
    case bluetooth
    /// Network service boundary.
    case network
    /// Reviewed fixed local-process boundary.
    case localProcess
}

/// Empty claim lists: unspecified (incremental) vs explicit none (complete).
public enum AdapterClaimCoverage: String, Codable, Hashable, Sendable, CaseIterable {
    case incremental
    case complete
}

/// One callable operation. Typed claims compared to a Skill before it is runnable.
public struct InstalledAdapterBinding: Codable, Hashable, Sendable {
    public var adapterID: AdapterID
    public var operation: String
    public var capabilities: [CapabilityID]
    public var inputTypes: [ValueTypeID]
    public var outputTypes: [ValueTypeID]
    public var consumesInteractions: [InteractionID]
    public var observesPerceptions: [PerceptionID]
    public var targetClasses: [String]
    /// Adapter-enforced source constraints after it resolves the target.
    /// Mary owns duration/payload/stage/confirm/target-class; AdapterManifestValidator lists the three delegated kinds.
    public var enforcedConstraints: [CapabilityConstraint]
    public var isAvailable: Bool
    public var unavailableReason: String?

    public init(
        adapterID: AdapterID,
        operation: String,
        capabilities: [CapabilityID] = [],
        inputTypes: [ValueTypeID] = [],
        outputTypes: [ValueTypeID] = [],
        consumesInteractions: [InteractionID] = [],
        observesPerceptions: [PerceptionID] = [],
        targetClasses: [String] = [],
        enforcedConstraints: [CapabilityConstraint] = [],
        isAvailable: Bool = true,
        unavailableReason: String? = nil
    ) {
        self.adapterID = adapterID
        self.operation = operation
        self.capabilities = capabilities
        self.inputTypes = inputTypes
        self.outputTypes = outputTypes
        self.consumesInteractions = consumesInteractions
        self.observesPerceptions = observesPerceptions
        self.targetClasses = targetClasses
        self.enforcedConstraints = enforcedConstraints
        self.isAvailable = isAvailable
        self.unavailableReason = unavailableReason
    }
}

/// Runtime handshake: contracts this adapter produces/consumes. Mary keeps execution/privacy.
public struct InstalledAdapterManifest: Codable, Hashable, Sendable, Identifiable {
    public var adapterID: AdapterID
    public var version: SemanticVersion
    public var title: String
    public var transport: AdapterTransport
    public var claimCoverage: AdapterClaimCoverage
    public var operations: [InstalledAdapterBinding]
    public var providesInteractions: [InteractionID]
    public var providesPerceptions: [PerceptionID]
    public var supportedValueTypes: [ValueTypeID]
    public var grantedPermissions: [PermissionKind]
    public var isAvailable: Bool
    public var unavailableReason: String?
    /// Nil = runtime-owned generic adapter. Plugin manifests freeze Ability provenance.
    public var provider: AdapterProviderProvenance?

    public init(
        adapterID: AdapterID,
        version: SemanticVersion = "1.0.0",
        title: String,
        transport: AdapterTransport,
        claimCoverage: AdapterClaimCoverage = .incremental,
        operations: [InstalledAdapterBinding] = [],
        providesInteractions: [InteractionID] = [],
        providesPerceptions: [PerceptionID] = [],
        supportedValueTypes: [ValueTypeID] = [],
        grantedPermissions: [PermissionKind] = [],
        isAvailable: Bool = true,
        unavailableReason: String? = nil,
        provider: AdapterProviderProvenance? = nil
    ) {
        self.adapterID = adapterID
        self.version = version
        self.title = title
        self.transport = transport
        self.claimCoverage = claimCoverage
        self.operations = operations
        self.providesInteractions = providesInteractions
        self.providesPerceptions = providesPerceptions
        self.supportedValueTypes = supportedValueTypes
        self.grantedPermissions = grantedPermissions
        self.isAvailable = isAvailable
        self.unavailableReason = unavailableReason
        self.provider = provider
    }

    public var id: AdapterID { adapterID }

}
