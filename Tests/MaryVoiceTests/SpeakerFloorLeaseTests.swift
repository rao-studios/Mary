//
//  SpeakerFloorLeaseTests.swift
//  MaryVoiceTests
//
//  WHAT: Shared TTS actor is the writer-ownership authority.
//  OUT:  SpeakerFloorLease
//  PIN:  Stale ops after a newer claim — the window caller-side cancel cannot close
//

import Foundation
import Testing
@testable import MaryVoice

@Suite struct SpeakerFloorLeaseTests {

    @Test func anOldTextLeaseCannotMutateAfterANewTurnClaimsTheSpeaker() async {
        let speaker = KokoroStreamSpeaker(synthesizer: FloorNullSynthesizer())
        let old = UUID()
        let new = UUID()

        #expect(await speaker.claimTextFloor(old))
        #expect(await speaker.feed("Old reply.", lease: old))

        // The new user boundary is a hard reset AND a new authoritative
        // writer. Every old operation must become inert at the speaker actor,
        // not merely at its caller.
        #expect(await speaker.claimTextFloor(new))
        #expect(!(await speaker.feed("late old token", lease: old)))
        #expect(!(await speaker.softStop(lease: old)))
        #expect(!(await speaker.hardStop(lease: old)))
        #expect(!(await speaker.enqueueRemotePCM(
            Data([0, 0, 0, 0]), sampleRate: 24_000, lease: old)))
        #expect(!(await speaker.endRemoteAudio(lease: old)))
        #expect(!(await speaker.flush(lease: old)))

        #expect(await speaker.feed("New reply.", lease: new))
        #expect(await speaker.ownsFloor(new))
        #expect(!(await speaker.ownsFloor(old)))
    }

    @Test func anAcceptedHardStopKeepsItsWritersLeaseForTheReplacement() async {
        let speaker = KokoroStreamSpeaker(synthesizer: FloorNullSynthesizer())
        let turn = UUID()

        #expect(await speaker.claimTextFloor(turn))
        #expect(await speaker.feed("Discard this acknowledgement.", lease: turn))
        #expect(await speaker.hardStop(lease: turn))
        #expect(await speaker.ownsFloor(turn))
        #expect(await speaker.feed("Speak this replacement.", lease: turn))
        #expect(await speaker.flush(lease: turn))
    }

    @Test func aReservedVoiceSessionRejectsHeldTextFollowUps() async {
        let speaker = KokoroStreamSpeaker(synthesizer: FloorNullSynthesizer())
        let voice = UUID()
        let text = UUID()

        #expect(await speaker.claimVoiceFloor(voice))
        #expect(!(await speaker.claimTextFloor(text)))
        #expect(!(await speaker.feed("late text follow-up", lease: text)))

        await speaker.leaveVoiceFloor()
        #expect(await speaker.claimTextFloor(text))
    }

    @Test func aDelayedVoiceFollowUpCannotRetakeANewerVoiceTurn() async {
        let speaker = KokoroStreamSpeaker(synthesizer: FloorNullSynthesizer())
        let oldTurn = UUID()
        let newTurn = UUID()
        let lateFollowUp = UUID()

        #expect(await speaker.claimVoiceFloor(oldTurn))
        #expect(await speaker.claimVoiceFloor(newTurn))

        // This is the stale detached-task race: it remembers the floor it
        // observed before a new utterance began. The speaker, not a caller
        // side cancellation check, refuses that compare-and-swap handoff.
        #expect(!(await speaker.replaceVoiceFloor(lateFollowUp, replacing: oldTurn)))
        #expect(await speaker.ownsFloor(newTurn))
        #expect(!(await speaker.ownsFloor(lateFollowUp)))
    }

    @Test func aFailedOldStartCannotReleaseANewerVoiceSession() async {
        let speaker = KokoroStreamSpeaker(synthesizer: FloorNullSynthesizer())
        let failedStart = UUID()
        let replacement = UUID()

        #expect(await speaker.claimVoiceFloor(failedStart))
        #expect(await speaker.claimVoiceFloor(replacement))
        #expect(!(await speaker.leaveVoiceFloor(lease: failedStart)))
        #expect(await speaker.ownsFloor(replacement))
    }

    @Test func aDelayedVoiceFollowUpCannotUseTheBargeInIdleGap() async {
        let speaker = KokoroStreamSpeaker(synthesizer: FloorNullSynthesizer())
        let interruptedTurn = UUID()
        let lateFollowUp = UUID()

        #expect(await speaker.claimVoiceFloor(interruptedTurn))
        // A committed barge-in clears the active writer while preserving the
        // voice-session reservation for the incoming utterance.
        await speaker.hardStop()
        #expect(!(await speaker.replaceVoiceFloor(lateFollowUp, replacing: interruptedTurn)))
        #expect(!(await speaker.ownsFloor(lateFollowUp)))
    }

    @Test func aQuietHandoffClearsThePreviousWritersDraftBeforeNewTextFeeds() async {
        let speaker = KokoroStreamSpeaker(synthesizer: FloorNullSynthesizer())
        let oldTurn = UUID()
        let followUp = UUID()
        let events = await speaker.events()
        let collector = Task {
            var chunks: [String] = []
            for await event in events {
                if case .chunkQueued(let text) = event { chunks.append(text) }
            }
            return chunks
        }

        #expect(await speaker.claimTextFloor(oldTurn))
        #expect(await speaker.feed("Old draft must never cross the handoff.", lease: oldTurn))
        #expect(await speaker.replaceTextFloor(followUp, replacing: oldTurn))
        // No audio is live, so this is a silent reset. It also cancels a
        // potential not-yet-audible synthesis tail before the new writer
        // establishes its diff baseline.
        #expect(await speaker.softStop(lease: followUp, handoff: true))
        #expect(await speaker.feed("Fresh detached answer.", lease: followUp))
        #expect(await speaker.flush(lease: followUp))

        collector.cancel()
        let spoken = await collector.value.joined(separator: " ")
        #expect(spoken.contains("Fresh detached answer."))
        #expect(!spoken.contains("Old draft"))
    }
}

private actor FloorNullSynthesizer: SpeechSynthesizer {
    var sampleRate: Double { 24_000 }
    var lastPronunciationReport: PronunciationReport? { nil }
    func synthesizeWaveform(_ text: String) async throws -> [Float] { [] }
}
