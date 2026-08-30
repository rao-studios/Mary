//
//  PerceptionCard.swift
//  MaryRuntime
//
//  WHAT: One watched place as the debugger sees it.
//  IN:   snapshot view model (tiles join on SCWindow bundle id)
//  OUT:  tile captions + inspector detail; PerceptionReport serializes these
//

import Foundation
import MaryPlugin
import MaryAmbient
import MaryBrain
import MaryFoundation

/// Subject of one card — a taught place. `current()` reads the live roster.
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

    /// Every place the roster knows, sorted by token (stable across launches).
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
    /// Canonical pin-string. Debugger badge and tile badge both read this.
    package var badgeKey: String { applicationID }

    /// The report's pin token: `writing(quill)`, `coding(forge)`.
    var reportToken: String {
        "\(focus == .coding ? "coding" : "writing")(\(applicationID))"
    }
}

package struct PerceptionCard: Identifiable, Equatable {

    /// Why Mary can't see. Precedence: appNotRunning → watcherInactive →
    /// automationDenied → pollFailure → accessibilityLimited.
    /// Running gates denied (deniedBox survives quit).
    package enum Blindness: Equatable {
        /// No watcher. World is still registered — pane owes a card, not omission.
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
    /// Per-window fields keyed by CGWindowID (= WindowTile.id). Join is exact
    /// id, not title. Empty for single-window worlds → fields(forWindow:) == fields.
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
    /// Which lanes received this contribution: voice+abilities / abilities only /
    /// voice only / neither. `routing` is how much; this is who got it.
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
    /// Where the writing signal came from. Nil = none (a real state).
    package var writingPlace: AmbientPlace?
    package var pinned: PinnedWorld?
    /// Inferred, not read: effectiveFocus() = override ?? pin ?? ambient, so
    /// any disagreement with the tier below IS an override. Almost always
    /// false — the pane is open between turns, when overrides are cleared.
    package var overrideActive: Bool
    /// Writing app earned the lead vs merely open. Mirrors writingInPlay().
    package var writingInPlay: Bool = true
    /// Where the last Skill read went. Nil = none since launch.
    package var readDelivery: ReadDelivery?
    /// Held facts with no window — store query. Reads that survived + eyeless
    /// (calendar, reminders). Empty = store holds neither.
    package var heldReads: [AmbientFact] = []
    /// Which budget-rule branch ordered those facts (relevance vs focused-world).
    package var rankingMode: AmbientRankingMode = .relevance

    /// Which card effective focus lights — `.writing` is one place.
    /// Asked of the place's own discipline, not a compiled world name.
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
