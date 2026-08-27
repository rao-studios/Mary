//
//  AmbientFact.swift
//  MaryBrain
//
//  ONE processed sensory detail of the machine: what it says, where in the
//  document it sits, how old it is, where it came from, and whether the user
//  asked for it.
//
//  This file holds the fact's STATE and its FRESHNESS rules; the phrasing that
//  turns it into prompt or pane text lives in `AmbientFact+Rendering.swift`,
//  because both readers must share exactly one implementation of it.
//
//  Freshness is deliberately KEYED TO DOCTRINE ALREADY IN THE TREE rather than
//  a second rule invented here — `AmbientSamplingCadence.bodyFreshWindow` and
//  `PerceptionAnchor.isLiveRead` decide what "live" means, and this file just
//  obeys them. Two staleness rules in one system is how a snapshot ends up
//  claiming to be live in one place and stale in another.
//

import Foundation

/// WHERE the content came from — the freshness claim it is allowed to make.
/// Mirrors `PerceptionAnchor.isLiveRead`'s doctrine: LIVE is a claim and it
/// has to be earned.
public enum AmbientProvenance: String, Sendable, Equatable, CaseIterable {
    /// Read off Accessibility this tick — live by construction.
    case liveAX
    /// Cut out of the watcher's throttled document cache — the words are as
    /// old as the last body read.
    case cachedBody
    /// A binding READ produced it (the targeted read, a symbol read, a git
    /// query). Real text, really fetched, with real bounds.
    case recipeRead
    /// Computed from watcher state that is not itself document text (git
    /// branch, build status, binder counts).
    case derived

    public var displayName: String {
        switch self {
        case .liveAX:     return "live accessibility read"
        case .cachedBody: return "cached document body"
        case .recipeRead: return "binding read"
        case .derived:    return "derived from watcher state"
        }
    }
}

/// HOW the fact came to be held: did Mary merely notice it, or did the user
/// ask for it? An asked-for fact outranks a perceived one at equal relevance —
/// the user's own request is the strongest statement of intent there is.
public enum AmbientRegistration: String, Sendable, Equatable, CaseIterable {
    /// The watchers saw it without being asked.
    case perceived
    /// The user asked, and a read went and got it.
    case askedFor

    public var verb: String {
        self == .askedFor ? "read" : "seen"
    }
}

/// One held fact.
public struct AmbientFact: Sendable, Equatable, Identifiable {

    /// Hard cap on stored content — the store is short-term awareness, not a
    /// document cache (the watchers already hold those, capped separately).
    public static let contentCap = 2000

    public var world: AmbientWorld
    /// The registered application this fact belongs to, when its world holds
    /// more than one — `"sketch"`, the LOGICAL id.
    ///
    /// Nil for a built-in world, which is the ordinary case: `.calendar` is the
    /// calendar and needs no second name. Non-nil is what keeps two registered
    /// applications sharing `.applications` from superseding each other, because
    /// this is the field that reaches `AmbientKey`.
    ///
    /// NOT the same thing as `applicationID` below. This is the identity Mary
    /// reasons and remembers with; that is the process it must return to in
    /// order to act. A fact can honestly have one without the other — a
    /// generic AX selection knows the bundle and not the package; a Dynamic
    /// read knows the package and may not have observed a bundle.
    public var application: String?
    public var slot: AmbientSlot
    public var content: String
    /// Nearby document text that informs a direct selection without becoming
    /// part of the selection itself.
    public var surroundingText: String?
    /// The document or file this is about, for the reader's benefit.
    public var subject: String?
    /// The concrete application that produced this fact, when the watcher
    /// knows it. This is intentionally separate from `world`: `.applications`
    /// is one perception world shared by many applications, while a later
    /// writing action must return to the exact app that owned the selection.
    /// It is a bundle identifier, never user-visible prompt text.
    public var applicationID: String?
    /// Character bounds inside `subject`, when the fact honestly knows them.
    /// NEVER invented — a fabricated range here is the same species of
    /// confident lie `PagesContextWatcher.windowLine` exists to stop.
    public var bounds: Range<Int>?
    /// The document's total length, when known — bounds without a total say
    /// nothing about how much was NOT seen.
    public var documentTotal: Int?
    /// What anchored a perceived excerpt (selection / viewport / caret / …).
    public var anchor: PerceptionAnchor?
    public var provenance: AmbientProvenance
    public var registration: AmbientRegistration
    public var capturedAt: Date
    /// How long this fact may still claim to describe the world as it stands.
    /// Past it the fact still LIVES — it renders with its age and loses the
    /// authority claim, which is the honest degradation, not deletion.
    public var freshFor: TimeInterval
    /// Past this the fact is dropped outright: short-term memory, by policy.
    public var retainFor: TimeInterval
    /// The turn loop's write-back: Mary spoke while holding this.
    public var spokenAt: Date?
    /// A clipped note of what she said about it — stops a second recitation.
    public var spokenNote: String?
    /// `[S1]` — the opaque handle for the passage this fact holds, when a read
    /// minted one (`PassageRegistry`).
    ///
    /// WHY A FACT CARRIES IT AT ALL: the bounds in `boundsPhrase` are for the
    /// READER, and they are all this fact used to offer. The prompt said "I
    /// know exactly where each one sits and can pull the text back up" beside
    /// `characters 68–916 of 916`, and no primitive in the tree accepted an
    /// end offset — so the model hand-wrote AppleScript against `document 1`
    /// and got `-1728`. The handle is the part that is actually ACCEPTED
    /// somewhere; carrying it here is what makes that sentence true.
    ///
    /// Nil is the normal case — a viewport, a git line and a calendar digest
    /// are not passages, and inventing a handle for them would offer the model
    /// something `PassageRegistry.resolve` would answer `.unknown` about.
    public var passageHandle: String?

