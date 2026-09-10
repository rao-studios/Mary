//
//  AdmittedPlaceMentionsTests.swift
//  MaryAmbientTests
//
//  WHAT: Rung 6 — real-work evidence re-admits a place past roster/prompt
//        suppression, the same warrant `WorkspaceFocusArbiter.stickyLead`
//        reads for the prompt, applied here to the roster.
//  OUT:  AmbientRanker.admittedPlaceMentions
//

import Foundation
import Testing
@testable import MaryAmbient

@Suite struct AdmittedPlaceMentionsTests {

    private static let place = AmbientPlace.application("xcode")

    @Test func realWorkEvidenceAdmitsThePlace() {
        let admitted = AmbientRanker.admittedPlaceMentions(
            route: nil, referent: nil, utterance: "hello",
            glanced: [],
            evidence: [Self.place: FocusEvidence(place: Self.place, kind: .activity, at: Date())])
        #expect(admitted.contains(Self.place))
    }

    /// A mere activation (a click-through) is not real work — only `.activity` admits.
    @Test func aMereActivationDoesNotAdmit() {
        let admitted = AmbientRanker.admittedPlaceMentions(
            route: nil, referent: nil, utterance: "hello",
            glanced: [],
            evidence: [Self.place: FocusEvidence(place: Self.place, kind: .activation, at: Date())])
        #expect(!admitted.contains(Self.place))
    }

    /// No evidence at all — the default param — admits nothing extra, same
    /// as every rung above it when the turn names and glances at nothing.
    @Test func noEvidenceAdmitsNothingExtra() {
        let admitted = AmbientRanker.admittedPlaceMentions(
            route: nil, referent: nil, utterance: "hello", glanced: [], evidence: [:])
        #expect(admitted.isEmpty)
    }
}
