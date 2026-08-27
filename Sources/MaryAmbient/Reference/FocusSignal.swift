//
//  FocusSignal.swift
//  MaryBrain
//
//  FOCUS AS A RESPONDER LAYER — the ranked evidence ledger behind the single
//  lead box.
//
//  The tracker's `leadBox` holds ONE `(place, at)` and last-writer-wins;
//  every downstream consumer projects that one value. That was the right
//  first shape and it stays authoritative: doctrine, roster hoist, and the
//  deposit subject need exactly one owner per turn. What it cannot express
//  is the user this system actually serves — Sketch, Xcode, Pages, and a
//  browser open AT ONCE, hopping between them — where the merely-not-lead
//  places silently degrade to one-line mentions and a glance at another
//  window (a Look) is no signal at all.
//
//  The ledger keeps ONE freshest evidence stamp per place, written by the
//  same funnels that already stamp the lead (note/noteWriting → activity;
//  record/noteDynamicApplication → activation) plus one new responder:
//  `noteGlance` — a successful look_at_screen at that place's app. A glance
//  is a GLANCE, not a move: it never touches the lead, and it decays on its
//  own horizon. `signal()` projects the ledger into {lead, co-active,
//  glanced}; when only one place has evidence it answers byte-identically to
//  `leadPlace()` — the parity rule the pinned focus tests stand on.
//
//  THE BROWSER IS A WORKSPACE (user decision, 2026-08-11): not a web-editor
//  whitelist — a user can write in any UX a browser hosts, so the workspace
//  is denoted simply "browser" and lives on the host lane as the logical
//  application id `browser`. Safari and Chrome bundles both resolve to it.
//  This replaces the old doctrine that browsers leave the focus signal
//  alone entirely; a browser activation now stamps ledger EVIDENCE (the
//  responder layer sees it) while lead promotion arrives with the merged
//  rendering that can actually show a browser section.
//

import Foundation

/// The kind of evidence a place holds in the ledger, in responder-precedence
/// order (highest first). Turn overrides, pins, and routed selections are
/// deliberately NOT ledger entries — they are turn-scoped projections the
/// tracker already owns; the ledger records durable ambient evidence.
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
    /// The CONCRETE process behind the stamp, when the place is a logical
    /// grouping ("browser" covers Safari AND Chrome — this says which one).
    /// Lets `type_in_web_page` resolve "the freshest browser evidence" to an
    /// actual app, and lets termination clear only the quitting process's
    /// claim. Defaulted — source-compatible.
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

/// The projected signal: one lead (today's answer, byte-identical), the
/// places with fresh evidence beside it, and which of those are only glanced.
public struct FocusSignal: Sendable, Equatable {
    public var lead: AmbientPlace?
    /// Fresh non-lead places, strongest-evidence-then-recency ranked.
    public var coActive: [AmbientPlace]
    /// The subset of `coActive` whose freshest evidence is a glance.
    public var glanced: Set<AmbientPlace>

    public init(
        lead: AmbientPlace? = nil,
        coActive: [AmbientPlace] = [],
        glanced: Set<AmbientPlace> = []
    ) {
        self.lead = lead
        self.coActive = coActive
        self.glanced = glanced
    }

    /// How long non-lead activity/activation evidence keeps a place
    /// co-active. Deliberately shorter than `signalHorizon` (the lead's
    /// 20 min): an app untouched five minutes while the user actively
    /// bounces degrades to today's one-liner, not to a standing section.
    public static let coActiveHorizon: TimeInterval = 5 * 60
    /// A glance is a deliberate ask — long enough to say "now write it in
    /// Pages", short enough not to haunt the next task.
    public static let glanceHorizon: TimeInterval = 10 * 60

    public static func horizon(for kind: FocusEvidenceKind) -> TimeInterval {
        kind == .glance ? glanceHorizon : coActiveHorizon
    }
}

/// THE ONE bundleID → place LADDER, extracted from `record(bundleID:)`'s
/// arms so the Look faculty (and anything else holding only a bundle id)
/// resolves places by the same rules the focus signal uses. The tracker's
/// `record` keeps its behavior-identical arms (they also stamp focus and
/// writing-app state the resolver must not); membership questions ask here.
public enum AmbientPlaceResolver {

    /// The browser workspace's logical application id on the host lane.
    public static let browserApplicationID = "browser"

    /// The browser workspace place — Safari, Chrome, and any Chromium
    /// variant sharing their prefixes all resolve to this one workspace.
    public static var browserPlace: AmbientPlace {
        AmbientPlace(world: .applications, application: browserApplicationID)
    }

