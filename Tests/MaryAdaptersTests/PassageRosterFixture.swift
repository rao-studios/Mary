//
//  PassageRosterFixture.swift
//  MaryAdaptersTests
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

    /// Two observed writing applications, which is the shape these suites
    /// assume: one to act in, and a second so "the other one" has an answer.
    static let registrations: [ApplicationRegistration] = ["pages", "xcode"].map { id in
        ApplicationRegistration(
            id: id,
            profile: ApplicationProfile(
                id: id, title: id.capitalized, summary: "A fixture.",
                abilities: [id == "xcode" ? .coding : .writing]),
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
