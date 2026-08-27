//
//  ApplicationRegistration.swift
//  MaryAmbient
//
//  WHICH APPLICATIONS EXIST ON THIS MACHINE — asked here, answered above, and
//  deliberately not the same question as "which worlds does Mary ship".
//
//  `AmbientWorld` is a CLOSED enum with one case per compiled plugin owner, and
//  it stays that way. Its closedness is load-bearing: `AmbientWorld.swift`'s own
//  header records what happened when the enum was narrower than the set of
//  things that could produce a read — `from(pluginOwner:)` answered nil for
//  "calendar", `registerRead` guarded on it, and a calendar read "reached NOBODY
//  and was gone by the next turn". The repair was to make the enum TOTAL over
//  plugin owners, and the bijection that pins it is the reason a read can no
//  longer land nowhere.
//
//  THE FAILURE THIS FIXES is that same bug, one layer out. A Dynamic `.mary`
//  application package — Sketch, Keynote — has an owner id (`"sketch"`) that is
//  a validated logical application id, NOT a plugin owner, so it was never in
//  the bijection and `from(pluginOwner:)` answers nil for it. Every guard that
//  reads "no world ⇒ nothing to store" then drops its evidence silently:
//  an application observation succeeds, produces a summary, and reaches
//  nobody. Registered applications therefore need a first-class deposit into
//  `.applications` rather than an engine-specific side channel.
//
//  WHY NOT ANOTHER ENUM CASE. Because there is no bound on how many there would
//  be, and because `docs/architecture/DYNAMIC-APPLICATION-ABILITIES.md` lists
//  "Adding a `Sketch` case to `AmbientWorld`, `WritingApp`, or another closed
//  native enum" as an explicit non-goal. An application is DATA. A world is
//  VOCABULARY. Growing the vocabulary every time a user imports a package is
//  how the vocabulary stops meaning anything — and it would put a per-user list
//  inside a package that is supposed to be portable.
//
//  So the enum keeps naming the worlds Mary was built around, and this names
//  everything else the machine can be pointed at. The two are joined by
//  `legacyWorld`: an application that HAS a built-in counterpart projects onto
//  it, and one that does not rides the generic perception world while keeping
//  its own identity in the key. Nothing below this file learns the difference.
//

import Foundation

/// One application Mary can recognise, whether or not it has an
/// `AmbientWorld` of its own.
///
/// Derived from Native Plugin profiles plus admitted Dynamic package graphs.
/// Recognition is separate from execution availability on purpose: a provider
/// blocked by a missing macOS permission may still teach Mary that an exact
/// running bundle is Sketch.
public struct ApplicationRegistration: Sendable, Equatable {

    /// The validated logical application id — `"sketch"`. This is what the
    /// dispatcher stamps on a binding as its owner, and what memory attribution
    /// uses; it is NEVER a bundle identifier.
    public var id: String

    /// Everything routing already knew about this application. It carries the
    /// aliases, abilities and target classes, so this type adds identity and
    /// taxonomy rather than restating them.
    public var profile: ApplicationProfile

    /// Exact process identities, matched case-insensitively. Human aliases
    /// answer "did the user name Sketch?"; these answer "did this fact actually
    /// come from Sketch?" — keeping both stops routing comparing unlike
    /// namespaces.
    public var bundleIdentifiers: Set<String>

    /// The process FAMILY, when the package declared one. See
    /// `ApplicationProfile.applicationBundlePrefix` — this is the same value,
    /// carried here so `owns(bundleID:)` is one question with one answer.
    public var bundleIdentifierPrefix: String?

    /// WHAT KIND of thing this application is, in the ambient taxonomy.
    ///
    /// Supplied by the registration rather than derived from `legacyWorld`,
    /// because the projection world is a rendering detail and the class is not:
    /// an application that rides `.applications` may still be workspace-class, and
    /// `.applications` itself is `.perceptionOnly`. Reading the class off the
    /// projection would silently deny eyes to every registered application.
    public var worldClass: AmbientWorldClass

    /// What the user is told this is called. Mary-derived from the logical
    /// id for a Dynamic package — a package-authored display title is inspector
    /// metadata and may not rename retrieved application knowledge.
    public var displayName: String

