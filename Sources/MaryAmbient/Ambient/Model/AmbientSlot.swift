//
//  AmbientSlot.swift
//  MaryBrain
//
//  WHAT a fact is about within its world, and the `(world, slot)` key the two
//  halves compose into.
//
//  The slot is the unit of supersession: a superseding write replaces its slot
//  and ONLY its slot, so a fresh viewport never erases the passage a read
//  registered. That separation is the whole reason the continuity bug is fixed
//  — perceived slots churn every poll, `namedRead` does not.
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
    /// THE USER'S SELECTION OF OBJECTS, where `.selection` is their highlight
    /// of TEXT. Its own case for a hard structural reason: `register` refuses
    /// `.selection` outright, because a text highlight may only enter through
    /// `recordSelection` carrying the source process and capture ordering
    /// that make a WRITE to it safe. A drawn canvas has neither — Sketch's
    /// layers are invisible to Accessibility, so this arrives from the
    /// document read, a poll old, and it authorizes nothing on its own: the
    /// script re-resolves the live selection inside the transaction that
    /// changes anything. Perceived, like the viewport it rides in with, so
    /// the poll supersedes it wholesale every cycle and a deselection is
    /// carried as faithfully as a selection.
    case objectSelection
    /// Ambient version-control state.
    case git
    /// Project/binder-level statistics.
    case project
    /// WHERE THE INSERTION POINT SITS, and enough of the text around it to
    /// say what the user is working on — the standing grounding a code
    /// editor's caret earns when nothing is highlighted.
    ///
    /// ITS WHOLE REASON FOR EXISTING IS TO NOT BE `.viewport`, and the
    /// doctrine that forces the split is already written down one file over:
    /// `PerceptionAnchor` says the viewport BEATS the caret, "a reader
    /// scrolls away from their cursor constantly, and the thing in front of
    /// their eyes is what they mean by this paragraph". Filing a caret
    /// excerpt under `.viewport` would render it beneath that slot's phrase —
    /// "what they're looking at" — and hand it to `PassageEditRunner
    /// .attention`, whose viewport fallback exists to break ties between
    /// candidate spans by where the user's EYES are. A cursor is not that
    /// claim. `.file` is identity, not content, and `.selection` is refused by
    /// `register` outright because a highlight may only arrive through
    /// `recordSelection`.
    ///
    /// NOT PERCEIVED, for exactly the three reasons `.digest` states below —
    /// and the middle one is decisive here rather than merely tidy.
    /// `MaryRuntime.heldContext` dedups every PERCEIVED fact belonging to the
    /// LEAD place, on the ground that "the live prompt section already renders
    /// them in full". No live section renders this one: it is polled by an
    /// observer that contributes no prompt text, so marking it perceived would
    /// delete it from the prompt on precisely the turns it exists for — the
    /// ones where the user is in the editor.
    ///
    /// It carries its own freshness and retention (`AmbientFact
    /// .cursorFreshWindow`/`cursorRetention`), and they are the shortest in
    /// the store. A caret is the most volatile thing on a screen; the standing
    /// doctrine that a stale surface is a confidently wrong screen applies to
    /// it more sharply than to anything else here.
    case cursor
    /// A passage a READ produced, keyed by the phrase that found it. THE
    /// continuity slot: this is the one that used to vanish at the end of the
    /// turn that fetched it.
    case namedRead(document: String?, phrase: String)
    /// THE STANDING LINE for an eyeless data source — "3 events today, next
    /// at 2 PM; 5 open reminders". One cheap line, refreshed on a slow
    /// cadence, expanded to detail only when the utterance concerns it.
    ///
    /// DELIBERATELY NOT PERCEIVED, and that is the whole reason this is its
    /// own case rather than reusing `.file`. `isPerceived` is written as
    /// "anything that isn't a read", so a new case defaults to perceived —
    /// which would (a) subject a digest nobody polls to `replacePerceived`'s
    /// wholesale wipe, (b) pin it to mention-only forever in the ranking even
    /// when the user asks about it, and (c) drop it out of the debugger's
    /// held-facts query, so the pane would stop showing a line the prompt was
    /// carrying. Prompt/pane drift is the exact bug this subsystem exists to
    /// end.
    case digest

    /// SOMETHING SAID IN THE ROOM that was not addressed to her.
    ///
    /// The continuous transcript's deposit. It is short-term memory in the
    /// literal sense — a brief `retainFor`, pruned like everything else — and
    /// it exists so "you mentioned a deadline earlier" is the SAME mechanism
    /// as "your calendar changed", rather than a second subsystem beside it.
    ///
    /// NOT PERCEIVED: nothing polls it, so a watcher's `replacePerceived`
    /// must never wipe a lane's heard speech along with its viewport.
    case heard

    /// A REMEMBERED LOOK — a viewport snapshot kept deliberately, minutes ago.
    ///
    /// ITS WHOLE REASON FOR EXISTING IS TO NOT BE `.viewport`. The live
    /// viewport churns every 1.5 s and describes what the user is looking at
    /// RIGHT NOW, which is the one thing never worth narrating back to them.
    /// A glimpse is the same content held long enough to become something she
    /// remembers rather than something she is staring at — same words,
    /// different age, opposite verdict at the floor.
    case glimpsed

    /// A READ THAT NAMES NO DOCUMENT — every eyeless world, and every
    /// single-document one. Sugar over `.namedRead(document: nil, phrase:)`,
    /// which is what the vast majority of call sites and test literals want;
    /// spelling the nil at each of them would be noise around the one case
    /// that matters.
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
            // NIL DOCUMENT RENDERS EXACTLY AS BEFORE — `read:batteries` — so
            // every existing pane row id and report token is byte-identical,
            // and only a world that can hold several documents at once pays
            // for the discriminator.
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
        // `.heard` and `.glimpsed` are deposited, never polled: a
        // watcher's wholesale lane replacement must not take them.
        // `.cursor` IS polled, and is still not perceived — see its own
        // comment: no live prompt section renders it, so the lead-place
        // dedup would erase it from the very turns it exists for.
        case .namedRead, .digest, .heard, .glimpsed, .cursor: return false
        default: return true
        }
    }

    /// True only for a passage the USER ASKED FOR. Narrower than
    /// `!isPerceived` on purpose: the per-world read cap must not evict a
    /// standing digest to make room for a fourth read, and the "a read is
    /// exempt" branches of the ranking must not accidentally exempt a digest
    /// nobody requested.
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

