//
//  PerceptionCard.swift
//  MaryRuntime
//
//  ONE WATCHED PLACE AS THE DEBUGGER SEES IT — the join key between the
//  window tiles (an SCWindow's owning bundle id) and Mary's parsed truth.
//
//  Cards are the SINGLE source for both the tile captions and the inspector
//  detail. Pure data, built by the snapshot view model, serialized by the
//  report.
//

import Foundation
import MaryPlugin
import MaryAmbient
import MaryBrain
import MaryFoundation

/// The subject of one card.
///
/// IT USED TO BE AN ENUM with four compiled cases and one open one, and the
/// comment above it already knew that was wrong: "the kinds stay closed and
/// the instances open". In Mary there are no compiled cases left to keep
/// closed — every place is a taught application — so the type is what it was
/// always describing: a place, with the debugger's questions on it.
///
/// A PANE THAT SILENTLY OMITS A WATCHED APPLICATION is the pane failing at the
/// one job it has, which is why `current()` reads the live roster rather than
/// an `allCases` frozen at compile time: which cards exist changes whenever a
/// package is imported or removed.
package struct PerceptionWorld: Hashable, Identifiable {

    package let place: AmbientPlace

    package init(_ place: AmbientPlace) { self.place = place }

    /// The stable string a tile tap writes and the inspector reads back.
    package var rawValue: String { place.memoryToken }
    package var id: String { rawValue }

    package init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.init(.application(rawValue))
    }

    package func matches(bundleID: String) -> Bool {
        AmbientApplicationIndexProvider.current
            .registration(bundleID: bundleID)?.place == place
    }

    /// The pin this card's tile plants. Nil when the place declares no
    /// discipline — a pin at a register that does not exist would leave the
    /// arbiter holding one it cannot honour.
    package var pinnedWorld: PinnedWorld? {
        guard let id = place.application, let focus = place.focus else { return nil }
        return PinnedWorld(applicationID: id, focus: focus)
    }

    package var hasLiveObserver: Bool { place.hasEyes }

    /// EVERY PLACE THE ROSTER KNOWS, in a stable order.
    ///
    /// Sorted by token rather than by a hand-written list, because a debugger
    /// whose rows move between launches is a debugger nobody trusts.
    package static func current() -> [PerceptionWorld] {
        AmbientApplicationIndexProvider.current.all
            .map { PerceptionWorld($0.place) }
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// The narrower live-eyes set.
    package static var watched: [PerceptionWorld] { current().filter(\.hasLiveObserver) }

    package var displayName: String {
        AmbientApplicationIndexProvider.current
            .registration(place: place)?.displayName ?? place.displayName
    }

    /// The report header's per-place id.
    package var representativeBundleID: String {
        AmbientApplicationIndexProvider.current
            .registration(place: place)?.bundleIdentifiers.sorted().first
            ?? place.memoryToken
    }

    /// The canonical pin string for the debugger's badge mirror.
    package var pinKey: String { pinnedWorld?.badgeKey ?? rawValue }
}

extension PinnedWorld {
    /// THE canonical pin-string mapping — the debugger's badge mirror and the
    /// tile badge both read this, and nothing else may spell it.
    ///
    /// The logical application id IS the roster's owner vocabulary, so there
    /// is no second spelling to keep in step. Its predecessor had three arms
    /// for two compiled worlds and one open one, which is how a badge came to
    /// disagree with the pin it mirrored.
    package var badgeKey: String { applicationID }

    /// The report's pin token: `writing(quill)`, `coding(forge)`.
    var reportToken: String {
        "\(focus == .coding ? "coding" : "writing")(\(applicationID))"
    }
}

