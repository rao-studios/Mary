//
//  DispositionTotalityTests.swift
//  MaryFoundationTests
//
//  THE MAP BETWEEN THE RUNTIME'S VOCABULARY AND THE DATASET'S MUST BE TOTAL.
//
//  `SkillRunStatus` is what the runtime says about a run right now.
//  `BehavioralDisposition` is what a written episode will still mean in a
//  year. They are deliberately separate types, and the whole value of that
//  separation depends on the translation between them being complete and
//  deliberate — a status that fell through to a default would land in the
//  dataset as a guess nobody made on purpose.
//
//  The compiler enforces most of this: `init(_ status:)` switches
//  exhaustively, so a new `SkillRunStatus` case breaks the build until
//  somebody decides what it means. These tests cover what the compiler
//  cannot — that every status actually produces a written case rather than
//  the decode-only `.unknown`, and that the round trip is stable.
//

import Foundation
import Testing
@testable import MaryFoundation

@Suite struct DispositionTotalityTests {

    /// Every runtime status maps to a disposition this build would write.
    /// `.unknown` exists for reading a future file, never for describing a
    /// run that just happened.
    @Test(arguments: SkillRunStatus.allCases)
    func everyStatusMapsToAWrittenDisposition(_ status: SkillRunStatus) {
        let disposition = BehavioralDisposition(status)
        #expect(
            disposition != .unknown,
            "\(status) has no deliberate disposition — decide what it means, don't let it default")
    }

    /// The mapping is pinned case by case, so a change to it is a change
    /// somebody has to make on purpose in two places.
    @Test func theMappingIsWhatItSaysItIs() {
        #expect(BehavioralDisposition(.succeeded) == .succeeded)
        #expect(BehavioralDisposition(.failed) == .failed)
        #expect(BehavioralDisposition(.blocked) == .blocked)
        #expect(BehavioralDisposition(.deferred) == .deferred)
        #expect(BehavioralDisposition(.cancelled) == .cancelled)
        #expect(BehavioralDisposition(.requested) == .requestedConfirmation)
        #expect(BehavioralDisposition(.running) == .unsettled)
    }

    /// `.requested` is the one rename that carries meaning: "requested" reads
    /// like the user requested it, when in fact MARY requested permission and
    /// the action has not run. The dataset spells that out.
    @Test func requestedMeansMaryAskedNotThatTheActionRan() {
        let disposition = BehavioralDisposition(.requested)
        #expect(disposition == .requestedConfirmation)
        #expect(!disposition.didRun)
    }

    /// Every disposition round-trips through its raw value — the property a
    /// stored dataset depends on most.
    @Test(arguments: BehavioralDisposition.allCases)
    func everyDispositionRoundTrips(_ disposition: BehavioralDisposition) throws {
        let data = try JSONEncoder().encode(disposition)
        let decoded = try JSONDecoder().decode(BehavioralDisposition.self, from: data)
        #expect(decoded == disposition)
    }

    /// The unknown case is reachable only by decoding something this build
    /// never wrote.
    @Test func unknownIsReachableOnlyByDecoding() throws {
        let decoded = try JSONDecoder().decode(
            BehavioralDisposition.self, from: Data("\"notAThingYet\"".utf8))
        #expect(decoded == .unknown)
        #expect(!decoded.didRun, "an unrecognized disposition must not be assumed to have run")
    }

    /// `didRun` splits the vocabulary the way a training filter will: what
    /// touched the world versus what was refused or merely proposed. Pinned
    /// exhaustively, because getting one of these backwards would silently
    /// mislabel a whole population of rows.
    @Test func didRunSplitsTheVocabularyDeliberately() {
        let ran: Set<BehavioralDisposition> =
            [.succeeded, .failed, .deferred, .cancelled, .unsettled]
        let didNotRun: Set<BehavioralDisposition> =
            [.blocked, .requestedConfirmation, .unknown]

        #expect(ran.union(didNotRun) == Set(BehavioralDisposition.allCases))
        for disposition in ran { #expect(disposition.didRun, "\(disposition)") }
        for disposition in didNotRun { #expect(!disposition.didRun, "\(disposition)") }
    }

    /// Both tolerant enums answer to the same rule, so a reader meeting an
    /// unfamiliar file degrades the same way in both places.
    @Test func sealReasonsAreTolerantToo() throws {
        for reason in EpisodeSealReason.allCases where reason != .unknown {
            let data = try JSONEncoder().encode(reason)
            #expect(try JSONDecoder().decode(EpisodeSealReason.self, from: data) == reason)
        }
        #expect(
            try JSONDecoder().decode(
                EpisodeSealReason.self, from: Data("\"somethingElse\"".utf8)) == .unknown)
    }
}