    /// HOW THIS APPLICATION CAN BE OBSERVED, when it can be at all.
    ///
    /// Nil is the honest default and the common case: a package that teaches
    /// Mary to OPERATE an application has not thereby taught her to SEE it.
    /// Sight is a separate claim and it has to be earned by declaring what
    /// Mary can poll — otherwise a workspace-class registration would render
    /// a card claiming live knowledge of a document nothing is reading.
    public var perception: ApplicationPerception?

    /// The closed world this projects onto for views that still take one.
    ///
    /// Non-nil ONLY for an application that genuinely is a built-in world
    /// (every Native Plugin: `"calendar"` → `.calendar`). Nil is the ordinary
    /// case for a Dynamic package, and `AmbientPlace` then rides the generic
    /// perception world with `id` as its discriminator.
    public var legacyWorld: AmbientWorld?

    public init(
        id: String,
        profile: ApplicationProfile,
        bundleIdentifiers: Set<String> = [],
        bundleIdentifierPrefix: String? = nil,
        worldClass: AmbientWorldClass,
        displayName: String? = nil,
        perception: ApplicationPerception? = nil,
        legacyWorld: AmbientWorld? = nil
    ) {
        self.id = id
        self.profile = profile
        self.bundleIdentifiers = bundleIdentifiers
        self.bundleIdentifierPrefix = bundleIdentifierPrefix
        self.worldClass = worldClass
        self.displayName = displayName ?? legacyWorld?.displayName ?? profile.title
        self.perception = perception
        self.legacyWorld = legacyWorld
    }

    /// IS THIS RUNNING PROCESS THIS APPLICATION? — the ONE membership
    /// predicate, exact ids first and then the declared family.
    ///
    /// It exists because the tree had this question answered in two places
    /// with two different rules: the focus tracker asked for the family while
    /// the app side asked for an exact id, so a next-major build was
    /// focus-tracked and pinnable yet reported "not running" by the very
    /// inspector that exists to explain it. Anything that needs to LAUNCH
    /// still asks `bundleIdentifiers` — a family cannot be launched.
    public func owns(bundleID: String) -> Bool {
        let lowered = bundleID.lowercased()
        if bundleIdentifiers.contains(where: { $0.lowercased() == lowered }) {
            return true
        }
        guard let prefix = bundleIdentifierPrefix?.lowercased(), !prefix.isEmpty
        else { return false }
        return Self.isInFamily(lowered, prefix: prefix)
    }

    /// A FAMILY MATCH ENDS ON A BOUNDARY, not anywhere in the middle of a word.
    ///
    /// A raw `hasPrefix` was the obvious rule and it is wrong in a way only a
    /// second vendor exposes: `com.example.mirrorwell` prefixes
    /// `com.example.mirrorwelling`, which is a DIFFERENT PRODUCT, and matching
    /// it would hand one application's registration — its eyes, its passages,
    /// its pin — to another company's app. The acceptance suite for a taught
    /// application caught exactly that.
    ///
    /// What counts as a boundary is decided by how vendors actually version:
    ///
    ///   - nothing at all (`…mirrorwell`), the plain identity;
    ///   - a DIGIT run (`…scrivener3`), which is the majority convention and
    ///     the reason this cannot simply require a dot;
    ///   - a DOT (`…scrivener3.setapp`, `…mirrorwell.beta`), a new component.
    ///
    /// A letter immediately after the prefix is a different word, and a
    /// different word is a different application.
    public static func isInFamily(_ bundleID: String, prefix: String) -> Bool {
        guard bundleID.hasPrefix(prefix) else { return false }
        var rest = Substring(bundleID.dropFirst(prefix.count))
        if rest.isEmpty { return true }
        while let first = rest.first, first.isNumber { rest = rest.dropFirst() }
        return rest.isEmpty || rest.first == "."
    }

    /// EYES ARE BOTH HALVES: workspace class AND a declared way to be observed.
    ///
    /// Built-in and registered worlds both keep taxonomy separate from live
    /// observation. A registration additionally needs Mary-owned perception
    /// machinery; package-authored workspace language can never declare its
    /// way into sight it does not have.
    /// Is anything actually reading this application's documents?
    public var observesDocuments: Bool {
        perception?.observesDocuments == true
    }