package struct PerceptionCard: Identifiable, Equatable {

    /// Why (or how far) Mary can't see — precedence pinned in the builder:
    /// appNotRunning → watcherInactive → automationDenied → pollFailure →
    /// accessibilityLimited. Running gates denied because deniedBox survives
    /// an app quit; a "denied" caption on a quit app would be a lie.
    package enum Blindness: Equatable {
        /// No watcher exists. TextEdit ships this way deliberately: its
        /// recipes read notes on demand and its writer reaches a background
        /// window without one, so there is nothing to poll — but the world IS
        /// registered, so the pane owes it a card that says so rather than
        /// omitting it.
        case noWatcher
        /// Plugin disabled → the poll loop isn't running.
        case watcherInactive
        case appNotRunning
        /// TCC refused the Apple Event.
        case automationDenied
        /// Scrivener partial: stats live, focused document blind.
        case accessibilityLimited
        /// The last poll's raw failure text, capped at the watcher.
        case pollFailure(String)

        /// Kebab token for the report — greppable, stable.
        package var label: String {
            switch self {
            case .noWatcher: return "no-watcher"
            case .watcherInactive: return "watcher-inactive"
            case .appNotRunning: return "app-not-running"
            case .automationDenied: return "automation-denied"
            case .accessibilityLimited: return "accessibility-limited"
            case .pollFailure: return "poll-failure"
            }
        }

        /// The one-line fix.
        package var remedy: String {
            switch self {
            case .noWatcher:
                return "Mary has no watcher for this app — its tiles stay honest icons."
            case .watcherInactive:
                return "Enable the plugin in Mary's Settings, then reopen this pane."
            case .appNotRunning:
                return "Launch the app — the watcher idles while it isn't running."
            case .automationDenied:
                return "Grant Automation for this app in System Settings → Privacy & Security → Automation."
            case .accessibilityLimited:
                return "Grant Accessibility in System Settings → Privacy & Security — stats stay live, but the focused document is out of reach."
            case .pollFailure:
                return "See last-error — the next successful poll clears it."
            }
        }
    }

    package struct Field: Equatable {
        package let label: String
        package let value: String

        package init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    package let world: PerceptionWorld
    package var isRunning: Bool
    /// Nil = seeing clearly. accessibilityLimited is PARTIAL — fields still
    /// render; every other case replaces them.
    package var blindness: Blindness?
    /// Freshness anchor (the watcher snapshot's capture stamp).
    package var capturedAt: Date?
    /// Tile overlay ∩ inspector detail: tiles show the first 2–3, the
    /// inspector shows all.
    package var fields: [Field]
    /// PER-WINDOW FIELDS, for a world that has more than one window open —
    /// keyed by `CGWindowID`, which is the same integer the tiles carry as
    /// `WindowTile.id`.
    ///
    /// THE BUG THIS FIXES, reported from the pane: with thirteen TextEdit
    /// notes open, every one of the thirteen tiles was captioned with the
    /// FRONT note's name and size, because a caption was re-derived from the
    /// world's card and a world has one card. Three visibly different notes
    /// read "mary-raise-a.txt / 16 characters" underneath all three. The
    /// assumption was never written down because until TextEdit no world could
    /// break it: one document per app made "the world's card" and "this
    /// window's card" the same sentence.
    ///
    /// EXACT, NOT MATCHED BY TITLE. Measured: TextEdit's AppleScript
    /// `id of window` and Core Graphics' `kCGWindowNumber` are the SAME
    /// integer (109 = "Untitled 18", and so on for all eleven). So the join
    /// needs no title comparison — which is fortunate, because eleven notes
    /// called `Untitled N` would defeat one.
    ///
    /// Empty for every single-window world, and `fields(forWindow:)` then
    /// answers exactly what `fields` always did.
    var windowFields: [Int: [Field]] = [:]

    /// The fields describing ONE window: its own when the world published
    /// them, the world's otherwise. The fallback is what keeps Xcode, Pages
    /// and Scrivener rendering precisely as before.
    package func fields(forWindow windowID: Int?) -> [Field] {
        guard let windowID, let own = windowFields[windowID] else { return fields }
        return own
    }
    /// The watcher's LIVE promptContribution — "what the NEXT turn gets";
    /// `routing` qualifies whether the arbiter carries it full or ambient.
    package var contribution: String?
    /// Xcode only: the quirks / build-verifier lines.
    package var extraContributions: [Field]
    package var pollDescription: String
    package var lastSuccessAt: Date?
    package var lastError: String?
    package var isPinned: Bool
    /// "leads — full context" / "ambient line only" / "absent this turn" —
    /// the live mirror of WorkspaceFocusArbiter routing.
    package var routing: String
    /// WHERE this world's contribution actually went this turn: "voice +
    /// abilities" / "abilities only" / "voice only" / "neither". `routing` answers
    /// how much of it the arbiter carried; this answers which LANES received
    /// it — and in a dual-lane architecture that is the diagnostic the pane
    /// was missing. The sync bug (Mary narrating a deleted paragraph from
    /// retrieval while her eyes were on the live document) reported healthy
    /// here for weeks: perception SUCCEEDED and Pages read "leads — full
    /// context", because nothing on the card ever said the speaking lane
    /// never got it. This row would have read "abilities only".
    package var delivery: String

    package var id: String { world.rawValue }

    package init(
        world: PerceptionWorld,
        isRunning: Bool,
        blindness: Blindness? = nil,
        capturedAt: Date? = nil,
        fields: [Field],
        windowFields: [Int: [Field]] = [:],
        contribution: String? = nil,
        extraContributions: [Field],
        pollDescription: String,
        lastSuccessAt: Date? = nil,
        lastError: String? = nil,
        isPinned: Bool,
        routing: String,
        delivery: String
    ) {
        self.world = world
        self.isRunning = isRunning
        self.blindness = blindness
        self.capturedAt = capturedAt
        self.fields = fields
        self.windowFields = windowFields
        self.contribution = contribution
        self.extraContributions = extraContributions
        self.pollDescription = pollDescription
        self.lastSuccessAt = lastSuccessAt
        self.lastError = lastError
        self.isPinned = isPinned
        self.routing = routing
        self.delivery = delivery
    }
}

/// The pane's focus block: where the user is, what the next turn will use,
/// and the pin between them.
package struct FocusSummary: Equatable {
    /// current() — window truth.
    package var ambient: WorkspaceFocus?
    /// effectiveFocus() — what the next turn will use.
    package var effective: WorkspaceFocus?
    /// WHERE the writing signal came from.
    ///
    /// One field, not two. Its predecessor kept this beside a compiled
    /// `writingApp` projection that could not name a taught application — so
    /// a manuscript session in one lit up whichever compiled world the enum
    /// defaulted to, and the pane showed a card claiming the focus for a
    /// document nobody was in. Nil means no writing signal at all, which is
    /// a real state and used to be unrepresentable.
    package var writingPlace: AmbientPlace?
    package var pinned: PinnedWorld?
    /// Inferred, not read: effectiveFocus() = override ?? pin ?? ambient, so
    /// any disagreement with the tier below IS an override. Almost always
    /// false — the pane is open between turns, when overrides are cleared.
    package var overrideActive: Bool
    /// Whether a WRITING app has earned the lead, or is merely open. Mirrors
    /// `WorkspaceFocusTracker.writingInPlay()`, which the arbiter now gates
    /// the writing lead on — shown because "Pages is running, and it is not
    /// leading" is otherwise indistinguishable on this pane from a bug.
    package var writingInPlay: Bool = true
    /// Where the last thing Mary READ actually went. The per-card `delivery`
    /// row describes a WATCHER's contribution; a Skill result had no row
    /// anywhere, which is how a successful `pages_body` read reaching nobody
    /// looked perfectly healthy on this pane while the voice denied the
    /// passage existed. Nil = no read since launch.
    package var readDelivery: ReadDelivery?
    /// WHAT SHE IS STILL HOLDING WITH NO WINDOW BEHIND IT — a straight query
    /// of the ambient context store, not a re-derivation. Two kinds of fact
    /// land here, and the second would otherwise be invisible on this pane:
    ///
    /// - READS that survive the turn that fetched them, each with its bounds
    ///   and its age.
    /// - EYELESS facts of every sort — a calendar read, a reminders digest.
    ///   The cards join facts to worlds through `PerceptionWorld`, which only
    ///   knows the three watched apps, so a calendar fact joins NO card. It
    ///   rides both prompts; showing it nowhere would be exactly the
    ///   prompt/pane drift the store was built to end.
    ///
    /// Empty = the store holds neither (nothing fetched, nothing standing, or
    /// everything aged out).
    package var heldReads: [AmbientFact] = []
    /// Which branch of the user's three-way budget rule decided the ORDER the
    /// prompt rendered those facts in. Shown beside them because "relevance"
    /// vs "focused-world priority" is the difference between two very
    /// different prompts built from the same store.
    package var rankingMode: AmbientRankingMode = .relevance

    /// Which card the effective focus lights up — `.writing` belongs to
    /// exactly one place, never two.
    ///
    /// ASKED OF THE PLACE, not of the compiled `writingApp`: that enum cannot
    /// name a taught application, so a manuscript session in one used to light
    /// up whichever compiled world the enum defaulted to — a card claiming the
    /// focus for a document nobody was in.
    /// Whether this card is the place the next turn will use.
    ///
    /// ASKED OF THE PLACE'S OWN DISCIPLINE. The version this replaces compared
    /// the coding side against one compiled world by name, so an IDE the user
    /// taught Mary could never be the effective card no matter what it
    /// declared.
    package func isEffective(_ world: PerceptionWorld) -> Bool {
        guard let effective else { return false }
        switch effective {
        case .writing: return world.place == writingPlace
        case .coding: return world.place.focus == .coding
        }
    }

    package init(
        ambient: WorkspaceFocus? = nil,
        effective: WorkspaceFocus? = nil,
        writingPlace: AmbientPlace? = nil,
        pinned: PinnedWorld? = nil,
        overrideActive: Bool,
        writingInPlay: Bool = true,
        readDelivery: ReadDelivery? = nil,
        heldReads: [AmbientFact] = [],
        rankingMode: AmbientRankingMode = .relevance
    ) {
        self.ambient = ambient
        self.effective = effective
        self.writingPlace = writingPlace
        self.pinned = pinned
        self.overrideActive = overrideActive
        self.writingInPlay = writingInPlay
        self.readDelivery = readDelivery
        self.heldReads = heldReads
        self.rankingMode = rankingMode
    }
}
