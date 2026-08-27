//
//  AmbientPlace.swift
//  MaryAmbient
//
//  WHERE a fact lives, as one unified taxonomy: every identity the ambient
//  layer routes, scopes, or remembers by is exactly one of two cases.
//
//  NATIVE IS THE CLOSED VOCABULARY. `AmbientWorld` has one case per compiled
//  plugin owner and that is deliberate: its own header records what happened
//  when it was narrower than the set of things that could produce a read. A
//  native place IS its world — `worldClass` and `displayName` still cover all
//  cases with no `default:`, so the compiler still refuses to build
//  a world that forgot to say what it is, which is the check that would have
//  caught the original calendar bug at compile time rather than in a user's
//  report.
//
//  DYNAMIC IS THE OPEN IDENTITY. The set of applications a user may teach
//  Mary is not closed, so a registered application is a case carrying its
//  LOGICAL id — and nothing else. It carries no host world of its own because
//  the M0 shape audit proved there is nothing to carry: a registration with a
//  legacy world IS that world (native case), and every other registration
//  rides `.applications`. `.applications` is therefore a host LANE — the shared
//  perception channel dynamics ride — not a routing identity a dynamic place
//  needs to restate. Every taxonomy member below resolves against the
//  registration when one owns the lane and falls back to the host when none
//  does, so an unregistered application degrades rather than crashes.
//
//  EYELESS IS AN AXIS, NOT AN IDENTITY. Whether anything is actually looking
//  at a place (`hasEyes` / `isEyeless`) cuts across both cases — a native
//  service world and a workspace-classed registration with no perception
//  contract are both eyeless — so it is a property here, never a third case.
//
//  THE NATIVE CASE RENDERS BYTE-IDENTICALLY to the bare world it always was.
//  Every existing key string, pane row id, report token and pinned literal is
//  unchanged, because `.calendar` IS the calendar and naming it twice would be
//  a second spelling of one fact.
//

import Foundation

public enum AmbientPlace: Sendable, Equatable, Hashable {

    /// A built-in world answering for itself.
    case lane(AmbientWorld)

    /// A registered application's LOGICAL id (`"sketch"`), riding the
    /// `.applications` host lane.
    ///
    /// REGISTERED places never carry a bundle identifier — that lives on
    /// `AmbientFact.applicationID` and answers a different question: this one
    /// is who Mary reasons and remembers with, that one is the exact
    /// process a later edit must return to. Comparing the two namespaces is
    /// the mistake `ApplicationProfile` already warns about for aliases.
    ///
    /// AMENDED (cursor-obvious lead, 2026-08-11): an UNREGISTERED generic
    /// application's place carries its BUNDLE ID as the open-form identity
    /// (`AmbientPlaceResolver.applicationPlace(forBundleID:)`) — the stable
    /// machine identity termination can match exactly. The namespaces still
    /// never collide: logical ids never contain dots, bundle ids always do.
    case application(String)

    // MARK: - The (world, application) projection

    /// The closed world. For a dynamic place this is the HOST lane it rides —
    /// always `.applications`, per the pinned host-lane shape — never a case of
    /// its own.
    public var world: AmbientWorld {
        switch self {
        case .lane(let world): return world
        case .application: return .applications
        }
    }

    /// The dynamic id, or nil when the world answers for itself.
    public var application: String? {
        switch self {
        case .lane: return nil
        case .application(let id): return id
        }
    }

    /// The pair spelling, kept as a factory so every existing call site
    /// compiles unchanged. A non-empty application names a dynamic place; the
    /// world argument is then the host lane, not part of the identity — the
    /// M0 shape audit (`AmbientPlaceABITests`) proved every such construction
    /// passes `.applications`, so dropping it drops nothing.
    public init(world: AmbientWorld, application: String? = nil) {
        if let application, !application.isEmpty {
            self = .application(application)
        } else {
            self = .lane(world)
        }
    }

    // NO SUGAR FACTORY. There used to be one — `.world(w)` standing in for
    // `.native(w)` — because the case was named for what it CONTAINED while
    // callers thought in terms of the lane. Renaming the case to `.lane`
    // makes the sugar and the case the same word, so the case is the whole
    // answer and a second spelling would only be ambiguous.

    // MARK: - Case axes

