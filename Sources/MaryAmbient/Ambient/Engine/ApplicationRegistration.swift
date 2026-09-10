//
//  ApplicationRegistration.swift
//  MaryAmbient
//
//  WHAT: Which applications exist on this machine — not which worlds Mary ships.
//  IN:   packages / AmbientApplicationIndexProvider
//  OUT:  AmbientPlace.application / AmbientAttention.applications (host lane)
//  PIN:  AmbientAttention stays closed over compiled plugin owners; taught apps are registrations.
//

import Foundation

/// One application Mary can recognise, with or without its own `AmbientAttention`.
/// PIN: Recognition ≠ execution availability — a blocked provider still registers.
public struct ApplicationRegistration: Sendable, Equatable, SurfaceClaim {

    /// Logical application id (`"sketch"`). Dispatcher owner and memory attribution — never a bundle id.
    public var id: String

    /// Routing profile — aliases, abilities, target classes. This type adds identity and taxonomy.
    public var profile: ApplicationProfile

    /// Exact process identities, case-insensitive.
    /// PIN: Aliases answer "did they name it?"; these answer "did this fact come from it?"
    public var bundleIdentifiers: Set<String>

    /// Process family, when declared. Same as `ApplicationProfile.applicationBundlePrefix`.
    public var bundleIdentifierPrefix: String?

    /// Ambient taxonomy class. From the registration, not `legacyAttention` (that's a rendering detail).
    public var placeClass: AmbientPlaceClass

    /// Spoken name. Dynamic packages derive from logical id — package title is inspector-only.
    public var displayName: String

    /// How this application can be observed, if at all. Nil is the common case — operate ≠ see.
    public var perception: ApplicationPerception?

    /// Closed world this projects onto. Non-nil only for a genuine built-in; Dynamic stays nil.
    public var legacyAttention: AmbientAttention?

    public init(
        id: String,
        profile: ApplicationProfile,
        bundleIdentifiers: Set<String> = [],
        bundleIdentifierPrefix: String? = nil,
        placeClass: AmbientPlaceClass,
        displayName: String? = nil,
        perception: ApplicationPerception? = nil,
        legacyAttention: AmbientAttention? = nil
    ) {
        self.id = id
        self.profile = profile
        self.bundleIdentifiers = bundleIdentifiers
        self.bundleIdentifierPrefix = bundleIdentifierPrefix
        self.placeClass = placeClass
        self.displayName = displayName ?? legacyAttention?.displayName ?? profile.title
        self.perception = perception
        self.legacyAttention = legacyAttention
    }

    /// `SurfaceClaim` identity — the logical id, never a bundle identifier.
    public var applicationID: String { id }

    /// Whether this running process is this application.
    public func owns(bundleID: String) -> Bool {
        SurfaceClaimOwnership.exactThenFamily(
            bundleID: bundleID,
            identifiers: bundleIdentifiers,
            prefix: bundleIdentifierPrefix)
    }

    /// Family match ends on a boundary, not mid-word.
    /// PIN: `hasPrefix` would treat `mirrorwell` as owning `mirrorwelling`.
    public static func isInFamily(_ bundleID: String, prefix: String) -> Bool {
        guard bundleID.hasPrefix(prefix) else { return false }
        var rest = Substring(bundleID.dropFirst(prefix.count))
        if rest.isEmpty { return true }
        while let first = rest.first, first.isNumber { rest = rest.dropFirst() }
        return rest.isEmpty || rest.first == "."
    }

    /// Eyes = workspace class and a declared way to observe. Taxonomy stays separate from observation.
    public var observesDocuments: Bool {
        perception?.observesDocuments == true
    }

    /// Singular document noun. `"document"` when the package did not say.
    public var documentNoun: String {
        profile.documentNoun ?? "document"
    }

    public var hasEyes: Bool {
        placeClass == .workspace && perception?.observesDocuments == true
    }

    /// Place this application's facts key under.
    /// PIN: All-browser process identities share the browser workspace, not a private place.
    public var place: AmbientPlace {
        if legacyAttention == nil, !bundleIdentifiers.isEmpty,
           bundleIdentifiers.allSatisfy({ AmbientPlaceResolver.isBrowser(bundleID: $0) }) {
            return AmbientPlaceResolver.browserPlace
        }
        return AmbientPlace(attention: legacyAttention ?? .applications,
                            application: legacyAttention == nil ? id : nil)
    }
}

/// Declared observation: a non-mutating operation and how often it may run.
public struct ApplicationPerception: Sendable, Equatable {

    /// What the package claimed it can be observed as — also the registration's class.
    public enum Kind: String, Sendable, Equatable {
        /// Live selection only, through the generic Accessibility reader.
        case perceptionOnly
        /// Selection plus a document channel — requires `documentOperation`.
        case workspace
    }

