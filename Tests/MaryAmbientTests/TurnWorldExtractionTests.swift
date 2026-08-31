//
//  TurnWorldExtractionTests.swift
//  MaryAmbientTests
//
//  WHAT: Turn World is the taught editor, never the applications host lane.
//  OUT:  AmbientWorld.Snapshot.place / AmbientEngine.leadPlace
//

import Foundation
import Testing
import MaryFoundation
@testable import MaryAmbient

@Suite struct TurnWorldExtractionTests {

    private func xcodeRegistration() -> ApplicationRegistration {
        ApplicationRegistration(
            id: "xcode",
            profile: ApplicationProfile(
                id: "xcode", title: "Xcode", summary: "IDE.",
                aliases: ["xcode"],
                applicationIdentifiers: ["com.apple.dt.Xcode"]),
            bundleIdentifiers: ["com.apple.dt.Xcode"],
            placeClass: .workspace,
            displayName: "Xcode",
            perception: ApplicationPerception(
                kind: .workspace, documentOperation: "read_buffer", pollSeconds: 15))
    }

    private func pagesRegistration() -> ApplicationRegistration {
        ApplicationRegistration(
            id: "pages",
            profile: ApplicationProfile(
                id: "pages", title: "Pages", summary: "Prose.",
                aliases: ["pages"],
                applicationIdentifiers: ["com.apple.iWork.Pages"]),
            bundleIdentifiers: ["com.apple.iWork.Pages"],
            placeClass: .workspace,
            displayName: "Pages",
            perception: ApplicationPerception(
                kind: .workspace, documentOperation: "read_document", pollSeconds: 15))
    }

    private var hostProfile: ApplicationProfile {
        ApplicationProfile(id: "applications", title: "Applications", summary: "Host lane.")
    }

    @Test func bundleIDSelectionResolvesToTaughtXcodeNotHostLane() {
        let registration = xcodeRegistration()
        AmbientApplicationIndexProvider.$scoped.withValue(
            AmbientApplicationRoster([registration])
        ) {
            let snapshot = AmbientWorld.Snapshot(
                tier: .selection,
                attention: .applications,
                subject: "Xcode",
                applicationID: "com.apple.dt.Xcode",
                selectedText: "func parameters() {}")
            #expect(snapshot.place == .application("xcode"))
            #expect(snapshot.place != .lane(.applications))

            let route = AmbientEngine.resolve(AmbientEngine.Inputs(
                utterance: "Let's take a look at this code",
                world: snapshot,
                profiles: [hostProfile, registration.profile]))
            #expect(route.selectionDefinesTurn)
            #expect(route.leadPlace == .application("xcode"))
            #expect(route.leadPlace != .lane(.applications))
            #expect(route.leadApplicationID == "xcode")
            #expect(route.inspiresSight)
        }
    }

    @Test func bundleIDSelectionResolvesToTaughtPagesNotHostLane() {
        let registration = pagesRegistration()
        AmbientApplicationIndexProvider.$scoped.withValue(
            AmbientApplicationRoster([registration])
        ) {
            let snapshot = AmbientWorld.Snapshot(
                tier: .selection,
                attention: .applications,
                subject: "Pages",
                applicationID: "com.apple.iWork.Pages",
                selectedText: "Once upon a time")
            #expect(snapshot.place == .application("pages"))

            let route = AmbientEngine.resolve(AmbientEngine.Inputs(
                utterance: "Can you help me understand what the parameters are here",
                world: snapshot,
                profiles: [hostProfile, registration.profile]))
            #expect(route.selectionDefinesTurn)
            #expect(route.leadPlace == .application("pages"))
            #expect(route.leadApplicationID == "pages")
        }
    }

    @Test func hostAdapterNeverRepresentsATaughtAppSelection() {
        let registration = xcodeRegistration()
        AmbientApplicationIndexProvider.$scoped.withValue(
            AmbientApplicationRoster([registration])
        ) {
            let snapshot = AmbientWorld.Snapshot(
                tier: .selection,
                attention: .applications,
                subject: "Xcode",
                applicationID: "com.apple.dt.Xcode",
                selectedText: "let x = 1")
            let route = AmbientEngine.resolve(AmbientEngine.Inputs(
                utterance: "what is this",
                world: snapshot,
                profiles: [hostProfile, registration.profile]))
            #expect(route.leadApplicationID != "applications")
            #expect(route.leadPlace?.application == "xcode")
        }
    }
}
