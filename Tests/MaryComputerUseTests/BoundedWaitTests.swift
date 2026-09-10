//
//  BoundedWaitTests.swift
//  MaryComputerUseTests
//
//  WHAT: RaceBox resolves exactly once, whoever answers first — a success
//        parked before anyone is waiting must survive a losing deadline.
//  OUT:  RaceBox / bounded / EmissionGate
//

import Foundation
import Testing
@testable import MaryComputerUse

@Suite struct BoundedWaitTests {

    /// THE BUG THIS FILE EXISTS TO CLOSE. `finish` used to leave `resolved`
    /// false on the park branch, so a value sitting unattached could still be
    /// overwritten by whoever called `finish` next — a fast success parked,
    /// then a slow deadline's `nil` silently replaced it before `attach` ever
    /// ran. The box must close the moment the FIRST value parks.
    @Test func firstFinishWinsWhenNothingIsAttachedYet() async {
        let box = RaceBox<Int>()
        box.finish(1)      // parks — nobody is attached yet
        box.finish(nil)    // must be a no-op: the box already resolved to 1
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            box.attach(continuation)
        }
        #expect(result == 1)
    }

    /// The mirror case — a losing `finish` after a value already resolved via
    /// an attached continuation must also be a no-op.
    @Test func finishAfterResolutionThroughAnAttachedContinuationIsANoOp() async {
        let box = RaceBox<Int>()
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            box.attach(continuation)
            box.finish(1)
            box.finish(2)   // must never be delivered — attach already fired
        }
        #expect(result == 1)
    }

    /// `bounded` itself: real work that finishes well inside the deadline.
    @Test func workWinsWhenFast() async {
        let result = await bounded(5) { 1 }
        #expect(result == 1)
    }

    /// `bounded` itself: work that never returns inside the deadline reports
    /// `nil`, the deadline's own honest answer.
    @Test func deadlineWinsWhenWorkIsSlow() async {
        let result: Int? = await bounded(0.05) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return 1
        }
        #expect(result == nil)
    }

    /// `EmissionGate` closes exactly once and never reopens.
    @Test func emissionGateIsOneWayAndIdempotent() {
        let gate = EmissionGate()
        #expect(gate.isOpen)
        gate.close()
        #expect(!gate.isOpen)
        gate.close()
        #expect(!gate.isOpen)
    }
}