    /// Browser bundle prefixes. Prefix-matched (like Scrivener's family
    /// rule) so Chrome Beta/Canary and Safari Technology Preview register.
    /// WHICH BUNDLES ARE BROWSERS, and what to call each one.
    ///
    /// KINDS CLOSED, INSTANCES OPEN — the rule this file's own place carve-out
    /// is built on, applied to the roster rather than only to the place. The
    /// browser WORKSPACE is closed vocabulary and stays one place. The set of
    /// browsers filling it is not: Safari is a compiled Native Plugin with a
    /// closed `AmbientWorld` case, and everything else arrives as a Dynamic
    /// `.mary` package that declares its own bundle identifiers and realizes
    /// the `browsing` Ability.
    ///
    /// So Chrome is NOT written down here. It was, briefly, and that was the
    /// same mistake in miniature as the one this whole change is undoing: a
    /// fact the package already states, restated in compiled Swift where it
    /// could drift — and where the next browser package to arrive would be
    /// invisible to the focus ledger however correctly it declared itself.
    /// `chrome.mary` says `bundleIdentifiers: ["com.google.Chrome"]` and
    /// realizes `browsing.*`; that IS the registration, and this reads it.
    ///
    /// The discovered half comes through `AmbientApplicationIndex`, the same
    /// injected seam the rest of this layer uses to stay above MaryFoundation
    /// alone. A host that has installed nothing still answers Safari.
    public static var browserIdentities: [(prefix: String, displayName: String)] {
        var identities: [(prefix: String, displayName: String)] = [
            (WorkspaceApplicationIdentity.safari, "Safari"),
        ]
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

    /// What to call the browser bundle, when it is one this build knows.
    ///
    /// Longest prefix first, so a package claiming a more specific id than
    /// another is named by its own registration rather than by whichever
    /// shorter prefix happened to be checked first.
    public static func browserName(bundleID: String) -> String? {
        browserIdentities
            .filter { bundleID.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }?
            .displayName
    }

    /// The engine the ledger says actually led the browser workspace, named.
    /// Nil when nothing is evidenced — "Browser" is the honest label then, and
    /// guessing an engine here would be the very confidence this whole change
    /// exists to remove.
    public static func evidencedBrowserName() -> String? {
        WorkspaceFocusTracker.shared
            .evidenceProcess(for: browserPlace)
            .flatMap(browserName(bundleID:))
    }

    /// Called on every focus record and every place resolution, so it answers
    /// the compiled case without building the discovered list at all, and
    /// scans registrations lazily rather than materializing tuples.
    public static func isBrowser(bundleID: String) -> Bool {
        if bundleID.hasPrefix(WorkspaceApplicationIdentity.safari) { return true }
        return AmbientApplicationIndexProvider.current.all.contains { registration in
            registration.profile.abilities.contains(.browsing)
                && registration.bundleIdentifiers.contains { bundleID.hasPrefix($0) }
        }
    }

    /// The place a bundle id belongs to: the five native workspace arms,
    /// then the browser workspace, then registered dynamic applications,
    /// then the host lane's generic `.applications` (no application id — the
    /// same lane OtherAppsWatcher files generic selections into).
    ///
    /// THE BROWSER CARVE-OUT: the browser rung sits ABOVE the registration
    /// rung on purpose. A dynamic package may register a browser bundle
    /// (chrome.mary claims com.google.Chrome so its operations can drive
    /// Chrome), but the browser is ONE workspace regardless of which plugin
    /// drives it — pulling Chrome into a `.application("chrome")` place would
    /// split the browser lane's facts, ledger evidence, and deposited memory
    /// away from Safari's. Registration grants verbs; it never re-homes the
    /// workspace.
    public static func factPlace(forBundleID bundleID: String) -> AmbientPlace {
        // The browser carve-out stays FIRST and is the only special case
        // left: the browser is deliberately ONE workspace across engines, so
        // a registered Chrome package must not pull Chrome into its own place
        // and split the lane's facts, ledger and memory away from Safari's.
        // Registration grants verbs; it never re-homes the workspace.
        if isBrowser(bundleID: bundleID) { return browserPlace }
        if let registration = AmbientApplicationIndexProvider.current
            .registration(bundleID: bundleID),
           registration.legacyWorld == nil {
            return registration.place
        }
        return .lane(.applications)
    }

    /// THE IDENTITY-BEARING LADDER — the cursor-obvious lead's place. Same
    /// rungs as `factPlace(forBundleID:)` except the terminal: a generic app
    /// keeps its identity (`.applications` + the BUNDLE ID as the open-form
    /// application id) instead of collapsing into the anonymous host lane.
    /// Bundle id, not localizedName, because it is the machine identity
    /// termination can match exactly; display honesty comes from
    /// `AmbientApplicationDirectory` via `AmbientPlace.displayName`.
    /// `factPlace(forBundleID:)` stays byte-identical — it is the FACT lane
    /// OtherAppsWatcher files generic selections into; changing its terminal
    /// would orphan fact-place matching.
    ///
    /// Namespace note: logical application ids ("browser", "sketch") never
    /// contain dots; bundle ids always do — the two never collide.
    public static func applicationPlace(forBundleID bundleID: String) -> AmbientPlace {
        let shared = factPlace(forBundleID: bundleID)
        if shared == .lane(.applications) {
            return AmbientPlace(world: .applications, application: bundleID)
        }
        return shared
    }
}
