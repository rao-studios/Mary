//
//  TakeoverTests.swift
//  MaryVoiceTests
//
//  WHAT: Stale Lane-A speech never reaches synthesis — retract replaces, not appends.
//  OUT:  VoicePipeline .retractSpeech via .chunkQueued
//

import Foundation
import Testing
@testable import MaryVoice

@Suite struct TakeoverTests {

    private func makeSpeaker() -> KokoroStreamSpeaker {
        KokoroStreamSpeaker(synthesizer: TakeoverNullSynthesizer())
    }

    /// Everything the speaker handed to synthesis, plus whether playback was
    /// ever started — the two questions a silent turn must answer "no" to.
    private final class Tap: @unchecked Sendable {
        private let lock = NSLock()
        private var chunksBox: [String] = []
        private var startedBox = false
        var chunks: [String] { lock.lock(); defer { lock.unlock() }; return chunksBox }
        var started: Bool { lock.lock(); defer { lock.unlock() }; return startedBox }
        func note(_ event: SpeakerEvent) {
            lock.lock()
            if case .chunkQueued(let text) = event { chunksBox.append(text) }
            if case .started = event { startedBox = true }
            lock.unlock()
        }
    }

    private func tap(_ speaker: KokoroStreamSpeaker) async -> (Tap, Task<Void, Never>) {
        let events = await speaker.events()
        let tap = Tap()
        let watcher = Task {
            for await event in events {
                if Task.isCancelled { break }
                tap.note(event)
            }
        }
        return (tap, watcher)
    }

