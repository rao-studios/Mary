//
//  AmbientWorld.swift
//  MaryAmbient
//
//  MARY'S OVERALL STATE AT A MOMENT — the lanes that host every ambient
//  context, and the faculties she can invoke.
//
//  A WORLD IS NOT A PLACE, and the whole vocabulary turns on keeping those
//  apart:
//
//    WORLD  — this enum. What Mary IS right now: the standing lanes her
//             context hangs on, and what she can reach for. Five of them,
//             all shipped by this build, and the list does not grow when a
//             user teaches her a new application.
//    REALM  — `AmbientRealm`. What is OUTSIDE her that could serve the turn:
//             the applications conforming to what the query needs, held as a
//             set while the where is still being decided.
//    PLACE  — `AmbientPlace`. The WHERE, singular and decided. A realm HOSTS
//             one once the focus signal has spoken.
//
//  Confusing the world for the place is the specific mixup this file exists
//  to prevent. A lane hosts contexts; it is not somewhere the user is.
//
//  EVERY AMBIENT CONTEXT IS HOSTED BY A LANE, mechanically and not just by
//  description: the store keys every fact under `(world, application)`, so
//  the lane is the first half of the address of everything Mary holds. An
//  application's facts ride `.applications`; her own faculties key under
//  themselves.
//
//  WHAT IS NOT HERE IS THE POINT. There is no `textEdit` case, no `pages`,
//  no `xcode`. Every application arrives as a Plugin package and lives as
//  `AmbientPlace.application("textedit")`, riding the `.applications` lane and
//  resolved through its registration. Bonnie learned this the expensive way:
//  its version of this enum carried one case per compiled plugin owner, so
//  every application anyone ever taught it needed a new case — a recompile to
//  learn a new app — and the two applications that were taught by package
//  instead (Scrivener, Sketch) then had to be special-cased back OUT of every
//  switch that assumed a world meant an application. The header of that file
//  argued at length about which apps deserved cases. Mary does not have that
//  argument available, which is the improvement.
//
//  THE CONSEQUENCE WORTH NAMING: several questions this enum used to answer —
//  does this place have eyes, what craft is it for, does it hold prose — are
//  now questions about a REGISTRATION, and `AmbientPlace` asks them there.
//  What is left here answers only for Mary's own lanes, and answers "no" or
//  "nothing" for all of them, honestly: the typer is not a place with
//  contents, and the applications lane is a channel rather than a location.
//  What this enum DOES still answer for itself is `isInvocable` — which of
//  these lanes is a faculty Mary can reach for, as opposed to a channel
//  through which she perceives.
//
//  THIS ALSO CLOSES A GAP BY CONSTRUCTION. Bonnie's passage backing was keyed
//  on this enum, so an application taught by package — having no case — could
//  be read, focused and remembered but could never have a passage cut from
//  it. There was a documented note about that. With no application cases at
//  all, there is no set to be left out of: passages key on the place, and
//  every application is a place the same way.
//

import Foundation

/// WHAT KIND of thing a place is.
///
/// Kept as a taxonomy rather than collapsed, because a registration answers
/// with one of these and the store's ranking reads it. `perceptionOnly` is
/// what an application without a declared observation channel resolves to —
/// seen, but not watched.
public enum AmbientWorldClass: String, Sendable, Equatable, CaseIterable {
    /// A place with contents the user works inside, where document focus
    /// matters. A claim about the KIND of place, never proof that anything is
    /// currently looking at it — `hasEyes` is the separate executable truth,
    /// and a card claiming live sight of something nothing polls is exactly
    /// the confident lie the perception layer exists to refuse.
    case workspace
    /// Something queried on demand with nothing to look at.
    case dataSource
    /// Hands and services rather than a place: they act, and there is no
    /// picture of their state to hold.
    case service
    /// Something a watcher can see but nothing can act on — sight with no
    /// hands. An application riding the shared lane with no declared
    /// perception contract lands here.
    case perceptionOnly
}

/// One of Mary's own lanes.
public enum AmbientWorld: String, Sendable, Equatable, Hashable, CaseIterable {

