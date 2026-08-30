//
//  FocusSignal.swift
//  MaryBrain
//
//  WHAT: Focus as a responder layer — ranked evidence ledger behind the single lead box.
//  IN:   WorkspaceFocusTracker funnels
//  OUT:  AmbientContextStore.noteLead / co-active places
//  PIN:  leadBox stays last-writer-wins and authoritative; ledger keeps one stamp per place.
//

import CoreGraphics
import Foundation

/// The kind of evidence a place holds in the ledger, in responder-precedence order (highest
/// first).
public enum FocusEvidenceKind: Int, Sendable, Comparable, Equatable {
    /// A watcher saw REAL WORK in the place (an edit, a document change).
    case activity = 2
    /// The place's application was activated / came frontmost.
    case activation = 1
    /// A successful look_at_screen at the place's app — sight, not presence.
    /// Never leads; co-activates so "look there, write here" carries context.
    case glance = 0

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One place's freshest evidence.
public struct FocusEvidence: Sendable, Equatable {
    public var place: AmbientPlace
    public var kind: FocusEvidenceKind
    public var at: Date
    /// The CONCRETE process behind the stamp, when the place is a logical grouping ("browser"
    /// covers Safari AND Chrome — this says which one).
    public var processBundleID: String?

    public init(
        place: AmbientPlace,
        kind: FocusEvidenceKind,
        at: Date,
        processBundleID: String? = nil
    ) {
        self.place = place
        self.kind = kind
        self.at = at
        self.processBundleID = processBundleID
    }
}

/// Pane-level look target: declared editor identity + screen frame.
public struct FocusPaneTarget: Sendable, Equatable {
    public var place: AmbientPlace
    /// `role|label` — same identity the published AX tree uses.
    public var identity: String
    /// Global top-left AX screen coordinates.
    public var frame: CGRect

    public init(place: AmbientPlace, identity: String, frame: CGRect) {
        self.place = place
        self.identity = identity
        self.frame = frame
    }
}

/// The projected signal: one lead (today's answer, byte-identical), the
/// places with fresh evidence beside it, and which of those are only glanced.
public struct FocusSignal: Sendable, Equatable {
    public var lead: AmbientPlace?
    /// Fresh non-lead places, strongest-evidence-then-recency ranked.
    public var coActive: [AmbientPlace]
    /// The subset of `coActive` whose freshest evidence is a glance.
    public var glanced: Set<AmbientPlace>
    /// Declared editor pane whose bbox justifies look_at_screen.
    public var lookTarget: FocusPaneTarget?

    public init(
        lead: AmbientPlace? = nil,
        coActive: [AmbientPlace] = [],
        glanced: Set<AmbientPlace> = [],
        lookTarget: FocusPaneTarget? = nil
    ) {
        self.lead = lead
        self.coActive = coActive
        self.glanced = glanced
        self.lookTarget = lookTarget
    }

    /// How long non-lead activity/activation evidence keeps a place co-active. Deliberately
    /// shorter than `signalHorizon` (the lead's 20 min): an app untouched five minutes while
    /// the user actively bounces degrades to today's one-liner, not to a standing section.
    public static let coActiveHorizon: TimeInterval = 5 * 60
    /// A glance is a deliberate ask — long enough to say "now write it in
    /// Pages", short enough not to haunt the next task.
    public static let glanceHorizon: TimeInterval = 10 * 60

    public static func horizon(for kind: FocusEvidenceKind) -> TimeInterval {
        kind == .glance ? glanceHorizon : coActiveHorizon
    }
}

/// THE ONE bundleID → place LADDER, extracted from `record(bundleID:)`'s arms so the Look
/// faculty (and anything else holding only a bundle id) resolves places by the same rules
/// the focus signal uses.
public enum AmbientPlaceResolver {

    /// The browser workspace's logical application id on the host lane.
    public static let browserApplicationID = "browser"

    /// The browser workspace place — Safari, Chrome, and any Chromium
    /// variant sharing their prefixes all resolve to this one workspace.
    public static var browserPlace: AmbientPlace {
        AmbientPlace(attention: .applications, application: browserApplicationID)
    }

    /// Browser bundle prefixes. Prefix-matched so Chrome Beta/Canary and Safari Technology
    /// Preview register. KINDS CLOSED, INSTANCES OPEN.
    public static var browserIdentities: [(prefix: String, displayName: String)] {
        var identities: [(prefix: String, displayName: String)] = []
        for registration in AmbientApplicationIndexProvider.current.all
        where registration.profile.abilities.contains(.browsing) {
            for bundleID in registration.bundleIdentifiers.sorted()
            where !identities.contains(where: { bundleID.hasPrefix($0.prefix) }) {
                identities.append((bundleID, registration.displayName))
            }
        }
        return identities
    }

    /// Prefix-matched (like Scrivener's family rule) so Chrome Beta/Canary and
    /// Safari Technology Preview register.
    public static var browserBundlePrefixes: [String] {
        browserIdentities.map(\.prefix)
    }

    /// What to call the browser bundle, when it is one this build knows. Longest prefix first,
    /// so a package claiming a more specific id than another is named by its own registration
    /// rather than by whichever shorter prefix happened to be checked first.
    public static func browserName(bundleID: String) -> String? {
        browserIdentities
            .filter { bundleID.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }?
            .displayName
    }

    /// The engine the ledger says actually led the browser workspace, named. Nil when nothing
    /// is evidenced — "Browser" is the honest label then, and guessing an engine here would be
    /// the very confidence this whole change exists to remove.
    public static func evidencedBrowserName() -> String? {
        WorkspaceFocusTracker.shared
            .evidenceProcess(for: browserPlace)
            .flatMap(browserName(bundleID:))
    }

    /// Called on every focus record and every place resolution, so it answers
    /// the compiled case without building the discovered list at all, and
    /// scans registrations lazily rather than materializing tuples.
    public static func isBrowser(bundleID: String) -> Bool {
        AmbientApplicationIndexProvider.current.all.contains { registration in
            registration.profile.abilities.contains(.browsing)
                && registration.bundleIdentifiers.contains { bundleID.hasPrefix($0) }
        }
    }

    /// The place a bundle id belongs to: the five native workspace arms, then the browser
    /// workspace, then registered dynamic applications, then the host lane's generic
    /// `.applications` . THE BROWSER CARVE-OUT: the browser rung sits ABOVE the registration.
    public static func factPlace(forBundleID bundleID: String) -> AmbientPlace {
        // The browser carve-out stays FIRST and is the only special case left: the browser is
        // deliberately ONE workspace across engines.
        if isBrowser(bundleID: bundleID) { return browserPlace }
        if let registration = AmbientApplicationIndexProvider.current
            .registration(bundleID: bundleID),
           registration.legacyAttention == nil {
            return registration.place
        }
        return .lane(.applications)
    }

    /// THE IDENTITY-BEARING LADDER — the cursor-obvious lead's place. Namespace note: logical
    /// application ids ("browser", "sketch") never contain dots; bundle ids always do — the two
    /// never collide.
    public static func applicationPlace(forBundleID bundleID: String) -> AmbientPlace {
        let shared = factPlace(forBundleID: bundleID)
        if shared == .lane(.applications) {
            return AmbientPlace(attention: .applications, application: bundleID)
        }
        return shared
    }
}