    /// WAIT FOR A TIMER, DO NOT ASSUME ONE. The self-releasing hold is the only
    /// claim here that rests on a `Task.sleep` firing, and this suite runs
    /// beside CPU-bound siblings on the same cooperative pool: measured under
    /// the full parallel run, a bare 50 ms `Task.sleep` in the test's own task
    /// took **447 ms** to resume. A fixed sleep of "eight times the window"
    /// therefore failed four runs in five while the mechanism was working
    /// perfectly — the hold released, just after the assertion had already
    /// read an empty tap. Polling to a ceiling keeps the real claim intact (a
    /// hold that NEVER releases still fails, loudly) and drops only the
    /// assumption that the scheduler is idle.
    private func awaitChunk(_ tap: Tap, within nanoseconds: UInt64 = 5_000_000_000) async {
        let deadline = DispatchTime.now() + .nanoseconds(Int(nanoseconds))
        while tap.chunks.isEmpty, DispatchTime.now() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - 1. Replace, never append

    /// The core claim. A short acknowledgement is below the chunker's
    /// threshold, so it is still un-synthesized text when the lane joins — the
    /// takeover window. After `.retractSpeech`, the replacement is the WHOLE
    /// spoken reply and the acknowledgement never reaches a synthesizer.
    @Test func aStaleAcknowledgementIsReplacedNotAppended() async {
        let speaker = makeSpeaker()
        let (tap, watcher) = await tap(speaker)

        var router = SpeechRouter(speaker: speaker)
        var accumulated = "On it. Putting that on now."
        await router.consumeToken(accumulated: accumulated)
        // The lane joined holding a finished outcome.
        await router.consumeRetractSpeech(accumulated: accumulated)
        accumulated += "I tightened the Background section."
        await router.consumeToken(accumulated: accumulated)
        await router.finish()

        watcher.cancel()
        let spoken = tap.chunks.joined(separator: " ")
        #expect(spoken.contains("I tightened the Background section."))
        #expect(!spoken.contains("On it"), "the retracted promise reached synthesis: \(tap.chunks)")
        #expect(!spoken.contains("Putting that on now"))
    }

    /// THE `didFeedSpeaker` TRAP. `SpeechRouter.finish()` flushes only when
    /// text reached the speaker; a takeover that left the flag false would
    /// substitute SILENCE for a correction — the failure mode swapped for a
    /// quieter one. The replacement's own token puts the flag back up.
    @Test func theReplacementStillFlushes() async {
        let speaker = makeSpeaker()
        let (tap, watcher) = await tap(speaker)

        var router = SpeechRouter(speaker: speaker)
        var accumulated = "On it."
        await router.consumeToken(accumulated: accumulated)
        await router.consumeRetractSpeech(accumulated: accumulated)
        #expect(!router.didFeedSpeaker, "the retraction rewinds the flush guard")
        accumulated += "That's done — the playlist is playing."
        await router.consumeToken(accumulated: accumulated)
        #expect(router.didFeedSpeaker, "the replacement re-arms it, or nothing ever flushes")
        await router.finish()

        watcher.cancel()
        #expect(tap.chunks.joined().contains("the playlist is playing"))
    }

    // MARK: - 2. A completed fast action stays silent

    /// The user's decision, verbatim: "a completed fast action stays SILENT —
    /// the chips are the reply." A retraction with nothing behind it takes the
    /// road a zero-token action turn always did: no flush, no audio, and no
    /// spurious `.started` flashing a phantom "speaking" state.
    @Test func aRetractionWithNoReplacementSpeaksNothing() async {
        let speaker = makeSpeaker()
        let (tap, watcher) = await tap(speaker)

        var router = SpeechRouter(speaker: speaker)
        let accumulated = "On it. Putting that on now."
        await router.consumeToken(accumulated: accumulated)
        await router.consumeRetractSpeech(accumulated: accumulated)
        await router.finish()

        watcher.cancel()
        #expect(tap.chunks.isEmpty, "nothing may reach synthesis: \(tap.chunks)")
        #expect(!tap.started, "an empty flush emitted the phantom .started again")
    }

    // MARK: - 3. The hold — policy, not coincidence

    /// Without the hold this is the accident the whole window rested on: three
    /// complete sentences arrive, the chunker hands a batch to synthesis, and
    /// the takeover is already too late. Held, the batch waits for the lane.
    @Test func theHoldKeepsAnAudibleBatchFromEscapingEarly() async {
        let speaker = makeSpeaker()
        let (tap, watcher) = await tap(speaker)

        var router = SpeechRouter(speaker: speaker, holdWindowNanoseconds: 5_000_000_000)
        await router.consumeToken(
            accumulated: "One is here. Two is here. Three begins")
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(tap.chunks.isEmpty, "the hold let a batch escape: \(tap.chunks)")

        watcher.cancel()
        await speaker.hardStop()
    }

    /// …and what the hold stages, a retraction DESTROYS. This is what turns
    /// "the stale text never reaches synthesis" from a hope about chunk sizing
    /// into a guarantee — and what will keep it true when first-audio latency
    /// is lowered later.
    @Test func aRetractionDiscardsWhatTheHoldStaged() async {
        let speaker = makeSpeaker()
        let (tap, watcher) = await tap(speaker)

        var router = SpeechRouter(speaker: speaker, holdWindowNanoseconds: 5_000_000_000)
        var accumulated = "One is here. Two is here. Three begins"
        await router.consumeToken(accumulated: accumulated)
        await router.consumeRetractSpeech(accumulated: accumulated)
        accumulated += "The playlist is playing."
        await router.consumeToken(accumulated: accumulated)
        await router.finish()

        watcher.cancel()
        let spoken = tap.chunks.joined(separator: " ")
        #expect(spoken.contains("The playlist is playing."))
        #expect(!spoken.contains("One is here"), "staged text survived a retraction: \(tap.chunks)")
        #expect(!spoken.contains("Two is here"))
    }

    /// A SELF-RELEASING HOLD. A stream that goes quiet inside the window (a
    /// model deliberating mid-reply) must not leave staged audio waiting on a
    /// token that never comes — silence bought by the mechanism that exists to
    /// protect speech.
    @Test func theHoldReleasesItselfWhenTheWindowExpires() async {
        let speaker = makeSpeaker()
        let (tap, watcher) = await tap(speaker)

        var router = SpeechRouter(speaker: speaker, holdWindowNanoseconds: 50_000_000)
        await router.consumeToken(
            accumulated: "One is here. Two is here. Three begins")
        // No further token, no flush — only the window passing.
        await awaitChunk(tap)
        #expect(tap.chunks == ["One is here. Two is here."], "\(tap.chunks)")

        watcher.cancel()
        await speaker.hardStop()
    }

    /// One hold per turn: the REPLACEMENT is never held behind the same window
    /// it bought. The lane it was waiting for has already spoken.
    @Test func theReplacementIsNotHeldAgain() async {
        let speaker = makeSpeaker()
        let (tap, watcher) = await tap(speaker)

        var router = SpeechRouter(speaker: speaker, holdWindowNanoseconds: 5_000_000_000)
        var accumulated = "On it."
        await router.consumeToken(accumulated: accumulated)
        await router.consumeRetractSpeech(accumulated: accumulated)
        accumulated += "First replacement line. Second replacement line. Third begins"
        await router.consumeToken(accumulated: accumulated)
        await awaitChunk(tap)
        #expect(tap.chunks == ["First replacement line. Second replacement line."],
                "the correction was held behind the window it bought: \(tap.chunks)")

        watcher.cancel()
        await speaker.hardStop()
    }

