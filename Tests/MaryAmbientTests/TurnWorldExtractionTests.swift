//
//  TurnWorldExtractionTests.swift
//  MaryAmbientTests
//
//  WHAT: Turn World is the taught editor, never the applications host lane.
//  OUT:  AmbientWorld.Snapshot.place / AmbientRoute.leadApplicationID
//

import Foundation
import Testing
import MaryFoundation
@testable import MaryAmbient

@Suite struct TurnWorldExtractionTests {

    private func registration(
        id: String, title: String, bundleID: String, operation: String
    ) -> ApplicationRegistration {
        ApplicationRegistration(
            id: id,
            profile: ApplicationProfile(
                id: id, title: title, summary: "Taught application.",
                aliases: [id],
                applicationIdentifiers: [bundleID]),
            bundleIdentifiers: [bundleID],
            placeClass: .workspace,
            displayName: title,
            perception: ApplicationPerception(
                kind: .workspace, documentOperation: operation, pollSeconds: 15))
    }

    private var hostProfile: ApplicationProfile {
        ApplicationProfile(id: "applications", title: "Applications", summary: "Host lane.")
    }

    /// A bundle-id selection resolves to the taught application, on both the
    /// snapshot's ladder and the route's — never to the host lane it rode in on.
    @Test(arguments: [
        ("xcode", "Xcode", "com.apple.dt.Xcode", "read_buffer",
         "Let's take a look at this code", "func parameters() {}"),
        ("pages", "Pages", "com.apple.iWork.Pages", "read_document",
         "Can you help me understand what the parameters are here", "Once upon a time"),
    ])
    func bundleIDSelectionResolvesToTheTaughtApplication(
        id: String, title: String, bundleID: String, operation: String,
        utterance: String, selectedText: String
    ) {
        let registration = registration(
            id: id, title: title, bundleID: bundleID, operation: operation)
        AmbientApplicationIndexProvider.$scoped.withValue(
            AmbientApplicationRoster([registration])
        ) {
            let snapshot = AmbientWorld.Snapshot(
                sense: .selection,
                attention: .applications,
                subject: title,
                applicationID: bundleID,
                selectedText: selectedText)
            // The snapshot's own ladder: bundle id → registration.
            #expect(snapshot.place == .application(id))

            let route = AmbientEngine.resolve(AmbientEngine.Inputs(
                utterance: utterance,
                world: snapshot,
                profiles: [hostProfile, registration.profile]))
            #expect(route.selectionDefinesTurn)
            // The route's one stored answer. `leadPlace` derives from it.
            #expect(route.leadApplicationID == id)
        }
    }

    /// WHY THE LADDER ONLY RUNS ONE WAY. A legacy registration's place is its
    /// lane, which drops the logical id — so the id cannot be recovered from the
    /// place, and `leadApplicationID` has to be the stored half.
    @Test func aLegacyRegistrationsPlaceCannotYieldItsApplicationID() {
        let legacy = ApplicationRegistration(
            id: "typer",
            profile: ApplicationProfile(
                id: "typer", title: "Typer", summary: "Built-in.",
                aliases: ["typer"],
                applicationIdentifiers: ["com.example.Typer"]),
            bundleIdentifiers: ["com.example.Typer"],
            placeClass: .workspace,
            displayName: "Typer",
            legacyAttention: .typer)
        AmbientApplicationIndexProvider.$scoped.withValue(
            AmbientApplicationRoster([legacy])
        ) {
            let route = AmbientRoute(
                intent: .converse, decidedBy: .none, leadApplicationID: "typer")
            #expect(route.leadPlace == .lane(.typer))
            #expect(route.leadPlace?.application == nil)
            #expect(route.leadApplicationID == "typer")
        }
    }
}