    public var isLane: Bool {
        if case .lane = self { return true }
        return false
    }

    public var isApplication: Bool {
        if case .application = self { return true }
        return false
    }

    /// The perception axis, spelled positively for scope ladders that admit
    /// eyeless places from everywhere. An axis, not an identity: both cases
    /// can be eyeless.
    public var isEyeless: Bool { !hasEyes }

    // MARK: - Tokens

    /// `calendar` / `other_apps:sketch` — the place half of a key id.
    ///
    /// A COLON, not a second slash: the report and the pane split a key id on
    /// its FIRST `/` to separate place from slot, and `read:doc#phrase`
    /// already proves a colon survives that split intact.
    public var token: String {
        switch self {
        case .lane(let world):
            return world.rawValue
        case .application(let id):
            return "\(AmbientWorld.applications.rawValue):\(id)"
        }
    }

    /// The persisted spelling: the memory graph stores `"pages"` and
    /// `"sketch"` as PEERS with no prefix, and there is no version field to
    /// migrate on — a prefixed token would orphan every previously-deposited
    /// row. Distinct from `token`, whose job is to never collide.
    public var memoryToken: String {
        switch self {
        case .lane(let world): return world.rawValue
        case .application(let id): return id
        }
    }

    /// The inverse of `token`. Splits on the FIRST colon — a dynamic id could
    /// itself contain one — and only the `.applications` host lane spells
    /// dynamics, so any other prefixed token is not a place.
    public static func from(token: String) -> AmbientPlace? {
        if let colon = token.firstIndex(of: ":") {
            guard String(token[..<colon]) == AmbientWorld.applications.rawValue else {
                return nil
            }
            let id = String(token[token.index(after: colon)...])
            return id.isEmpty ? nil : .application(id)
        }
        return AmbientWorld.from(pluginOwner: token).map { .lane($0) }
    }

    /// The lead ladder every focus consumer had been spelling by hand: a
    /// dynamic id outranks the world, resolves through its registration when
    /// one is installed (a legacy-projecting registration IS its world), and
    /// falls back to the raw dynamic place when the index does not know it
    /// yet. Nothing led — no place.
    public static func lead(
        world: AmbientWorld?, applicationID: String?
    ) -> AmbientPlace? {
        if let applicationID, !applicationID.isEmpty {
            return AmbientApplicationIndexProvider.current
                .registration(id: applicationID)?.place ?? .application(applicationID)
        }
        return world.map { .lane($0) }
    }

    // MARK: - The taxonomy

    /// The registration backing this place, if any. Resolved through the
    /// installed index rather than held, because a place is a value that
    /// travels and the roster changes when a package is imported or removed.
    public var registration: ApplicationRegistration? {
        guard case .application(let id) = self else { return nil }
        return AmbientApplicationIndexProvider.current.registration(id: id)
    }

    /// WHAT KIND of thing this place is.
    ///
    /// The registration's answer when one owns this lane, because the HOST
    /// world's class describes the host and not the guest: `.applications` is
    /// `.perceptionOnly`, so reading the class off it would deny eyes to every
    /// registered application no matter what it declared. An unregistered
    /// dynamic falls back to the host lane's class.
    public var worldClass: AmbientWorldClass {
        registration?.worldClass ?? world.worldClass
    }

    /// Whether anything is actually looking at this place.
    ///
    /// NOT simply `worldClass == .workspace` for a registration. A package may
    /// class itself workspace and declare no way to be observed, and a card
    /// claiming live sight of something nothing polls is precisely the
    /// confident lie the perception layer exists to refuse. The registration
    /// answers for itself, and its own `hasEyes` requires both.
    public var hasEyes: Bool {
        if let registration { return registration.hasEyes }
        return world.hasEyes
    }

    /// CODING OR WRITING, or neither — the workspace-identity axis the focus
    /// arbiter and the reference ladder both split on.
    ///
    /// A registration answers from the DISCIPLINES ITS PACKAGE REALIZES, which
    /// is the same edge `AmbientEngine.classify` already reads and the same one
    /// `AmbientWorld.ability` spells for the compiled worlds. Asking the host
    /// world instead would answer nil for every taught application — and a nil
    /// focus is what makes the rival-writing bar silently stand down, so a
    /// manuscript in a taught application could be hijacked by a note the user
    /// never mentioned.
    ///
    /// Ordered coding-before-writing to match `AmbientWorld.focus`, which gives
    /// Xcode `.coding` and never has to choose. A package that realizes both is
    /// a coding workspace that also writes, not a writing one that also codes.
    public var focus: WorkspaceFocus? {
        guard let registration else { return world.focus }
        switch ability {
        case .some(.coding):  return .coding
        case .some(.writing): return .writing
        default:              return nil
        }
    }

