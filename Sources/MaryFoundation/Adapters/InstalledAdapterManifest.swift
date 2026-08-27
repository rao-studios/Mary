//
//  InstalledAdapterManifest.swift
//  MaryFoundation
//
//  WHAT AN INSTALLED PROVIDER CLAIMS: the transport Mary dispatches through,
//  the operations it binds, and how completely it covers the Capabilities and
//  Interactions an Ability asked for.
//

import Foundation

/// The machine-local provider boundary through which Mary dispatches an
/// adapter operation. This is not an implementation-language claim and not an
/// exhaustive call graph of OS facilities used behind that boundary.
///
/// In particular, `.native` means Mary enters a compiled provider directly;
/// that reviewed provider may internally combine fixed Accessibility, Apple
/// Event, or local-process faculties. Providers whose operation contract is
/// intentionally defined by one external boundary declare that boundary
/// instead. `AdapterProviderProvenance.pluginClass`, not this value, records
/// whether the provider is compiled or Ability-carried declarative data.
public enum AdapterTransport: String, Codable, Hashable, Sendable, CaseIterable {
    /// Direct dispatch into a compiled provider. No claim of exclusively using
    /// native frameworks behind that provider boundary is implied.
    case native
    /// A closed Accessibility interaction boundary.
    case accessibility
    /// A fixed Apple Event / Automation boundary.
    case automation
    /// A Bluetooth device boundary.
    case bluetooth
    /// A network service boundary.
    case network
    /// A reviewed fixed local-process boundary.
    case localProcess
}

/// Whether empty typed claim lists mean "not specified yet" or an explicit
/// statement that the adapter supports none of that contract. Incremental is
/// the migration-safe default for Mary's existing adapters; new devices and
/// fully described adapters should publish `.complete`.
public enum AdapterClaimCoverage: String, Codable, Hashable, Sendable, CaseIterable {
    case incremental
    case complete
}

/// One callable operation an installed adapter can satisfy. Its typed claims
/// are compared with an Ability Skill before that Skill becomes runnable.
public struct InstalledAdapterBinding: Codable, Hashable, Sendable {
    public var adapterID: AdapterID
    public var operation: String
    public var capabilities: [CapabilityID]
    public var inputTypes: [ValueTypeID]
    public var outputTypes: [ValueTypeID]
    public var consumesInteractions: [InteractionID]
    public var observesPerceptions: [PerceptionID]
    public var targetClasses: [String]
    /// Source-sensitive guarantees enforced inside the local adapter after it
    /// has resolved the concrete application, document, or selection target.
    /// Mary enforces duration, payload, stage, confirmation, and target-class
    /// policy itself; adapters may attest only the three delegated constraint
    /// kinds accepted by `AdapterManifestValidator`.
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

/// Runtime handshake published by one adapter. This is the extension seam for
/// a new IDE, application, sensor, or Bluetooth device: it names the stable
/// data contracts it can produce or consume, while Mary retains execution,
/// permission, routing, and privacy arbitration.
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
    /// Nil resolves to a runtime-owned provider — a generic adapter Mary ships.
    /// Plugin manifests always freeze their Ability-provided provenance.
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
