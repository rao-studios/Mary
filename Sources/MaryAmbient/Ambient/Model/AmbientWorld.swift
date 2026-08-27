//
//  AmbientWorld.swift
//  MaryAmbient
//
//  MARY'S OWN LANES — and deliberately nothing else.
//
//  This enum is the CLOSED half of the `AmbientRealm` taxonomy: the places
//  Mary herself is, as opposed to the places she is looking at. There are
//  five, they are all things this build ships, and the list is not expected
//  to grow when a user teaches her a new application — because teaching her
//  an application does not add a world.
//
//  WHAT IS NOT HERE IS THE POINT. There is no `textEdit` case, no `pages`,
//  no `xcode`. Every application arrives as a Plugin package and lives as
//  `AmbientRealm.dynamic("textedit")`, riding the `.applications` lane and
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
//  now questions about a REGISTRATION, and `AmbientRealm` asks them there.
//  What is left here answers only for Mary's own lanes, and answers "no" or
//  "nothing" for all of them, honestly: the typer is not a place with
//  contents, and the applications lane is a channel rather than a location.
//
//  THIS ALSO CLOSES A GAP BY CONSTRUCTION. Bonnie's passage backing was keyed
//  on this enum, so an application taught by package — having no case — could
//  be read, focused and remembered but could never have a passage cut from
//  it. There was a documented note about that. With no application cases at
//  all, there is no set to be left out of: passages key on the realm, and
//  every application is a realm the same way.
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
    /// `AmbientRealm.dynamic("textedit")`, whose `world` is this; the lane is
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
    /// application taught by package. `AmbientRealm.hasEyes` asks the
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
    /// `AmbientRealm.ability` reads the disciplines a package declares; this
    /// is the fallback for a lane that owns no package, and there is no craft
    /// to name there.
    public var ability: AbilityID? { nil }

    /// Every Ability any lane realizes, in a stable order.
    ///
    /// Empty here, and still worth keeping as the ONE spelling of the
    /// deterministic ability order: `AmbientRealm.ability` uses it to break
    /// ties when a package declares several disciplines, and a `Set`'s own
    /// order would make the roster differ between runs.
    public static var realizedAbilities: [AbilityID] {
        var seen = Set<String>()
        return allCases.compactMap(\.ability).filter { seen.insert($0.rawValue).inserted }
    }

    /// Nil for every lane: workspace identity belongs to applications, and
    /// `AmbientRealm.focus` asks the registration for it.
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
