//
//  VerifiedActivationTests.swift
//  MaryComputerUseTests
//
//  WHAT: The pure halves of the stage faculty — which process a family means,
//        and what a failure says.
//

import Testing
@testable import MaryComputerUse

@Suite struct VerifiedActivationTests {

    /// A HELPER BELONGS TO THE LONGEST REGULAR ID IT EXTENDS. A roster that
    /// matches a family by prefix can hand over a renderer; the regular member
    /// is what "bring Chrome forward" means.
    @Test func aHelperResolvesToTheRegularMemberOfItsFamily() {
        let regular = ["com.google.Chrome", "com.apple.dt.Xcode", "com.google"]
        #expect(VerifiedActivation.familyBundleID(
            forHelper: "com.google.Chrome.helper.renderer", regular: regular) == "com.google.Chrome")
        #expect(VerifiedActivation.familyBundleID(
            forHelper: "com.google.Chrome.helper", regular: regular) == "com.google.Chrome")
    }

    /// A regular id that merely shares letters is not a family: the helper's
    /// id must extend it by a dotted component.
    @Test func aSharedSpellingIsNotAFamily() {
        #expect(VerifiedActivation.familyBundleID(
            forHelper: "com.google.Chromecast.helper", regular: ["com.google.Chrome"]) == nil)
        #expect(VerifiedActivation.familyBundleID(
            forHelper: "com.example.Other", regular: ["com.google.Chrome"]) == nil)
    }

    /// EVERY FAILURE HAS ITS OWN SENTENCE. Eight browser call sites used to
    /// collapse all of these into "wouldn't come forward".
    @Test func eachFailureNamesItsCause() {
        let failures: [Activation.Failure] = [
            .notRunning, .refused, .cancelled, .noVisibleWindow, .stageHeld("typing"),
        ]
        let sentences = Set(failures.map { Activation.lost($0).reason(app: "Chrome") })
        #expect(sentences.count == failures.count)
        #expect(Activation.lost(.notRunning).reason(app: "Chrome") == "Chrome isn't running.")
        #expect(Activation(road: .raised, failure: nil).reason(app: "Chrome") == nil)
    }
}
