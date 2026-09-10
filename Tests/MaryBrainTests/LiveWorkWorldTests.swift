//
//  LiveWorkWorldTests.swift
//  MaryBrainTests
//
//  WHAT: Unled arbiter yields to the turn World when a taught place is standing.
//  OUT:  LiveWorkWorld.claim
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain

@Suite struct LiveWorkWorldTests {

    @Test func unledArbiterTakesDocumentClaimFromSelectionWorld() {
        AmbientApplicationIndexProvider.$scoped.withValue(
            AmbientApplicationRoster([
                ApplicationRegistration(
                    id: "xcode",
                    profile: ApplicationProfile(id: "xcode", title: "Xcode", summary: "IDE."),
                    bundleIdentifiers: ["com.apple.dt.Xcode"],
                    placeClass: .workspace,
                    displayName: "Xcode"),
            ])
        ) {
            let machine = AmbientWorld.Snapshot(
                sense: .selection,
                attention: .applications,
                subject: "AbilityRuntime.swift",
                applicationID: "com.apple.dt.Xcode",
                selectedText: "func foo()")
            let claimed = LiveWorkWorld.claim(arbiter: .unled, machine: machine)
            #expect(claimed == .document(name: "Xcode", whole: false))
        }
    }

    @Test func emptyMachineStaysUnled() {
        #expect(LiveWorkWorld.claim(arbiter: .unled, machine: nil) == .unled)
    }

    @Test func arbiterDocumentIsNotOverridden() {
        let machine = AmbientWorld.Snapshot(
            sense: .selection,
            attention: .applications,
            applicationID: "com.apple.dt.Xcode")
        let claimed = LiveWorkWorld.claim(
            arbiter: .document(name: "Buffer.swift", whole: true),
            machine: machine)
        #expect(claimed == .document(name: "Buffer.swift", whole: true))
    }
}
