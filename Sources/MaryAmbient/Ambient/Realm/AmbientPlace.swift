//
//  AmbientPlace.swift
//  MaryAmbient
//
//  WHAT: Where a fact lives — native lane or registered application.
//  IN:   AmbientAttention (closed) / ApplicationRegistration (open)
//  OUT:  store keys, ranking, prompt
//  PIN:  Place is the address (lane or taught app). A snapshot is AT a place; place ≠ realm ≠ attention.
//

import Foundation

public enum AmbientPlace: Sendable, Equatable, Hashable {

    /// A built-in world answering for itself.
    case lane(AmbientAttention)

    /// Registered application's logical id (`"sketch"`), riding the `.applications` host lane.
    /// PIN: Registered places never carry a bundle identifier.
    case application(String)

    // MARK: - The (world, application) projection

    /// Closed world. Dynamic places ride the `.applications` host lane, never a case of their own.
    public var attention: AmbientAttention {
        switch self {
        case .lane(let attention): return attention
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

    /// The pair spelling, kept as a factory so every existing call site compiles unchanged.
    public init(attention: AmbientAttention, application: String? = nil) {
        if let application, !application.isEmpty {
            self = .application(application)
        } else {
            self = .lane(attention)
        }
    }

    // No `.world(w)` sugar — that used to stand in for `.lane(w)` and mixed case with lane.

    // MARK: - Case axes

    public var isLane: Bool {
        if case .lane = self { return true }
        return false
    }

    public var isApplication: Bool {
        if case .application = self { return true }
        return false
    }

    /// Perception axis — both cases can be eyeless; not an identity.
    public var isEyeless: Bool { !hasEyes }

    // MARK: - Tokens

    /// Place half of a key id (`calendar` / `other_apps:sketch`).
    /// PIN: Colon, not a second slash — keys split on the first `/`.
    public var token: String {
        switch self {
        case .lane(let attention):
            return attention.rawValue
        case .application(let id):
            return "\(AmbientAttention.applications.rawValue):\(id)"
        }
    }

    /// Persisted spelling — `"pages"` and `"sketch"` as peers, no prefix.
    /// PIN: Distinct from `token`; a prefix would orphan deposited rows.
    public var memoryToken: String {
        switch self {
        case .lane(let attention): return attention.rawValue
        case .application(let id): return id
        }
    }

    /// Inverse of `token`. Splits on the first colon; only `.applications` spells dynamics.
    public static func from(token: String) -> AmbientPlace? {
        if let colon = token.firstIndex(of: ":") {
            guard String(token[..<colon]) == AmbientAttention.applications.rawValue else {
                return nil
            }
            let id = String(token[token.index(after: colon)...])
            return id.isEmpty ? nil : .application(id)
        }
        return AmbientAttention.from(pluginOwner: token).map { .lane($0) }
    }

    /// Lead place: dynamic id outranks the world; resolve through registration when installed.
    public static func lead(
        attention: AmbientAttention?, applicationID: String?
    ) -> AmbientPlace? {
        if let applicationID, !applicationID.isEmpty {
            return AmbientApplicationIndexProvider.current
                .registration(id: applicationID)?.place ?? .application(applicationID)
        }
        return attention.map { .lane($0) }
    }

    // MARK: - The taxonomy

    /// Registration backing this place, if any. Resolved through the installed index, not held.
    public var registration: ApplicationRegistration? {
        guard case .application(let id) = self else { return nil }
        return AmbientApplicationIndexProvider.current.registration(id: id)
    }

    /// Taxonomy class. Registration's answer when one owns this lane — host class describes the host.
    public var placeClass: AmbientPlaceClass {
        registration?.placeClass ?? attention.placeClass
    }

    /// Whether anything is looking at this place.
    /// PIN: Not simply `placeClass == .workspace` — a package may declare no observation.
    public var hasEyes: Bool {
        if let registration { return registration.hasEyes }
        return attention.hasEyes
    }

    /// The discipline this place hosts, or none. WHATEVER IS INSTALLED —
    /// a place hosts a discipline when the Ability it realizes IS one, so a
    /// third craft needs no case here.
    public var focus: WorkspaceFocus? {
        guard let registration else { return attention.focus }
        guard let ability,
              AmbientCapabilityIndexProvider.current.disciplines.contains(ability)
        else { return nil }
        return WorkspaceFocus(ability)
    }

    /// Craft this place is for. `focus` above is the discipline projection.
    /// PRECEDENCE IS THE REGISTRY'S, not an enum's declaration order: an app
    /// realizing two disciplines is whichever the installed graph ranks first.
    public var ability: AbilityID? {
        guard let registration else { return attention.ability }
        let declared = registration.profile.abilities
        return AmbientCapabilityIndexProvider.current.disciplines
            .first(where: declared.contains)
            ?? declared.sorted { $0.rawValue < $1.rawValue }.first
    }

    /// Spoken name. Browser and generic-app places have no registration — do not fall back to "Applications".
    public var displayName: String {
        if let registration { return registration.displayName }
        if case .application(let id) = self {
            // Which browser, when the ledger knows.
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
        return attention.displayName
    }

    /// Stable render order. Built-ins keep their positions; registrations sort after, in roster order.
    public var order: Int {
        switch self {
        case .lane(let attention):
            return attention.order
        case .application(let id):
            let roster = AmbientApplicationIndexProvider.current.all
            let position = roster.firstIndex { $0.id == id } ?? roster.count
            return 1_000 + position
        }
    }
}
