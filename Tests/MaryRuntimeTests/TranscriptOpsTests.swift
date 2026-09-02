//
//  TranscriptOpsTests.swift
//  MaryRuntimeTests
//
//  WHAT: A chip and its own run rows must always resolve to the SAME bubble
//        — never a positional fallback onto whatever is streaming now.
//  OUT:  TranscriptOps.apply / anchorIndex
//  PIN:  The first coverage this reducer has ever had. `TranscriptOps` and
//        `ChatService.Center.State` are `package`, so `@testable import
//        MaryRuntime` reaches both without exposing them publicly.
//

import Foundation
import Testing
import MaryFoundation
import MaryFoundationTestSupport
@testable import MaryRuntime

@Suite struct TranscriptOpsTests {

    // MARK: - Fixtures

    private static func state(_ utterances: [Utterance]) -> ChatService.Center.State {
        var state = ChatService.Center.State()
        state.conversation.utterances = utterances
        return state
    }

    private static func bubble(
        turnID: UUID?, isStreaming: Bool = false, isThinking: Bool = false
    ) -> Utterance {
        var utterance = Utterance(role: .assistant, isThinking: isThinking, isStreaming: isStreaming)
        utterance.turnID = turnID
        return utterance
    }

    private static func run(id: String) -> BehavioralActionRecord {
        var record = BehaviorFixtures.typedRecord
        record.id = id
        return record
    }

    // MARK: - No positional fallback