    /// ONE HOLD PER TURN — AND A SILENT TURN IS STILL A TURN. The turn shape
    /// this round INTRODUCED is the one that leaked: a completed fast action
    /// retracts to silence, so `finish()` never flushes, and `flush()` was one
    /// of only two places the per-turn hold flag was cleared. The flag survived
    /// into the next turn on the shared speaker and `holdSynthesis(for:)` turned
    /// that turn's hold away — so the commonest sequence there is, "put on some
    /// jazz" followed by a question, was exactly the sequence with no takeover
    /// window. Found by driving two turns through one speaker; the control (a
    /// turn one that DID flush) held turn two correctly.
    @Test func aSilentTurnDoesNotSwallowTheNextTurnsHold() async {
        let speaker = makeSpeaker()
        let (tap, watcher) = await tap(speaker)

        var first = SpeechRouter(speaker: speaker, holdWindowNanoseconds: 5_000_000_000)
        await first.consumeToken(accumulated: "On it. Putting that on now.")
        await first.consumeRetractSpeech(accumulated: "On it. Putting that on now.")
        await first.finish()
        #expect(tap.chunks.isEmpty, "turn one spoke: \(tap.chunks)")

        // Turn two, same shared speaker: an audible batch that must wait for
        // its OWN lane. Un-held, it reaches synthesis synchronously inside
        // `consumeToken`, so this cannot pass by being early.
        var second = SpeechRouter(speaker: speaker, holdWindowNanoseconds: 5_000_000_000)
        await second.consumeToken(accumulated: "One is here. Two is here. Three begins")
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(tap.chunks.isEmpty, "turn two got no hold at all: \(tap.chunks)")

        watcher.cancel()
        await speaker.hardStop()
    }

    // MARK: - 4. The bound the brain leans on

    /// `mayAlreadyBeAudible` is the brain's only way to ask "could this text
    /// already be playing?", and a second approximation of the chunker's rule
    /// living in another package is exactly how one of them comes to be wrong.
    /// So it is checked against the chunker ITSELF, unheld.
    @Test func mayAlreadyBeAudibleAgreesWithTheChunker() async {
        let samples = [
            "",
            "On it",
            "On it.",
            "On it. Putting that on now.",
            "One is here. Two is here. Three begins",
            "One is here. Two is here. Three is here. Four begins",
        ]
        for text in samples {
            let speaker = makeSpeaker()
            let (tap, watcher) = await tap(speaker)
            await speaker.feed(text)
            // Asymmetric on purpose. When the predicate claims the text could
            // already be playing we WAIT for the chunker to agree, so a
            // starved watcher cannot manufacture a disagreement; when it
            // claims silence, a fixed grace is what proves nothing escaped —
            // the same shape SentenceSpeakerTests uses.
            if KokoroStreamSpeaker.mayAlreadyBeAudible(text) {
                await awaitChunk(tap)
            } else {
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            watcher.cancel()
            await speaker.hardStop()
            #expect(KokoroStreamSpeaker.mayAlreadyBeAudible(text) == !tap.chunks.isEmpty,
                    "disagreed about \"\(text)\" — chunks \(tap.chunks)")
        }
    }

    /// The arithmetic, written down: two complete sentences fill a chunk, and a
    /// third sentence of text is what proves the second one ended.
    @Test func theFirstAudioThresholdIsTwoChunkSentencesPlusOne() {
        #expect(KokoroStreamSpeaker.defaultSentencesPerChunk == 2)
        #expect(KokoroStreamSpeaker.sentencesBeforeFirstAudio
                == KokoroStreamSpeaker.defaultSentencesPerChunk + 1)
    }

    // MARK: - 5. Both cloud voices carry a wall clock

    /// `request.timeoutInterval` is URLSession's IDLE timer and it resets on
    /// every byte; the wall clock lives on the session CONFIGURATION, and
    /// `URLSession.shared`'s is SEVEN DAYS. `ttsBackend` defaults to `.sewn`,
    /// so this is the path EVERY spoken sentence takes — Mary has one cloud
    /// voice, which makes this the only file that can get it wrong and also
    /// the only one that has to get it right.
    @Test func theCloudVoiceStreamsOnTheBoundedSession() throws {
        #expect(SpeechStreamingHTTP.resourceTimeout > 0)
        #expect(SpeechStreamingHTTP.resourceTimeout < SpeechStreamingHTTP.idleTimeout,
                "the wall clock is the binding one; the idle timer never was")
        // One sentence, retry included, stays inside the sixty seconds both
        // engines already believed a chunk was capped at.
        #expect(SpeechStreamingHTTP.resourceTimeout * 2 <= SpeechStreamingHTTP.idleTimeout)
        let file = "TTS/Sewn/SewnTTSEngine.swift"
        let text = try Self.source(file)
        #expect(text.contains("SpeechStreamingHTTP.session"), "\(file)")
        #expect(!text.contains("URLSession.shared.bytes"),
                "\(file) still streams on the seven-day session")
    }

    private static func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaryVoiceTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // MaryVoice
            .appendingPathComponent("Sources/MaryVoice/\(relative)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private actor TakeoverNullSynthesizer: SpeechSynthesizer {
    var sampleRate: Double { 24_000 }
    var lastPronunciationReport: PronunciationReport? { nil }
    func synthesizeWaveform(_ text: String) async throws -> [Float] { [] }
}
