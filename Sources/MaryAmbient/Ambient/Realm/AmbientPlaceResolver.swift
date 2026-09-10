//
//  AmbientPlaceResolver.swift
//  MaryAmbient
//
//  WHAT: THE ONE bundleID → AmbientPlace ladder.
//  IN:   bundle identifiers (focus records, the Look faculty, any holder of one)
//  OUT:  AmbientPlace — native arm, browser workspace, registration, or host lane
//  PIN:  Lives beside AmbientPlace: resolving one is a Realm question, not a focus
//        one. The browser carve-out stays first; logical ids never contain dots.
//

import Foundation

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

    /// A LOGICAL application id — one served by more than one profile — as the
    /// place whose focus evidence says which profile is meant. Nil for a real
    /// bundle id. The turn loop asks this instead of knowing a browser exists.
    public static func logicalPlace(forApplication id: String) -> AmbientPlace? {
        id == browserApplicationID ? browserPlace : nil
    }

    /// Whether a bundle id can serve a logical place.
    public static func serves(_ place: AmbientPlace, bundleID: String) -> Bool {
        place == browserPlace && isBrowser(bundleID: bundleID)
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

    /// The registration that answers for the browser workspace: the browser
    /// the ledger evidences, else the first package realizing browsing. See
    /// `AmbientPlace.registration`.
    public static func browserRegistration() -> ApplicationRegistration? {
        let index = AmbientApplicationIndexProvider.current
        if let evidenced = WorkspaceFocusTracker.shared.evidenceProcess(for: browserPlace),
           let registration = index.registration(bundleID: evidenced),
           registration.profile.abilities.contains(.browsing) {
            return registration
        }
        return index.all
            .filter { $0.profile.abilities.contains(.browsing) }
            .min { $0.id < $1.id }
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