    /// THE HOST LANE EVERY TAUGHT APPLICATION RIDES.
    ///
    /// Not "an application" — the channel through which any of them is
    /// perceived. A fact about TextEdit is stored under
    /// `AmbientPlace.application("textedit")`, whose `world` is this; the lane is
    /// what makes a fact about an application distinguishable from a fact
    /// about the Mac, and the registration is what says which application.
    case applications

    /// The machine itself — the hand that opens and activates things.
    case mac

    /// Settings and state that belong to no application.
    case system

    /// Raising, restoring and arranging windows. A service: it acts on
    /// windows, it is not a place with contents.
    case windowManagement = "window-management"

    /// The keyboard. Mary's hands for putting text where a cursor is.
    case typer

    /// WHETHER THIS LANE IS SOMETHING MARY CAN INVOKE.
    ///
    /// Four of the five are faculties: she types, she drives the machine, she
    /// reads and sets system state, she moves windows. `.applications` is the
    /// odd one and the important one — it is the channel every taught
    /// application's perception rides, not a thing to reach for. Asking to
    /// "invoke applications" is a category error, and a roster that offered
    /// it would be offering the user a lane instead of an app.
    ///
    /// Stated as a property rather than left implicit because the distinction
    /// is exactly the world-versus-place mixup this file guards: a faculty is
    /// part of Mary's state, a hosted application is not.
    public var isInvocable: Bool {
        switch self {
        case .applications: return false
        case .mac, .system, .windowManagement, .typer: return true
        }
    }

    /// The faculties, in `order` — what Mary can reach for right now.
    public static var invocable: [AmbientWorld] { allCases.filter(\.isInvocable) }

    /// The adapter owner id the roster and the dispatcher use.
    public var pluginOwner: String { rawValue }

    public static func from(pluginOwner: String) -> AmbientWorld? {
        AmbientWorld(rawValue: pluginOwner.lowercased())
    }

    public var worldClass: AmbientWorldClass {
        switch self {
        case .applications: return .perceptionOnly
        case .mac, .system, .windowManagement, .typer: return .service
        }
    }

    /// WHETHER ANYTHING IS LOOKING AT THIS LANE ITSELF — always false, and
    /// the reason is worth stating rather than leaving as a bare `false`.
    ///
    /// A lane is not observed; the applications riding it are. Asking the
    /// host lane whether it has eyes would answer for the channel and not the
    /// guest, which is precisely how Bonnie's version denied sight to every
    /// application taught by package. `AmbientPlace.hasEyes` asks the
    /// registration, and only falls back here when nothing owns the lane —
    /// where the honest answer is no.
    public var hasEyes: Bool { false }

    /// The lanes with live watchers of their own. Empty, by the above.
    public static var watched: [AmbientWorld] { allCases.filter(\.hasEyes) }

    /// Places queried without anything being open. None of Mary's own lanes
    /// is one; a data source would arrive as a package.
    public static var dataSources: [AmbientWorld] {
        allCases.filter { $0.worldClass == .dataSource }
    }

    /// WHICH CRAFT THIS LANE IS FOR — nothing, for all five.
    ///
    /// A craft belongs to an application, and applications are registrations.
    /// `AmbientPlace.ability` reads the disciplines a package declares; this
    /// is the fallback for a lane that owns no package, and there is no craft
    /// to name there.
    public var ability: AbilityID? { nil }

    /// Every Ability any lane realizes, in a stable order.
    ///
    /// Empty here, and still worth keeping as the ONE spelling of the
    /// deterministic ability order: `AmbientPlace.ability` uses it to break
    /// ties when a package declares several disciplines, and a `Set`'s own
    /// order would make the roster differ between runs.
    public static var realizedAbilities: [AbilityID] {
        var seen = Set<String>()
        return allCases.compactMap(\.ability).filter { seen.insert($0.rawValue).inserted }
    }

    /// Nil for every lane: workspace identity belongs to applications, and
    /// `AmbientPlace.focus` asks the registration for it.
    public var focus: WorkspaceFocus? { nil }

    public var displayName: String {
        switch self {
        case .applications: return "Applications"
        case .mac: return "Mac"
        case .system: return "System"
        case .windowManagement: return "Window Management"
        case .typer: return "Typer"
        }
    }

    /// Stable order for deterministic rendering — the debugger pane and the
    /// prompt must agree byte for byte, so nothing may depend on dictionary
    /// order. Lanes sort after applications, which is `allCases` order.
    public var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}
