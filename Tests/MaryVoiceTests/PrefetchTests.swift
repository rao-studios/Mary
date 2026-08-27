//
//  PrefetchTests.swift
//  MaryVoiceTests
//
//  STAGE A'S LOOKAHEAD, pinned at the seams that matter: chunks may
//  synthesize concurrently, but they YIELD strictly in feed order (the
//  reorder buffer); a chunk that fails past every engine fallback emits
//  `.chunkFailed` instead of vanishing; and `beginUtterance` fires exactly
//  once per pipeline run, which is the emotion-pinning boundary.
//
//  Order is observed through `.pronunciation` events — they are emitted at
//  YIELD time inside the drain, so their order IS the yield order, with no
//  audio hardware in the loop.
//

import Foundation
import Testing
@testable import MaryVoice

@Suite struct PrefetchTests {

    /// Per-text scripted delays and failures; reports each chunk's text back
    /// through its pronunciation report so tests can read yield order.
    private actor ScriptedSynth: SpeechSynthesizer {
        var sampleRate: Double = 24_000
        private let delaysMs: [String: UInt64]
        private let failing: Set<String>
        private(set) var utterancesBegun = 0

        init(delaysMs: [String: UInt64] = [:], failing: Set<String> = []) {
            self.delaysMs = delaysMs
            self.failing = failing
        }

        func beginUtterance() {
            utterancesBegun += 1
        }

        func synthesizeWaveform(_ text: String) async throws -> [Float] {
            try await synthesizeChunk(text).samples
        }

        func synthesizeChunk(_ text: String) async throws -> SynthesizedChunk {
            if let delay = delaysMs.first(where: { text.contains($0.key) })?.value {
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
            }
            if failing.contains(where: { text.contains($0) }) {
                throw SeerTTSError.emptyAudio
            }
            return SynthesizedChunk(
                samples: [Float](repeating: 0.1, count: 2_400),
                sampleRate: sampleRate,
                pronunciation: PronunciationReport(
                    text: text, normalizedText: text,
                    words: [], unmappedScalars: [], totalTokens: 1))
        }
    }

    private func run(
        _ synth: ScriptedSynth,
        sentences: [String]
    ) async -> (yielded: [String], failed: [String]) {
        let speaker = KokoroStreamSpeaker(
            engine: KokoroEngine(), sentencesPerChunk: 1)
        await speaker.setSynthesizer(synth)
        let events = await speaker.events()
        let collector = Task { () -> ([String], [String]) in
            var yielded: [String] = []
            var failed: [String] = []
            for await event in events {
                if case .pronunciation(let report) = event { yielded.append(report.text) }
                if case .chunkFailed(let text, _) = event { failed.append(text) }
            }
            return (yielded, failed)
        }
        var accumulated = ""
        for sentence in sentences {
            accumulated += sentence + " "
            await speaker.feed(accumulated)
        }
        await speaker.flush()
        try? await Task.sleep(nanoseconds: 600_000_000)
        collector.cancel()
        let result = await collector.value
        await speaker.hardStop()
        return result
    }

    @Test func prefetchPreservesChunkOrderUnderVariableLatency() async {
        // The FIRST chunk is slow, the later ones fast — under naive
        // concurrency a later chunk would land first; the reorder buffer must
        // hold it. Chunk BOUNDARIES are the speaker's own business (the
        // takeover hold merges the tail), so the pin is marker ORDER across
        // however many chunks it made.
        let synth = ScriptedSynth(delaysMs: ["Alpha": 250])
        let (yielded, failed) = await run(
            synth,
            sentences: ["Alpha is one.", "Bravo is two.", "Charlie is three."])
        #expect(failed.isEmpty)
        #expect(yielded.count >= 2, "the slow first chunk and at least one more")
        let joined = yielded.joined(separator: " | ")
        let alpha = try? #require(joined.range(of: "Alpha"))
        let bravo = try? #require(joined.range(of: "Bravo"))
        let charlie = try? #require(joined.range(of: "Charlie"))
        if let alpha, let bravo, let charlie {
            #expect(alpha.lowerBound < bravo.lowerBound)
            #expect(bravo.lowerBound < charlie.lowerBound)
        }
    }

    @Test func aFailingChunkEmitsChunkFailedAndTheRestPlay() async {
        // The FIRST chunk (its own batch) fails past every fallback; the rest
        // of the reply still speaks, and the skipped sentence is announced.
        let synth = ScriptedSynth(failing: ["Alpha"])
        let (yielded, failed) = await run(
            synth,
            sentences: ["Alpha is one.", "Bravo is two.", "Charlie is three."])
        #expect(failed.count == 1)
        #expect(failed.first?.contains("Alpha") == true)
        let joined = yielded.joined(separator: " | ")
        #expect(joined.contains("Bravo"))
        #expect(joined.contains("Charlie"), "the reply continues past a skipped sentence")
        #expect(!joined.contains("Alpha"))
    }

    @Test func beginUtteranceFiresOncePerPipelineRun() async {
        let synth = ScriptedSynth()
        _ = await run(synth, sentences: ["Alpha is one.", "Bravo is two."])
        #expect(await synth.utterancesBegun == 1,
                "one pipeline, one utterance, one emotion classification")
    }
}

