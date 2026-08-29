//
//  StackListenerTests.swift
//  MaryRuntimeTests
//
//  Stop of an external Seer/Totem is allowed only when the listener is the
//  named binary. These tests pin the parse and the path check — the lsof
//  call itself stays in LocalStackManager.
//

import Foundation
import Testing
@testable import MaryRuntime

@Suite struct StackListenerTests {

    @Test func lsofDashTCollapsesDuplicateListenPids() {
        #expect(StackListener.parsePIDs("12345\n12345\n67890\n") == [12345, 67890])
    }

    @Test func blankLsofOutputIsNoOneToStop() {
        #expect(StackListener.parsePIDs("").isEmpty)
        #expect(StackListener.parsePIDs("   \n").isEmpty)
    }

    @Test func onlyTheNamedBinaryIsAKillTarget() {
        let paths: [pid_t: String] = [
            11: "/Users/ritesh/Documents/rao/repositories/Seer/.build/release/seer-server",
            22: "/usr/bin/python3",
            33: "/tmp/seer-server-wrapper",
        ]
        #expect(
            StackListener.matching(
                listed: [11, 22, 33],
                executableName: "seer-server",
                commandPath: { paths[$0] })
                == [11])
    }

    @Test func aMissingPathIsNotAKillTarget() {
        #expect(
            StackListener.matching(
                listed: [99],
                executableName: "seer-server",
                commandPath: { _ in nil })
                .isEmpty)
    }
}
