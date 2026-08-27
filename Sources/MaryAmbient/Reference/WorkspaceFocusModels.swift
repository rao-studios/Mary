//
//  WorkspaceFocusModels.swift
//  MaryAmbient
//
//  WHAT KIND OF WORK IS HAPPENING, and WHICH PLACE the user has planted a
//  flag in. Two small types, and both got smaller in Mary for the same
//  reason: an application is a registration, never a compiled case.
//
//  WHAT USED TO BE HERE. Bonnie carried a `WritingApp` enum — pages,
//  textEdit, keynote — so that every "which writing app" question could be a
//  switch rather than a ternary. That was the right shape for a build where
//  the writing applications were compiled in and countable. Mary has no
//  compiled applications at all, so the enum would have exactly zero cases,
//  and every question it answered ("what is this app called", "does its
//  watcher hold the whole document") is now a question about a registration —
//  asked of `AmbientPlace`, which resolves it through the roster.
//
//  A PIN IS THEREFORE JUST A PLACE AND ITS DISCIPLINE. Bonnie's `PinnedWorld`
//  was a three-case enum where two cases named compiled worlds and the third
//  carried a registration id; with the compiled worlds gone the third case is
//  the whole type, and an enum with one case is a struct wearing a costume.
//

import Foundation
import MaryFoundation

/// THE DISCIPLINE AXIS — coding or writing, or neither.
///
/// Not a taxonomy of applications but of WORK: the arbiter uses it to decide
/// whether a manuscript and a source file are rivals for the same attention
/// or two unrelated things. A package declares which disciplines it realizes,
/// and `AmbientPlace.focus` projects that down to this.
public enum WorkspaceFocus: String, CaseIterable, Sendable, Equatable {
    case coding
    case writing

    /// The Ability a package realizes in order to join this discipline.
    ///
    /// THE SAME WORD ON PURPOSE. A discipline is not a second taxonomy laid
    /// over the packages — it is one Ability, seen on the axis the arbiter
    /// splits on. `writing.mary` is the worked example: its id is the
    /// discipline's own name, and an application joins by realizing one of its
    /// Skills rather than by claiming membership.
    public var abilityID: AbilityID { AbilityID(rawValue) }

    /// The disciplines as Ability ids, in precedence order.
    ///
    /// CODING BEFORE WRITING, which is `allCases` order and therefore the
    /// declaration order above: a package realizing both is a coding workspace
    /// that also writes, not a writing one that also codes.
    ///
    /// This is the ONE deterministic ordering of abilities. `AmbientPlace`
    /// needs it because `ApplicationProfile.abilities` is a `Set`, and a set's
    /// own order would make the roster differ between runs. It lives here, on
    /// the axis, because the previous home — the lanes — stopped realizing any
    /// craft when the compiled applications went away; see `AmbientPlace.ability`
    /// for what an empty order cost.
    public static var abilityOrder: [AbilityID] { allCases.map(\.abilityID) }
}

/// A USER-PLANTED FOCUS PIN — the debugger's "watch THIS place" gesture.
///
/// Sticky where the ambient signal decays: the ordinary churn of activation
/// and selection never touches it, and only an explicit clear (or a relaunch
/// — the pin is deliberately in-memory) removes it. A spoken domain still
/// wins for its one turn: if the user does name a place, that must work.
///
/// PINNABLE ⟺ OBSERVABLE, and that is the whole admission rule. Bonnie
/// recorded the objection this answers: widening the pin "would put an
/// unpinnable value into the pin" — a user could click a tile for something
/// nothing is looking at, and Mary would then insist on a place she cannot
/// see. `from(bundleID:)` gates on the registration's own two-halves `hasEyes`
/// (it classes itself a workspace AND declares a real channel), so an
/// unobservable place simply has no pin to plant.
///
/// The discipline rides along rather than being re-derived, so the debugger's
/// tile, the arbiter's register and the pin can never disagree about whether
/// the pinned application is a coding or a writing place.
public struct PinnedWorld: Sendable, Equatable {

    /// The registered application's logical id.
    public let applicationID: String

    /// The discipline it registers for, frozen at pin time.
    public let focus: WorkspaceFocus

    public init(applicationID: String, focus: WorkspaceFocus) {
        self.applicationID = applicationID
        self.focus = focus
    }

    /// Click → place. Asks the roster, and refuses everything it does not
    /// know: there is no compiled whitelist to consult first, because there
    /// are no compiled applications.
    ///
    /// Both halves of the guard are load-bearing. `hasEyes` keeps the pin
    /// pinnable-only; a nil `focus` means the package realizes neither
    /// discipline, and pinning to a register that does not exist would leave
    /// the arbiter holding a pin it cannot honour.
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