/// The store's key: `(world, application, slot)`. A superseding write replaces
/// exactly this.
///
/// THE APPLICATION IS PART OF THE KEY because a world is not always one
/// application. `.applications` is, by its own definition, "one perception world
/// shared by many applications" — so before this field existed, two registered
/// applications writing the same slot in that world overwrote each other, and
/// Mary would answer about Figma using Sketch's canvas. `AmbientFact` has
/// carried a bundle identifier for exactly this reason since it was written;
/// what was missing was the discriminator reaching the KEY, which is what the
/// store actually supersedes on.
///
/// Nil for a built-in world, which is the ordinary case and the reason every
/// existing key string is byte-identical: `.calendar` IS the calendar, so
/// naming the application again would be a second spelling of one fact.
public struct AmbientKey: Sendable, Equatable, Hashable {
    /// WHERE, as one value. Holding a place rather than a loose pair is what
    /// lets the store scope a read budget or a perception wipe to a lane
    /// without every call site re-deriving what a lane is.
    public var place: AmbientPlace
    public var slot: AmbientSlot

    /// The closed world half. Kept as the primary spelling because almost every
    /// reader asks exactly this and does not care about the discriminator.
    /// Read-only since the place became an enum: nothing ever wrote these
    /// halves, and half a place is not a thing you can assign.
    public var world: AmbientWorld { place.world }

    /// The registered application's LOGICAL id — `"sketch"`, never a bundle
    /// identifier. Distinct from `AmbientFact.applicationID`, which is the
    /// bundle id a watcher observed: one is the identity Mary reasons and
    /// remembers with, the other is the process it must return to in order to
    /// act. Keeping them apart is what stops routing comparing unlike
    /// namespaces, the same rule `ApplicationProfile` states for aliases.
    public var application: String? { place.application }

    public init(world: AmbientWorld, application: String? = nil, slot: AmbientSlot) {
        self.init(place: AmbientPlace(world: world, application: application), slot: slot)
    }

    public init(place: AmbientPlace, slot: AmbientSlot) {
        self.place = place
        self.slot = slot
    }

    /// `pages/read:batteries` — the pane's row id and the report's token — and
    /// `other_apps:sketch/read:canvas` once an application shares its world.
    ///
    /// The built-in form is unchanged deliberately: these strings are pinned as
    /// literals in tests, rendered into route reports, and used as pane row ids,
    /// so a world that answers for itself must key exactly as it always has.
    public var id: String { "\(place.token)/\(slot.token)" }
}
