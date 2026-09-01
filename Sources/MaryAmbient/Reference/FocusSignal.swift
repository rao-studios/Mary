//
//  FocusSignal.swift
//  MaryAmbient
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
