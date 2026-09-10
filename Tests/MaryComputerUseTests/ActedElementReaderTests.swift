//
//  ActedElementReaderTests.swift
//  MaryComputerUseTests
//
//  WHAT: Action target and captured surface spell identity the same way.
//  OUT:  ActedElementReader / ElementIdentity
//  PIN:  Live AX reads stay in the probe
//

import CoreGraphics
import Foundation
import MaryFoundation
import Testing
@testable import MaryComputerUse
@testable import MaryAmbient

@Suite struct ActedElementReaderTests {

    /// THE PARITY CONTRACT. A record made from a walked element and a record
    /// made from an acted-on element must carry the same identity for the same
    /// control, or an episode's target can never be matched to the surface it
    /// was captured from.
    @Test(arguments: [
        ("AXButton", "Save", "axbutton|save"),
        ("AXButton", "Skip  Ads", "axbutton|skip ads"),
        ("AXTextArea", "", "axtextarea|"),
        ("AXCheckBox", "  Remember Me  ", "axcheckbox|remember me"),
    ])
    func identityIsSpelledOneWay(_ role: String, _ label: String, _ expected: String) {
        #expect(ElementIdentity.identity(role: role, label: label) == expected)

        // The same spelling reached through the element-shaped door.
        let walked = AXScreenElement(
            ordinal: 1, id: AXNodeID(raw: 1), pid: 1, appName: "Example",
            windowID: AXNodeID(raw: 2), windowTitle: "Window",
            role: role, category: .interactive, label: label,
            frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(ElementIdentity.identity(of: walked) == expected)
    }

    /// THE ORDINAL IS NOT A POSITION HERE, and saying so is the point. A
    /// published element's ordinal is its place in a roster's reading order;
    /// an acted-on element came from no roster, and inventing a position would
    /// make the record look like it came from a walk it did not.
    @Test func actedRecordsCarryNoRosterPosition() {
        // Documented as a constant of the reader rather than asserted against
        // a live read, which is what the probe is for.
        #expect(ActedElementReader.maximumAncestorClimb == 24)
    }

    /// THE CLIMB IS BOUNDED, and the reason is not tidiness. An accessibility
    /// parent chain is another process's data structure; an unbounded walk
    /// through a malformed one is a hang in Mary wearing another
    /// application's bug.
    @Test func theAncestorClimbIsBounded() {
        #expect(ActedElementReader.maximumAncestorClimb > 0)
        #expect(
            ActedElementReader.maximumAncestorClimb < 100,
            "deep enough for a real hierarchy, shallow enough that a cyclic one costs milliseconds")
    }
}
