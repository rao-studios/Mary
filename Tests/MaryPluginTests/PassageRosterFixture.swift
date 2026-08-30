//
//  PassageRosterFixture.swift
//  MaryPluginTests
//
//  A ROSTER THE PASSAGE SUITES CAN STAND ON.
//
//  A passage can only be cut from a place with EYES, and in Mary eyes come
//  from a registration — an application that classes itself a workspace AND
//  declares a way to be observed. Bonnie's passage tests needed no roster
//  because their places were compiled worlds that answered `hasEyes` from a
//  switch; here the same test needs the same fact to arrive the way it
//  arrives in a real turn.
//
//  INSTALLED PROCESS-WIDE, not scoped per test, and deliberately: these
//  suites construct passages inside helpers far from any test body, so a
//  TaskLocal would have to be threaded through every one of them. The roster
//  is inert — two registrations nothing else looks up — and installing it
//  once is closer to the running system than wrapping thirty call sites.
//

import Foundation
import MaryAmbient
import MaryFoundation

enum PassageRosterFixture {

    /// Two observed applications: one that writes, one that codes — so
    /// "the other one" has an answer and the two disciplines are both live.
    ///
    /// THE NAMES ARE INVENTED, and that is the point. A fixture naming a real
    /// product invites a reader to believe Mary knows about that product, and
    /// she does not: a place is whatever a package declared. Quill and Forge
    /// exist only here, which is exactly as much as any application exists to
    /// the code under test.
    static let registrations: [ApplicationRegistration] = [
        ("quill", AbilityID.writing, "note"),
        ("forge", AbilityID.coding, "file"),
    ].map { id, ability, noun in
        ApplicationRegistration(
            id: id,
            profile: ApplicationProfile(
                id: id, title: id.capitalized, summary: "A fixture.",
                abilities: [ability],
                documentNoun: noun),
            bundleIdentifiers: ["com.example.\(id)"],
            worldClass: .workspace,
            displayName: id.capitalized,
            perception: ApplicationPerception(
                kind: .workspace, documentOperation: "read_document", pollSeconds: 3))
    }

    /// Idempotent — every suite in this target may call it, and the last
    /// caller installs the same roster.
    static func install() {
        AmbientApplicationIndexProvider.install {
            AmbientApplicationRoster(registrations)
        }
    }
}
