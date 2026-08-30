//
//  WorkspaceFocusModels.swift
//  MaryAmbient
//
//  WHAT: Kind of work (coding/writing) and which place the user planted a flag in.
//  OUT:  AmbientPlace.focus / PinnedWorld. An application is a registration, never a compiled case.
//  PIN:  Pinnable ⟺ observable (hasEyes). Discipline rides along so tile, arbiter, and pin agree.
//
import Foundation
import MaryFoundation

/// THE DISCIPLINE AXIS — coding or writing, or neither. Not a taxonomy of applications but
/// of WORK: the arbiter uses it to decide whether a manuscript and a source file are rivals
/// for the same attention or two unrelated things.
public enum WorkspaceFocus: String, CaseIterable, Sendable, Equatable {
    case coding
    case writing

    /// The Ability a package realizes in order to join this discipline. THE SAME WORD ON
    /// PURPOSE. A discipline is not a second taxonomy laid over the packages — it is one
    /// Ability, seen on the axis the arbiter splits on.
    public var abilityID: AbilityID { AbilityID(rawValue) }

    /// The disciplines as Ability ids, in precedence order. CODING BEFORE WRITING, which is
    /// `allCases` order and therefore the declaration order above: a package realizing both is
    /// a coding workspace that also writes, not a writing one that also codes.
    public static var abilityOrder: [AbilityID] { allCases.map(\.abilityID) }
}

/// A USER-PLANTED FOCUS PIN.
public struct PinnedWorld: Sendable, Equatable {

    /// The registered application's logical id.
    public let applicationID: String

    /// The discipline it registers for, frozen at pin time.
    public let focus: WorkspaceFocus

    public init(applicationID: String, focus: WorkspaceFocus) {
        self.applicationID = applicationID
        self.focus = focus
    }

    /// Click → place. Asks the roster, and refuses everything it does not know: there is no
    /// compiled whitelist to consult first, because there are no compiled applications. Both
    /// halves of the guard are load-bearing. `hasEyes` keeps the pin pinnable-only.
    public static func from(bundleID: String?) -> PinnedWorld? {
        guard let bundleID,
              let registration = AmbientApplicationIndexProvider.current
                  .registration(bundleID: bundleID),
              registration.hasEyes,
              let focus = registration.place.focus
        else { return nil }
        return PinnedWorld(applicationID: registration.id, focus: focus)
    }

    /// Where the pin points. Resolved through the roster on every read rather
    /// than held, because a pin is a value that outlives an import: a package
    /// can be reinstalled under the same id and the place must follow it.
    public var place: AmbientPlace {
        AmbientApplicationIndexProvider.current.registration(id: applicationID)?.place
            ?? .application(applicationID)
    }
}