    /// THE BUG: a run whose own turnID names a bubble that has been trimmed
    /// off the page used to fall through to `currentAssistantIndex` and land
    /// on whatever is CURRENTLY streaming — a stranger's reply. It must now
    /// drop instead.
    @Test func aRunRowNeverLandsOnAStrangersBubble() {
        let trimmedTurn = UUID()
        let strangersTurn = UUID()
        var state = Self.state([Self.bubble(turnID: strangersTurn, isStreaming: true)])
        state.activeTurnID = strangersTurn

        TranscriptOps.apply(
            .abilityRunStarted(Self.run(id: "run-1"), turnID: trimmedTurn),
            to: &state)

        #expect(state.conversation.utterances.count == 1)
        #expect(state.conversation.utterances[0].actions.isEmpty,
                "the run must not have landed on the streaming stranger's bubble")
    }

    /// Same claim for a result — the paired write on the same wire event.
    @Test func aRunResultNeverLandsOnAStrangersBubble() {
        let trimmedTurn = UUID()
        let strangersTurn = UUID()
        var state = Self.state([Self.bubble(turnID: strangersTurn, isStreaming: true)])
        state.activeTurnID = strangersTurn

        TranscriptOps.apply(
            .abilityRunResult(record: Self.run(id: "run-1"), turnID: trimmedTurn),
            to: &state)

        #expect(state.conversation.utterances[0].actions.isEmpty)
    }

    /// And the proactive channel, which already refused to fall back — this
    /// pins it stays that way once routed through the shared resolver.
    @Test func aProactiveBadgeNeverLandsOnAStrangersBubble() {
        let trimmedTurn = UUID()
        let strangersTurn = UUID()
        var state = Self.state([Self.bubble(turnID: strangersTurn, isStreaming: true)])
        state.activeTurnID = strangersTurn

        TranscriptOps.apply(
            .proactiveAbilityBadge(
                reference: BehaviorFixtures.typeAtCursorSkill, turnID: trimmedTurn),
            to: &state)

        #expect(state.conversation.utterances[0].abilityBadges.isEmpty)
    }

    // MARK: - Consistent resolution

    /// A badge and its own run rows, named by the SAME turnID, must resolve
    /// to the SAME bubble — the property the shared resolver exists for.
    @Test func chipAndItsRunsResolveToTheSameBubble() {
        let turnA = UUID()
        let turnB = UUID()
        var state = Self.state([
            Self.bubble(turnID: turnA),
            Self.bubble(turnID: turnB, isStreaming: true),
        ])
        state.activeTurnID = turnB

        TranscriptOps.apply(
            .abilityBadge(BehaviorFixtures.typeAtCursorSkill, turnID: turnA), to: &state)
        TranscriptOps.apply(
            .abilityRunStarted(Self.run(id: "run-1"), turnID: turnA), to: &state)

        #expect(state.conversation.utterances[0].abilityBadges == [BehaviorFixtures.typeAtCursorSkill])
        #expect(state.conversation.utterances[0].actions.map(\.id) == ["run-1"])
        #expect(state.conversation.utterances[1].abilityBadges.isEmpty)
        #expect(state.conversation.utterances[1].actions.isEmpty)
    }

    /// A nil turnID (the live-stream shorthand probes use) still resolves to
    /// whichever bubble is actively streaming — unchanged legacy behaviour.
    @Test func aNilTurnIDResolvesToTheStreamingBubble() {
        var state = Self.state([Self.bubble(turnID: nil, isStreaming: true)])

        TranscriptOps.apply(
            .abilityRunStarted(Self.run(id: "run-1"), turnID: nil), to: &state)

        #expect(state.conversation.utterances[0].actions.map(\.id) == ["run-1"])
    }

    // MARK: - A result with no ask still lands

    /// A lane veto refuses before any invocation is announced — the FIRST
    /// event for that call is the result, not a started row. It must still
    /// land, by appending rather than requiring a prior match.
    @Test func aResultWithNoAskStillLands() {
        let turn = UUID()
        var state = Self.state([Self.bubble(turnID: turn, isStreaming: true)])
        state.activeTurnID = turn

        TranscriptOps.apply(
            .abilityRunResult(record: Self.run(id: "run-1"), turnID: turn), to: &state)

        #expect(state.conversation.utterances[0].actions.map(\.id) == ["run-1"])
    }

    /// A result naming an id already started REPLACES that row by id, never
    /// by position, and never duplicates it.
    @Test func aRunResultReplacesItsStartedRowByIdNotPosition() {
        let turn = UUID()
        var state = Self.state([Self.bubble(turnID: turn, isStreaming: true)])
        state.activeTurnID = turn

        TranscriptOps.apply(
            .abilityRunStarted(Self.run(id: "run-1"), turnID: turn), to: &state)
        var settled = Self.run(id: "run-1")
        settled.disposition = .succeeded
        settled.summary = "Done."
        TranscriptOps.apply(.abilityRunResult(record: settled, turnID: turn), to: &state)

        #expect(state.conversation.utterances[0].actions.count == 1)
        #expect(state.conversation.utterances[0].actions[0].summary == "Done.")
    }

    // MARK: - Supersede clears both

    /// `.turnSuperseded` must clear the run rows alongside the badges — they
    /// belong to the reply being replaced, and leaving them keeps a husk
    /// alive with no chip able to open them.
    @Test func supersedeClearsRunsWithTheChips() {
        let turn = UUID()
        var state = Self.state([Self.bubble(turnID: turn, isStreaming: true)])
        state.activeTurnID = turn
        TranscriptOps.apply(
            .abilityBadge(BehaviorFixtures.typeAtCursorSkill, turnID: turn), to: &state)
        TranscriptOps.apply(
            .abilityRunStarted(Self.run(id: "run-1"), turnID: turn), to: &state)
        #expect(!state.conversation.utterances[0].abilityBadges.isEmpty)
        #expect(!state.conversation.utterances[0].actions.isEmpty)

        TranscriptOps.apply(.turnSuperseded, to: &state)

        #expect(state.conversation.utterances[0].abilityBadges.isEmpty)
        #expect(state.conversation.utterances[0].actions.isEmpty)
    }

    /// A bubble whose only content is run rows (no text, no badges) is still
    /// a husk once superseded clears them — `shouldDropHusk`'s own contract,
    /// now honoured for `actions` the way it already was for everything else.
    @Test func aBubbleWithOnlyRunsIsAHuskAfterSupersede() {
        let turn = UUID()
        var state = Self.state([Self.bubble(turnID: turn, isStreaming: true)])
        state.activeTurnID = turn
        TranscriptOps.apply(
            .abilityRunStarted(Self.run(id: "run-1"), turnID: turn), to: &state)
        TranscriptOps.apply(.turnSuperseded, to: &state)

        TranscriptOps.apply(.assistantDone("", turnID: turn), to: &state)

        #expect(state.conversation.utterances.isEmpty,
                "no text, no badges, no actions, no live routine — a droppable husk")
    }

    // MARK: - Own reads (the "looked first" capsule)

    /// Anchored the same way as its chip/run siblings, and cleared the same
    /// way `.turnSuperseded` clears them — a stranded capsule would credit
    /// the wrong reply with a read that belonged to the one it replaced.
    @Test func ownReadsLandOnTheirOwnTurnAndAreClearedBySupersede() {
        let turn = UUID()
        var state = Self.state([Self.bubble(turnID: turn, isStreaming: true)])
        state.activeTurnID = turn

        TranscriptOps.apply(.ownReads([Self.run(id: "run-1")], turnID: turn), to: &state)
        #expect(state.conversation.utterances[0].ownReads.map(\.id) == ["run-1"])

        TranscriptOps.apply(.turnSuperseded, to: &state)
        #expect(state.conversation.utterances[0].ownReads.isEmpty)
    }

    /// A bubble whose only content is own-reads (no text, no badges, no
    /// model-called actions) is NOT a husk — `shouldDropHusk`'s contract,
    /// extended to the capsule the same way it already covers `actions`.
    @Test func aBubbleWithOnlyOwnReadsIsNotAHusk() {
        let turn = UUID()
        var state = Self.state([Self.bubble(turnID: turn, isStreaming: true)])
        state.activeTurnID = turn
        TranscriptOps.apply(.ownReads([Self.run(id: "run-1")], turnID: turn), to: &state)

        TranscriptOps.apply(.assistantDone("", turnID: turn), to: &state)

        #expect(state.conversation.utterances.count == 1,
                "the capsule alone earns the bubble its place, same as a chip or a run row would")
        #expect(state.conversation.utterances[0].ownReads.map(\.id) == ["run-1"])
    }
}
