//
//  PassageRosterFixture.swift
//  MaryPluginTests
//
//  WHAT: Process-wide roster so passage helpers have a place with eyes.
//  OUT:  PassageTests + PassageRefreshTests
//  PIN:  Installed once — helpers sit too far from test bodies for TaskLocal
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
