//
//  LaneAWorldHintTests.swift
//  MaryBrainTests
//
//  WHAT: Lane A inspires a look/read from the turn World; unled offer-to-open stays off.
//  OUT:  MaryPrompts.seerInstructions
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain

@Suite struct LaneAWorldHintTests {

    @Test func inspiredSightHintsIncomingLookAndDoesNotTakeUnledBranch() {
        let text = MaryPrompts.seerInstructions(
            liveWorkWorld: .unled,
            inspiredSight: true)
        #expect(text.contains("work they have selected on screen"))
        #expect(text.contains("Do not offer to open a file"))
        #expect(!text.contains("You are NOT looking at their screen right now"))
    }

    @Test func defaultPassStaysFreeOfTheWorldHint() {
        let text = MaryPrompts.seerInstructions()
        #expect(!text.contains("work they have selected on screen"))
        #expect(!text.contains("Do not offer to open a file"))
    }

    @Test func lookUnderwayOutranksInspiredSight() {
        let text = MaryPrompts.seerInstructions(
            lookUnderway: true,
            inspiredSight: true)
        #expect(text.contains("A look at their screen is being taken RIGHT NOW"))
        #expect(!text.contains("Do not offer to open a file"))
    }

    @Test func unledHeldFactsPlusInspiredSightDoesNotSayNotLooking() {
        let text = MaryPrompts.seerInstructions(
            liveWork: ["held from earlier"],
            liveWorkWorld: .unled,
            inspiredSight: true)
        #expect(text.contains("work they have selected on screen"))
        #expect(!text.contains("You are NOT looking at their screen right now"))
    }

    @Test func documentClaimPlusInspiredSightDoesNotSayNotLooking() {
        let text = MaryPrompts.seerInstructions(
            liveWork: ["func parameters() {}"],
            liveWorkWorld: .document(name: "Xcode", whole: false),
            inspiredSight: true)
        #expect(text.contains("Do not offer to open a file"))
        #expect(!text.contains("You are NOT looking at their screen right now"))
        #expect(text.contains("document open in front of them in Xcode"))
    }
}
