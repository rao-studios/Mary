//
//  AmbientSlot.swift
//  MaryBrain
//
//  WHAT: What a fact is about within its world, and the (world, application, slot) key.
//  OUT:  AmbientContextStore supersession
//  PIN:  A write replaces its slot only. Application is part of the key — `.applications` is shared.
//

import Foundation

/// What the fact is about within its world.
public enum AmbientSlot: Sendable, Equatable, Hashable {
    /// The file or document in view, and how big it is. Named `file` after
    /// the plan's own key (`(xcode, file)`); `slotPhrase` says "document" for
    /// the writing worlds, because a Pages session must never hear "file".
    case file
    /// What the app reports as on screen.
    case viewport
    /// The user's own highlight.
    case selection
    /// User's selection of objects (`.selection` is text highlight).
    case objectSelection
    /// Ambient version-control state.
    case git
    /// Project/binder-level statistics.
    case project
    /// Insertion point plus enough surrounding text to name the work.
    case cursor
    /// Passage a READ produced, keyed by the finding phrase. Survives the fetch turn.
    case namedRead(document: String?, phrase: String)
    /// Standing line for an eyeless data source.
    case digest

    /// Room speech not addressed to Mary. Continuous transcript deposit.
    case heard

    /// Remembered look. Must not be `.viewport` (that churns every 1.5 s).
    case glimpsed

    /// Read that names no document — eyeless and single-document worlds.
    public static func read(_ phrase: String, in document: String? = nil) -> AmbientSlot {
        .namedRead(document: document, phrase: phrase)
    }

    /// Greppable token — the debugger report and the tests both key on this.
    public var token: String {
        switch self {
        case .file:                return "file"
        case .viewport:            return "viewport"
        case .selection:           return "selection"
        case .objectSelection:     return "object-selection"
        case .cursor:              return "cursor"
        case .git:                 return "git"
        case .project:             return "project"
        case .namedRead(let document, let phrase):
            // NIL DOCUMENT RENDERS EXACTLY AS BEFORE — `read:batteries` — so every existing pane row
            // id and report token is byte-identical, and only a world that can hold several documents
            // at once pays for the discriminator.
            guard let document, !document.isEmpty else { return "read:\(phrase)" }
            return "read:\(document)#\(phrase)"
        case .digest:              return "digest"
        case .heard:               return "heard"
        case .glimpsed:            return "glimpsed"
        }
    }

    /// True for the slots a WATCHER fills on every poll — the ones the live
    /// prompt section already renders in full for the world that leads. A
    /// digest is NOT one: nothing polls it, and nothing may wipe it wholesale.
    public var isPerceived: Bool {
        switch self {
        // `.heard` and `.glimpsed` are deposited, never polled: a watcher's wholesale lane
        // replacement must not take them.
        case .namedRead, .digest, .heard, .glimpsed, .cursor: return false
        default: return true
        }
    }

    /// True only for a passage the USER ASKED FOR.
    public var isRead: Bool {
        if case .namedRead = self { return true }
        return false
    }

    public var order: Int {
        switch self {
        case .namedRead:      return 0   // the asked-for thing leads its world
        case .selection:      return 1
        case .objectSelection: return 2  // what they are pointing at, next
        case .viewport:       return 3
        // BELOW THE VIEWPORT, DELIBERATELY — `PerceptionAnchor`'s own rule
        // ("the thing in front of their eyes" beats "where they last typed"),
        // read here as sort order rather than restated as a second doctrine.
        case .cursor:         return 4
        case .file:           return 5
        case .project:        return 6
        case .git:            return 7
        case .digest:         return 8   // background by construction
        case .glimpsed:       return 9   // something she saw a while ago
        case .heard:          return 10  // something said near her
        }
    }
}

/// The store's key: `(world, application, slot)`. A superseding write replaces exactly
/// this. THE APPLICATION IS PART OF THE KEY because a world is not always one application.
public struct AmbientKey: Sendable, Equatable, Hashable {
    /// WHERE, as one value. Holding a place rather than a loose pair is what
    /// lets the store scope a read budget or a perception wipe to a lane
    /// without every call site re-deriving what a lane is.
    public var place: AmbientPlace
    public var slot: AmbientSlot

    /// The closed world half. Kept as the primary spelling because almost every reader asks
    /// exactly this and does not care about the discriminator.
    public var attention: AmbientAttention { place.attention }

    /// The registered application's LOGICAL id — `"sketch"`, never a bundle identifier.
    public var application: String? { place.application }

    public init(attention: AmbientAttention, application: String? = nil, slot: AmbientSlot) {
        self.init(place: AmbientPlace(attention: attention, application: application), slot: slot)
    }

    public init(place: AmbientPlace, slot: AmbientSlot) {
        self.place = place
        self.slot = slot
    }

    /// `pages/read:batteries` — the pane's row id and the report's token — and
    /// `other_apps:sketch/read:canvas` once an application shares its world. The built-in form
    /// is unchanged deliberately: these strings are pinned as literals in tests, rendered into.
    public var id: String { "\(place.token)/\(slot.token)" }
}
