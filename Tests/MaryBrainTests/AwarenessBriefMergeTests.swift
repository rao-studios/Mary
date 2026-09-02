//
//  AwarenessBriefMergeTests.swift
//  MaryBrainTests
//
//  WHAT: The standing brief joins the lead place's section beside the caret
//        window — it never becomes the section, and never claims the sight.
//  OUT:  WorkspaceFocusArbiter.sections
//  PIN:  Whose place it is, and whether the document is held whole, stay the
//        answers of the observer that holds the text.
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain

@Suite struct AwarenessBriefMergeTests {

    private static let place = AmbientPlace.application("tests.editor")

    /// BESIDE THE CARET WINDOW, not instead of it: the arbiter merges every
    /// full section for the lead place, in the caller's order.
    @Test func theBriefMergesBesideTheCaretWindow() {
        let caret = WorkspaceFocusArbiter.Contribution(
            place: Self.place,
            discipline: .coding,
            full: ["Current file:\nBufferReader.swift\nWhat they see:\nfunc read() {}"],
            ambient: "In Test Editor: BufferReader.swift",
            liveDocumentIsWhole: false)
        let bearings = WorkspaceFocusArbiter.Contribution(
            place: Self.place,
            discipline: .coding,
            full: ["Around what they are working on:\n- open — S.swift:6: x"])
        let sections = WorkspaceFocusArbiter.sections(
            focus: .coding, contributions: [caret, bearings])
        #expect(sections.leadPlace == Self.place)
        #expect(sections.leadContext.count == 2)
        #expect(sections.leadContext[0].contains("What they see"))
        #expect(sections.leadContext[1].contains("S.swift:6"))
        // The document's own observer still decides the sight claim.
        #expect(sections.liveWorld == .document(name: nil, whole: false))
    }

    /// A brief with no document behind it does not claim to be one.
    @Test func theBriefMakesNoClaimAboutSight() {
        let bearings = WorkspaceFocusArbiter.Contribution(
            place: Self.place,
            discipline: .coding,
            full: ["Around what they are working on:\n- open — S.swift:6: x"],
            liveDocumentIsWhole: nil)
        let sections = WorkspaceFocusArbiter.sections(
            focus: .coding, contributions: [bearings])
        #expect(sections.liveWorld == .application(nil))
    }
}
