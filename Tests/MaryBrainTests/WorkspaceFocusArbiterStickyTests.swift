//
//  WorkspaceFocusArbiterStickyTests.swift
//  MaryBrainTests
//
//  WHAT: The ADHD case — a place still holds the lead though it is not
//        frontmost, warranted by ambient-world evidence rather than a clock.
//  OUT:  WorkspaceFocusArbiter.stickyLead
//

import Foundation
import Testing
import MaryAmbient
@testable import MaryBrain

@Suite struct WorkspaceFocusArbiterStickyTests {

    private static let coding = AmbientPlace.application("xcode")
    private static let writing = AmbientPlace.application("notes")

    private static func contribution(
        _ place: AmbientPlace, discipline: WorkspaceFocus, wasNamed: Bool = false
    ) -> WorkspaceFocusArbiter.Contribution {
        .init(place: place, discipline: discipline, full: ["live text"], wasNamed: wasNamed)
    }

    /// A mere activation (a click-through) carries no warrant at all — only
    /// real-work `.activity` evidence does.
    @Test func activationAloneDoesNotStick() {
        let now = Date()
        let evidence: [AmbientPlace: FocusEvidence] = [
            Self.coding: .init(place: Self.coding, kind: .activation, at: now),
        ]
        let sticky = WorkspaceFocusArbiter.stickyLead(
            evidence: evidence,
            contributions: [Self.contribution(Self.coding, discipline: .coding)],
            now: now)
        #expect(sticky == nil)
    }

    /// Real work in a coding place stays live though a writing place now leads on-screen.
    @Test func freshActivityStillLeadsAgainstNoRival() {
        let now = Date()
        let evidence: [AmbientPlace: FocusEvidence] = [
            Self.coding: .init(place: Self.coding, kind: .activity, at: now.addingTimeInterval(-30)),
        ]
        let sticky = WorkspaceFocusArbiter.stickyLead(
            evidence: evidence,
            contributions: [
                Self.contribution(Self.coding, discipline: .coding),
                Self.contribution(Self.writing, discipline: .writing),
            ],
            now: now)
        #expect(sticky == .coding)
    }

    /// Real typing in the RIVAL place — fresher `.activity` — steals the lead back.
    @Test func fresherRivalActivitySteals() {
        let now = Date()
        let evidence: [AmbientPlace: FocusEvidence] = [
            Self.coding: .init(place: Self.coding, kind: .activity, at: now.addingTimeInterval(-120)),
            Self.writing: .init(place: Self.writing, kind: .activity, at: now.addingTimeInterval(-5)),
        ]
        let sticky = WorkspaceFocusArbiter.stickyLead(
            evidence: evidence,
            contributions: [
                Self.contribution(Self.coding, discipline: .coding),
                Self.contribution(Self.writing, discipline: .writing),
            ],
            now: now)
        #expect(sticky == .writing)
    }

    /// Symmetric to the case above — a writing place sticks past a coding
    /// place that only activated. No discipline is special-cased.
    @Test func writingStaysStickyPastCodingActivation() {
        let now = Date()
        let evidence: [AmbientPlace: FocusEvidence] = [
            Self.writing: .init(place: Self.writing, kind: .activity, at: now.addingTimeInterval(-30)),
            Self.coding: .init(place: Self.coding, kind: .activation, at: now),
        ]
        let sticky = WorkspaceFocusArbiter.stickyLead(
            evidence: evidence,
            contributions: [
                Self.contribution(Self.coding, discipline: .coding),
                Self.contribution(Self.writing, discipline: .writing),
            ],
            now: now)
        #expect(sticky == .writing)
    }

    /// Naming a RIVAL place this turn beats stickiness outright, even though
    /// the sticky place's own evidence is fresher.
    @Test func namingARivalStandsStickinessDown() {
        let now = Date()
        let evidence: [AmbientPlace: FocusEvidence] = [
            Self.coding: .init(place: Self.coding, kind: .activity, at: now.addingTimeInterval(-5)),
        ]
        let sticky = WorkspaceFocusArbiter.stickyLead(
            evidence: evidence,
            contributions: [
                Self.contribution(Self.coding, discipline: .coding),
                Self.contribution(Self.writing, discipline: .writing, wasNamed: true),
            ],
            now: now)
        #expect(sticky == nil)
    }

    /// An exact freshness tie defers to ordinary frontmost arbitration
    /// rather than picking a winner arbitrarily.
    @Test func exactTieDoesNotSteal() {
        let now = Date()
        let stamp = now.addingTimeInterval(-10)
        let evidence: [AmbientPlace: FocusEvidence] = [
            Self.coding: .init(place: Self.coding, kind: .activity, at: stamp),
            Self.writing: .init(place: Self.writing, kind: .activity, at: stamp),
        ]
        let sticky = WorkspaceFocusArbiter.stickyLead(
            evidence: evidence,
            contributions: [
                Self.contribution(Self.coding, discipline: .coding),
                Self.contribution(Self.writing, discipline: .writing),
            ],
            now: now)
        #expect(sticky == nil)
    }

    /// The conversational referent keeps a place warm even past a stale (or
    /// absent) ledger stamp — talking about the code keeps it live.
    @Test func referentKeepsAPlaceWarmPastAStaleStamp() {
        let now = Date()
        let referent = ResolvedReferent(
            place: Self.coding, key: "Foo.swift", title: "Foo.swift", rung: .title)
        let sticky = WorkspaceFocusArbiter.stickyLead(
            evidence: [:],
            contributions: [
                Self.contribution(Self.coding, discipline: .coding),
                Self.contribution(Self.writing, discipline: .writing),
            ],
            referent: referent,
            now: now)
        #expect(sticky == .coding)
    }

    // MARK: - Composed with `sections` — worlds bridged, not silenced

    /// The sticky place gets the FULL live-work section; the place that
    /// actually leads on-screen is not silenced — it collapses to its own
    /// ambient line, same invariant `sections` already guarantees for any
    /// two live places. This is the "multitasking agent" feel end to end:
    /// switching windows mid-request does not drop the other world either.
    @Test func stickyCodingLeadsWhileWritingStillGetsItsLine() {
        let now = Date()
        let evidence: [AmbientPlace: FocusEvidence] = [
            Self.coding: .init(place: Self.coding, kind: .activity, at: now.addingTimeInterval(-30)),
        ]
        let contributions: [WorkspaceFocusArbiter.Contribution] = [
            .init(
                place: Self.coding, discipline: .coding,
                full: ["Current file:\nFoo.swift"], ambient: "In Xcode: Foo.swift"),
            .init(
                place: Self.writing, discipline: .writing,
                full: ["Current file:\nNotes.txt"], ambient: "In Notes: Notes.txt"),
        ]
        let sticky = WorkspaceFocusArbiter.stickyLead(
            evidence: evidence, contributions: contributions, now: now)
        #expect(sticky == .coding)
        let sections = WorkspaceFocusArbiter.sections(focus: sticky, contributions: contributions)
        #expect(sections.leadPlace == Self.coding)
        #expect(sections.leadContext.contains("Current file:\nFoo.swift"))
        #expect(sections.ambientNotes.contains("In Notes: Notes.txt"))
    }
}