    /// What it calls one of its documents, singular. `"document"` when it did
    /// not say — a neutral word, and honest: Mary does not know their word.
    public var documentNoun: String {
        profile.documentNoun ?? "document"
    }

    public var hasEyes: Bool {
        worldClass == .workspace && perception?.observesDocuments == true
    }

    /// The lane this application's facts key under.
    ///
    /// THE BROWSER CARVE-OUT (mirrors `AmbientPlaceResolver.place`): a dynamic
    /// registration whose process identities are ALL browsers (chrome.mary,
    /// claiming com.google.Chrome) files on the one shared browser workspace,
    /// not a place of its own. The browser is ONE workspace regardless of
    /// which plugin drives it; a package registration grants verbs, it never
    /// splits the lane's facts and memory by engine. Native plugins carry a
    /// `legacyWorld` and never reach the carve-out.
    public var place: AmbientPlace {
        if legacyWorld == nil, !bundleIdentifiers.isEmpty,
           bundleIdentifiers.allSatisfy({ AmbientPlaceResolver.isBrowser(bundleID: $0) }) {
            return AmbientPlaceResolver.browserPlace
        }
        return AmbientPlace(world: legacyWorld ?? .applications,
                            application: legacyWorld == nil ? id : nil)
    }
}

/// WHAT BONNIE MAY POLL to keep a registered application's document in view.
///
/// Declared by the package, validated at admission, and deliberately tiny: a
/// non-mutating operation and how often it may run. Everything else about
/// perception — the Accessibility selection read, the fact slots, the freshness
/// rules — is Mary's own and identical for every application.
public struct ApplicationPerception: Sendable, Equatable {

    /// WHAT THE PACKAGE CLAIMED it can be observed as. The single source of
    /// truth for the registration's class too, so a package cannot declare
    /// workspace in one field and something else in another.
    public enum Kind: String, Sendable, Equatable {
        /// Live selection only, through the generic Accessibility reader.
        case perceptionOnly
        /// Selection plus a document channel — requires `documentOperation`.
        case workspace
    }

    public var kind: Kind

    /// The declared read operation Mary runs on a timer. It must be
    /// non-mutating; an operation that turned out to write would run against
    /// the user's document every few seconds, unasked, for as long as the
    /// package stayed installed.
    ///
    /// One of the two ways `.workspace` can be satisfied — see
    /// `observesDocuments`.
    public var documentOperation: String?

    /// MARY'S OWN CORPUS READER IS THE CHANNEL, rather than a declared
    /// operation.
    ///
    /// Set at admission when the package declares a `documentCorpus`, never by
    /// the package directly — the schema has no field for it. The distinction
    /// matters because the two halves of `hasEyes` have to stay independently
    /// earned: `.workspace` is a claim, and this is the evidence that
    /// something is actually reading. A package could otherwise claim the
    /// class and get a card asserting live knowledge nothing is polling.
    public var readsDocumentCorpus: Bool

    /// Seconds between document polls.
    ///
    /// Bounded well above the Accessibility selection cadence on purpose: a
    /// selection read is an attribute fetch, and this is a subprocess against
    /// the application's own tooling. Treating them as the same cost is how a
    /// perception layer turns into a background load the user can feel.
    public var pollSeconds: Int

    /// The floor and ceiling the validator enforces.
    public static let pollBounds = 15...300

    /// The ambient class this declaration implies. Derived rather than stored
    /// beside it, because two fields that must agree eventually disagree.
    public var worldClass: AmbientWorldClass {
        switch kind {
        case .workspace:      return .workspace
        case .perceptionOnly: return .perceptionOnly
        }
    }

