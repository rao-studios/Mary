//
//  TaughtApplicationFixture.swift
//  MaryBrainTests
//
//  A ROSTER THE BRAIN SUITES CAN STAND ON — two taught applications, one for
//  each discipline.
//
//  EVERY APPLICATION IN MARY IS A TAUGHT ONE, so a suite that needs a place
//  with eyes has to install a registration the way a real launch does. The
//  suites this replaces stood on compiled worlds that answered `hasEyes` from
//  a switch and needed no roster at all; the same test now needs the same
//  fact to arrive by the same road it arrives on in a running system, which
//  is the whole point of the change it is adapting to.
//
//  THE NAMES ARE INVENTED. A fixture naming a real product invites a reader
//  to believe some part of Mary knows about that product, and none does.
//
//  SCOPED, NOT INSTALLED. `AmbientApplicationIndexProvider.$scoped` binds to
//  one task tree, so concurrent suites cannot clear the roster underneath
//  each other — which a process-wide install in a parallel test run does
//  reliably and invisibly.
//

import Foundation
import MaryAmbient
import MaryFoundation

/// The taught writing application's logical id, and its place.
let taughtWritingID = "quill"
let taughtWritingPlace = AmbientPlace.application(taughtWritingID)
let taughtWritingBundleID = "com.example.quill"

/// The taught coding application's, for the suites that need a rival with a
/// different discipline.
let taughtCodingID = "forge"
let taughtCodingPlace = AmbientPlace.application(taughtCodingID)
let taughtCodingBundleID = "com.example.forge"

let taughtRoster = AmbientApplicationRoster([
    ApplicationRegistration(
        id: taughtWritingID,
        profile: ApplicationProfile(
            id: taughtWritingID, title: "Quill", summary: "A fixture that writes.",
            abilities: [.writing],
            applicationIdentifiers: [taughtWritingBundleID],
            documentNoun: "note"),
        bundleIdentifiers: [taughtWritingBundleID],
        worldClass: .workspace,
        displayName: "Quill",
        perception: ApplicationPerception(
            kind: .workspace, documentOperation: "read_document", pollSeconds: 3)),
    ApplicationRegistration(
        id: taughtCodingID,
        profile: ApplicationProfile(
            id: taughtCodingID, title: "Forge", summary: "A fixture that codes.",
            abilities: [.coding],
            applicationIdentifiers: [taughtCodingBundleID],
            documentNoun: "file"),
        bundleIdentifiers: [taughtCodingBundleID],
        worldClass: .workspace,
        displayName: "Forge",
        perception: ApplicationPerception(
            kind: .workspace, documentOperation: "read_file", pollSeconds: 3)),
])

/// Runs `body` with the taught roster installed for this task tree only.
func withTaughtRoster<T>(_ body: () throws -> T) rethrows -> T {
    try AmbientApplicationIndexProvider.$scoped.withValue(taughtRoster, operation: body)
}

/// The async spelling, for suites that dispatch inside the scope.
func withTaughtRoster<T>(_ body: () async throws -> T) async rethrows -> T {
    try await AmbientApplicationIndexProvider.$scoped.withValue(
        taughtRoster, operation: body)
}
