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

/// THE DISCIPLINE AXIS — the kind of WORK a place hosts. Not a taxonomy of
/// applications but of craft: the arbiter uses it to decide whether a
/// manuscript and a source file are rivals for the same attention or two
/// unrelated things.
///
/// AN OPEN SET, and that is the point. A discipline IS one Ability — the same
/// word on purpose — so the disciplines are whichever installed packages
/// declare `paradigm: .discipline`, and installing one more is a package
/// import rather than a new case here. This was two frozen cases (`coding`,
/// `writing`); every list that enumerated them is now a question asked of the
/// registry, because a closed set is a gate, and a gate cannot be taught.
public struct WorkspaceFocus: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ abilityID: AbilityID) { self.rawValue = abilityID.rawValue }

    /// The Ability a package realizes in order to join this discipline. THE
    /// SAME WORD ON PURPOSE. A discipline is not a second taxonomy laid over
    /// the packages — it is one Ability, seen on the axis the arbiter splits on.
    public var abilityID: AbilityID { AbilityID(rawValue) }

    /// The two Mary ships. NAMES, NOT A MEMBERSHIP LIST: code that reads well
    /// saying `.coding` still may, but nothing may enumerate the disciplines
    /// from here — ask `AmbientCapabilityIndexProvider.current.disciplines`,
    /// which answers for whatever is installed.
    public static let coding = WorkspaceFocus(rawValue: "coding")
    public static let writing = WorkspaceFocus(rawValue: "writing")
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

    /// THE SAME GUARD, FROM THE LOGICAL ID. A click gives a bundle id; a
    /// declaration, a bench or a chip gives the application the graph knows —
    /// and both have to pass the same two conditions, because `hasEyes` is what
    /// keeps the pin pinnable-only and the discipline is what it pins TO.
    public static func from(applicationID: String) -> PinnedWorld? {
        guard let registration = AmbientApplicationIndexProvider.current
                  .registration(id: applicationID),
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