    public var kind: Kind

    /// Declared read operation Mary polls. Must be non-mutating — one of two `.workspace` channels.
    public var documentOperation: String?

    /// Mary's corpus reader is the channel. Set at admission from `documentCorpus`, not by the package.
    public var readsDocumentCorpus: Bool

    /// Seconds between document polls. Bounded well above Accessibility selection cadence.
    public var pollSeconds: Int

    /// The floor and ceiling the validator enforces.
    public static let pollBounds = 15...300

    /// Ambient class this declaration implies. Derived — two stored fields that must agree eventually disagree.
    public var placeClass: AmbientPlaceClass {
        switch kind {
        case .workspace:      return .workspace
        case .perceptionOnly: return .perceptionOnly
        }
    }

    /// Whether anything is reading this application's document — poll operation or corpus reader.
    public var observesDocuments: Bool {
        documentOperation != nil || readsDocumentCorpus
    }

    public init(
        kind: Kind = .workspace,
        documentOperation: String?,
        pollSeconds: Int,
        readsDocumentCorpus: Bool = false
    ) {
        self.kind = kind
        self.documentOperation = documentOperation
        self.readsDocumentCorpus = readsDocumentCorpus
        self.pollSeconds = min(max(pollSeconds, Self.pollBounds.lowerBound),
                               Self.pollBounds.upperBound)
    }
}

/// Applications this machine can be pointed at.
public protocol AmbientApplicationIndex: Sendable {

    /// By logical id — the owner a dispatcher stamps on a binding.
    func registration(id: String) -> ApplicationRegistration?

    /// By exact process identity, case-insensitive — the lookup a watcher does.
    func registration(bundleID: String) -> ApplicationRegistration?

    /// Every registration, for the rosters that enumerate rather than resolve.
    var all: [ApplicationRegistration] { get }
}

public extension AmbientApplicationIndex {
    /// By place — the spelling callers downstream of routing hold.
    /// PIN: Defaulted extension, not a protocol requirement.
    func registration(place: AmbientPlace?) -> ApplicationRegistration? {
        guard let place, case .application(let id) = place else { return nil }
        return registration(id: id) ?? registration(bundleID: id)
    }
}

/// Empty index — no applications recognised beyond Mary's own worlds. Not an error.
public struct EmptyAmbientApplicationIndex: AmbientApplicationIndex {
    public init() {}
    public func registration(id: String) -> ApplicationRegistration? { nil }
    public func registration(bundleID: String) -> ApplicationRegistration? { nil }
    public var all: [ApplicationRegistration] { [] }
}

/// Default index when a caller did not hand one. Inversion — this package must not name the roster.
public enum AmbientApplicationIndexProvider {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var provider: (@Sendable () -> any AmbientApplicationIndex)?

    /// Task-tree roster; `current` prefers this over the process-wide install.
    @TaskLocal public static var scoped: (any AmbientApplicationIndex)?

    /// Install the live index. Last caller wins. Called at config and every `AbilityLibrary` activation.
    public static func install(_ resolve: @escaping @Sendable () -> any AmbientApplicationIndex) {
        lock.lock()
        defer { lock.unlock() }
        provider = resolve
    }

    public static var current: any AmbientApplicationIndex {
        if let scoped { return scoped }
        lock.lock()
        let resolved = provider
        lock.unlock()
        return resolved?() ?? EmptyAmbientApplicationIndex()
    }
}

/// A registry over a fixed list. The shape the app installs.
public struct AmbientApplicationRoster: AmbientApplicationIndex {
    public let all: [ApplicationRegistration]
    private let byID: [String: ApplicationRegistration]
    private let byBundleID: [String: ApplicationRegistration]

    public init(_ registrations: [ApplicationRegistration]) {
        self.all = registrations
        // First wins, both maps.
        var ids: [String: ApplicationRegistration] = [:]
        var bundles: [String: ApplicationRegistration] = [:]
        for registration in registrations {
            let key = registration.id.lowercased()
            if ids[key] == nil { ids[key] = registration }
            for bundleID in registration.bundleIdentifiers {
                let bundleKey = bundleID.lowercased()
                if bundles[bundleKey] == nil { bundles[bundleKey] = registration }
            }
        }
        self.byID = ids
        self.byBundleID = bundles
    }

    public func registration(id: String) -> ApplicationRegistration? {
        byID[id.lowercased()]
    }

    /// Exact bundle id first, then family. An exact id must never be outranked.
    public func registration(bundleID: String) -> ApplicationRegistration? {
        if let exact = byBundleID[bundleID.lowercased()] { return exact }
        return all.first { $0.owns(bundleID: bundleID) }
    }
}
