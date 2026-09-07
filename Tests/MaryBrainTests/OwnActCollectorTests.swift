//
//  OwnActCollectorTests.swift
//  MaryBrainTests
//
//  WHAT: The turn-scoped box the "looked first" capsule's records travel
//        through — task-local visibility, append order, one-shot drain.
//  OUT:  OwnActCollector
//

import Foundation
import Testing
import MaryFoundation
import MaryFoundationTestSupport
@testable import MaryBrain

@Suite struct OwnActCollectorTests {

    /// Nil outside any bound scope — the Life pulse's own dispatches (see
    /// `AbilityDispatching.perform`) never nest inside `sewnTurn`, so this is
    /// the exact condition that makes their `.append` calls silent no-ops.
    @Test func currentIsNilOutsideABoundScope() {
        #expect(OwnActCollector.current == nil)
    }

    /// Bound around an `await`, the same shape `sewnTurn` uses to wrap each
    /// fetch-first call — the task-local must survive the suspension.
    @Test func currentResolvesInsideItsBoundScopeAcrossASuspension() async {
        let collector = OwnActCollector()
        let seenInside = await OwnActCollector.$current.withValue(collector) {
            await Task.yield()
            return OwnActCollector.current === collector
        }
        #expect(seenInside)
        #expect(OwnActCollector.current == nil, "the binding must not leak past its scope")
    }

    /// Append order is call order — the capsule groups by Ability, but the
    /// per-run inspector list should still read as it happened.
    @Test func drainReturnsAppendsInOrder() {
        let collector = OwnActCollector()
        var first = BehaviorFixtures.typedRecord
        first.id = "run-a"
        var second = BehaviorFixtures.typedRecord
        second.id = "run-b"
        collector.append(first)
        collector.append(second)

        #expect(collector.drain().map(\.id) == ["run-a", "run-b"])
    }

    /// ONE-SHOT. A turn drains its own reads exactly once, right before the
    /// lane spawns — a second drain (a stray later call, a retry) must not
    /// hand out the same records twice.
    @Test func drainEmptiesTheBoxOneShot() {
        let collector = OwnActCollector()
        collector.append(BehaviorFixtures.typedRecord)

        #expect(collector.drain().count == 1)
        #expect(collector.drain().isEmpty)
    }
}