    public init(
        world: AmbientWorld,
        application: String? = nil,
        slot: AmbientSlot,
        content: String,
        surroundingText: String? = nil,
        subject: String? = nil,
        applicationID: String? = nil,
        bounds: Range<Int>? = nil,
        documentTotal: Int? = nil,
        anchor: PerceptionAnchor? = nil,
        provenance: AmbientProvenance,
        registration: AmbientRegistration = .perceived,
        capturedAt: Date = Date(),
        freshFor: TimeInterval? = nil,
        retainFor: TimeInterval? = nil,
        spokenAt: Date? = nil,
        spokenNote: String? = nil,
        passageHandle: String? = nil
    ) {
        self.world = world
        self.application = application
        self.slot = slot
        self.content = String(content.prefix(Self.contentCap))
        self.surroundingText = surroundingText.map { String($0.prefix(Self.contentCap)) }
        self.subject = subject
        self.applicationID = applicationID
        self.bounds = bounds
        self.documentTotal = documentTotal
        self.anchor = anchor
        self.provenance = provenance
        self.registration = registration
        self.capturedAt = capturedAt
        self.freshFor = freshFor ?? Self.defaultFreshWindow(provenance: provenance, slot: slot)
        self.retainFor = retainFor ?? Self.defaultRetention(slot: slot)
        self.spokenAt = spokenAt
        self.spokenNote = spokenNote
        self.passageHandle = passageHandle
    }

    /// WHERE this fact lives — the world it rides and, when its world holds
    /// more than one application, which lane inside it.
    public var place: AmbientPlace {
        AmbientPlace(world: world, application: application)
    }

    public var key: AmbientKey { AmbientKey(place: place, slot: slot) }
    public var id: String { key.id }

    // MARK: - Freshness (reusing what already exists)

    /// Keyed to the doctrine already in the tree rather than a second rule
    /// invented here: an AX-anchored read is live by construction (it was read
    /// this tick), cached body text is live only inside
    /// `AmbientSamplingCadence.bodyFreshWindow`, and a binding read is exactly as
    /// good as the body it came out of.
    public static func defaultFreshWindow(provenance: AmbientProvenance) -> TimeInterval {
        switch provenance {
        case .liveAX:     return AmbientSamplingCadence.activeInterval * 2
        case .cachedBody: return AmbientSamplingCadence.bodyFreshWindow
        case .recipeRead: return AmbientSamplingCadence.bodyFreshWindow
        case .derived:    return 60
        }
    }

    /// A STANDING DIGEST'S OWN WINDOWS. Both had to be separated from the
    /// provenance/perceived defaults, and each for a reason that would
    /// otherwise show up as Mary lying:
    ///
    /// - FRESHNESS. A digest is `.derived`, whose window is 60 s, so "3 events
    ///   today" would start appending "so it may have moved on since" after
    ///   one minute. Today's event count does not go stale in a minute; the
    ///   window is keyed to the refresh cadence plus slack instead, exactly as
    ///   `AmbientSamplingCadence.bodyFreshWindow` is.
    /// - RETENTION. `isPerceived` is false, which would have handed it the
    ///   READ retention (20 minutes) — LONGER than a passage the user actually
    ///   asked for, for a line nobody requested. It only has to outlive a few
    ///   missed ticks, so it sits below both the read retention and, at the
    ///   fresh window, well above the refresh floor.
    public static let digestRefreshFloor: TimeInterval = 180
    public static let digestFreshWindow: TimeInterval = digestRefreshFloor * 3   // 9 min
    public static let digestRetention: TimeInterval = digestRefreshFloor * 5     // 15 min

    /// Perceived slots are superseded every poll, so their retention only has
    /// to outlive a watcher going quiet. A READ is the continuity headline —
    /// it has to survive several turns of conversation, because "ask for the
    /// passage, then follow up two turns later" is the user's own acceptance
    /// test.
    public static func defaultRetention(slot: AmbientSlot) -> TimeInterval {
        switch slot {
        case .digest: return digestRetention
        case .namedRead: return 1200
        default: return 300
        }
    }

    /// The slot-aware window `init` actually uses. The provenance-only form
    /// above is kept because it is the doctrine bridge to
    /// `PerceptionAnchor.isLiveRead`, and a digest is the one fact whose
    /// freshness is a property of its REFRESH CADENCE, not of where its words
    /// came from.
    public static func defaultFreshWindow(
        provenance: AmbientProvenance, slot: AmbientSlot
    ) -> TimeInterval {
        if case .digest = slot { return digestFreshWindow }
        return defaultFreshWindow(provenance: provenance)
    }

    public func age(at now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(capturedAt))
    }

    /// May this fact still claim to describe the world as it stands?
    public func isFresh(at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(capturedAt)
        return age >= 0 && age <= freshFor
    }

    /// Past retention — dropped on the next touch of the store.
    public func isExpired(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(capturedAt) > retainFor
    }
}