    /// WHICH CRAFT this place is for, so that a taught application can give
    /// one.
    ///
    /// `focus` above is the two-value projection of this, and it is written as
    /// a projection deliberately: the two used to pick from
    /// `profile.abilities` independently, and two derivations of one answer
    /// eventually disagree. One ordering, one place.
    ///
    /// THE ORDER IS NOT `Set` ORDER. `profile.abilities` is a `Set<AbilityID>`,
    /// so a bare `first` would answer differently between runs and make the
    /// roster nondeterministic. The order is `WorkspaceFocus`'s own — the
    /// disciplines, coding before writing — because that enum IS the axis this
    /// projects onto.
    ///
    /// IT USED TO ASK THE LANES, and in Mary that silently answered nothing.
    /// `AmbientWorld.realizedAbilities` was "every Ability any world realizes,
    /// in a stable order", which was a real list while the writing and coding
    /// applications were compiled cases; the world shrink left five lanes that
    /// realize no craft at all, so the list went empty and every taught
    /// application fell to the last rung — plain alphabetical order over a set
    /// that ALWAYS contains the package's own id. TextEdit's craft came back
    /// "textedit", because t sorts before w. The cost was not cosmetic: `focus`
    /// went nil for every declared application (standing down the rival-writing
    /// bar the way this file's `focus` comment warns about) and
    /// `workspaceFamily` never produced "writing", so the one admission arm in
    /// `writing.mary` that does not depend on classifying a sentence could
    /// never fire. Found by the behavior probe, which asked a live TextEdit
    /// what discipline it was in and was told none.
    ///
    /// The last rung is for a craft that is not a discipline: a package can
    /// teach one — design.mary does — and answering nil there would deny it
    /// the workspace family its own package declares.
    public var ability: AbilityID? {
        guard let registration else { return world.ability }
        let declared = registration.profile.abilities
        return WorkspaceFocus.abilityOrder.first(where: declared.contains)
            ?? declared.sorted { $0.rawValue < $1.rawValue }.first
    }

    /// What the user is told this place is called.
    ///
    /// THE LADDER GREW HONEST RUNGS (2026-08-11): the browser workspace and
    /// generic-application places have no registration, and the old fallback
    /// rendered them all as "Applications" — the chip literally said
    /// "with: Applications" about the video the user was watching. Now:
    /// registration → the browser workspace's own name → the session
    /// directory's localizedName → a prettified bundle-id tail → the world.
    public var displayName: String {
        if let registration { return registration.displayName }
        if case .application(let id) = self {
            // WHICH BROWSER, when the ledger knows. The workspace is
            // deliberately one place for both engines, and the chip said so —
            // "led: Browser" — which is exactly the information the user
            // needed and did not get on the turn where the prose said Chrome
            // and every binding ran against Safari. The place stays shared;
            // the LABEL names the engine that actually led it, from the same
            // evidence the targeting ladder reads. Nothing evidenced still
            // says "Browser", because with nothing evidenced that is true.
            if id == AmbientPlaceResolver.browserApplicationID {
                return AmbientPlaceResolver.evidencedBrowserName() ?? "Browser"
            }
            if let name = AmbientApplicationDirectory.shared.name(for: id) {
                return name
            }
            if let tail = id.split(separator: ".").last, id.contains(".") {
                return String(tail).capitalized
            }
        }
        return world.displayName
    }

    /// Stable render order. Built-ins keep exactly their existing positions;
    /// registrations sort after every built-in, in roster order, so adding one
    /// can never reorder the worlds the golden prompt diff compares byte for
    /// byte.
    public var order: Int {
        switch self {
        case .lane(let world):
            return world.order
        case .application(let id):
            let roster = AmbientApplicationIndexProvider.current.all
            let position = roster.firstIndex { $0.id == id } ?? roster.count
            return 1_000 + position
        }
    }
}