    /// IS ANYTHING ACTUALLY READING THIS APPLICATION'S DOCUMENT?
    ///
    /// Two channels, one question. A compiled world declares an operation Mary
    /// polls; a taught application hands Mary's corpus reader a layout to read.
    /// Callers ask this rather than testing either field, so adding a third
    /// channel later does not mean auditing every eyes-gated site again.
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

/// What the ambient layer needs to know about the applications this machine
/// can be pointed at — three members, and nothing more than that.
///
/// Keeping it this narrow is the point, exactly as with
/// `AbilityCapabilityIndex`: it is what lets this package build against
/// MaryFoundation alone, and what makes the layer portable. A host with an
/// entirely different notion of "installed application" satisfies three members
/// and the evidence model works unchanged.
public protocol AmbientApplicationIndex: Sendable {

    /// By logical id — the owner a dispatcher stamps on a binding.
    func registration(id: String) -> ApplicationRegistration?

    /// By exact process identity, matched case-insensitively. This is the
    /// lookup a watcher does, because a watcher only ever knows a bundle id.
    func registration(bundleID: String) -> ApplicationRegistration?

    /// Every registration, for the rosters that enumerate rather than resolve.
    var all: [ApplicationRegistration] { get }
}

public extension AmbientApplicationIndex {
    /// By place — the spelling every caller downstream of routing actually
    /// holds.
    ///
    /// A DEFAULTED EXTENSION, not a protocol requirement: it is composed from
    /// `registration(id:)` and there is no index for which a different answer
    /// would be correct. A lane is never a registration — Mary's own faculties
    /// are not applications, and asking for one is a question, not a miss.
    func registration(place: AmbientPlace?) -> ApplicationRegistration? {
        guard let place, case .application(let id) = place else { return nil }
        return registration(id: id) ?? registration(bundleID: id)
    }
}

/// The answer when nothing has been installed: this machine has no
/// applications Mary recognises beyond its own worlds.
///
/// Deliberately not an error. A turn can run before the registry has loaded,
/// and "I know of no applications" is the honest reading of that state — the
/// built-in worlds still answer for themselves, which is exactly the behaviour
/// that shipped before this file existed.
public struct EmptyAmbientApplicationIndex: AmbientApplicationIndex {
    public init() {}
    public func registration(id: String) -> ApplicationRegistration? { nil }
    public func registration(bundleID: String) -> ApplicationRegistration? { nil }
    public var all: [ApplicationRegistration] { [] }
}

/// Where the ambient layer looks when a caller did not hand it an index.
///
/// An inversion rather than a direct call, because the roster is assembled a
/// layer above — from compiled plugins and admitted Dynamic package graphs —
/// and this package must not name either.
public enum AmbientApplicationIndexProvider {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var provider: (@Sendable () -> any AmbientApplicationIndex)?

    /// A ROSTER SCOPED TO ONE TASK TREE, which `current` prefers over the
    /// installed one.
    ///
    /// The installed provider is process-wide, and that is right for an app
    /// with one composition root. It is wrong for a test suite: swift-testing
    /// runs suites concurrently, so a test that installs a roster and clears it
    /// on the way out clears it underneath whatever else is mid-turn. Scoping
    /// through a task local lets a caller answer this question for its own work
    /// without answering it for everybody — the same reason
    /// `AbilityTurnContext.$snapshot` exists.
    @TaskLocal public static var scoped: (any AmbientApplicationIndex)?

    /// Installs the live index. Idempotent; the last caller wins.
    ///
    /// Called at configuration AND on every `AbilityLibrary` activation, since
    /// importing or removing a package changes the answer for the next turn.
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
        // FIRST WINS, both times. The roster is assembled native-first, and a
        // Native identity is a strict admission boundary — a Dynamic package
        // that collides with one is rejected upstream rather than shadowing it
        // here, so this only has to be deterministic, not adjudicating.
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

    /// EXACT FIRST, THEN THE FAMILY. An exact id is an unambiguous claim and
    /// must never be outranked; the family scan is the fallback that keeps
    /// next year's build of a taught application recognised instead of
    /// silently becoming "some app I don't know".
    ///
    /// Deterministic under a tie: registrations are scanned in roster order,
    /// which is assembled native-first, and a Dynamic package colliding with a
    /// Native identity is rejected at admission rather than adjudicated here.
    public func registration(bundleID: String) -> ApplicationRegistration? {
        if let exact = byBundleID[bundleID.lowercased()] { return exact }
        return all.first { $0.owns(bundleID: bundleID) }
    }
}
