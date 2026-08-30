//
//  AmbientWorld.swift
//  MaryAmbient
//
//  WHAT: Mary's standing lanes (what she is now). Not a place, not an app.
//  OUT:  AmbientRealm (candidates) → AmbientPlace (decided where)
//  PIN:  Store keys (world, application). Apps are Plugin packages on
//        .applications — no per-app enum cases.
//

import Foundation

/// Kind of place a registration answers with. Ranking reads this.
/// `perceptionOnly` = seen, not watched (no declared observation channel).
public enum AmbientWorldClass: String, Sendable, Equatable, CaseIterable {
    /// Place with contents; document focus matters. Not proof of live sight
    /// (`hasEyes` is that).
    case workspace
    /// Something queried on demand with nothing to look at.
    case dataSource
    /// Hands and services rather than a place: they act, and there is no
    /// picture of their state to hold.
    case service
    /// Sight with no hands. Shared-lane apps with no perception contract.
    case perceptionOnly
}

/// One of Mary's own lanes.
public enum AmbientWorld: String, Sendable, Equatable, Hashable, CaseIterable {

    /// Host lane every taught application rides. Channel, not an app.
    /// Facts: AmbientPlace.application("textedit") → this world.
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

    /// Whether Mary can invoke this lane. `.applications` is a channel, not a faculty.
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

    /// Lane itself is never observed; apps riding it are. Eyes: AmbientPlace.hasEyes.
    public var hasEyes: Bool { false }

    /// The lanes with live watchers of their own. Empty, by the above.
    public static var watched: [AmbientWorld] { allCases.filter(\.hasEyes) }

    /// Places queried without anything being open. None of Mary's own lanes
    /// is one; a data source would arrive as a package.
    public static var dataSources: [AmbientWorld] {
        allCases.filter { $0.worldClass == .dataSource }
    }

    /// Craft belongs to registrations. AmbientPlace.ability reads the package.
    public var ability: AbilityID? { nil }

    // Ability order lives on WorkspaceFocus. AmbientPlace.ability is the reader.

    /// Nil: workspace identity belongs to apps. AmbientPlace.focus asks the registration.
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

    /// Stable render order. Debugger and prompt must agree. allCases order.
    public var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}
