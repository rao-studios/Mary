//
//  VoicePipeline+ContinuousHearing.swift
//  MaryVoice
//
//  WHAT: Session-long transcript beside the acoustic path.
//  IN:   Mic frames / TranscriptSegment → IntakePlanner
//  OUT:  .heardSpeech (ambient) | .finalTranscript (Brain turn)
//

import AVFoundation
import Foundation

extension VoicePipeline {

    // MARK: - Continuous hearing

    func startContinuousHearing(format: AVAudioFormat) async {
        guard !terminated, let continuous else { return }
        do {
            try await continuous.beginSession(format: format)
        } catch {
            guard !terminated else { return }
            // Degraded, not dead. Acoustic path is untouched. OUT: .continuousUnavailable.
            emit(.continuousUnavailable(error.localizedDescription))
            return
        }
        guard !terminated else {
            // Teardown raced a slow begin. Second cleanup after the late begin.
            Task.detached(priority: .utility) {
                await continuous.endSession()
            }
            return
        }
        let stream = await continuous.segments()
        guard !terminated else {
            Task.detached(priority: .utility) {
                await continuous.endSession()
            }
            return
        }
        continuousTask = Task { [weak self] in
            for await segment in stream {
                await self?.handleSegment(segment)
            }
        }
    }

    private func handleSegment(_ segment: TranscriptSegment) async {
        guard !stopExitInProgress, state != .idle else { return }
        guard !speakerAudioLive else { return }
        // Volatile spans may still be rewritten — skip them.
        guard segment.isFinalized else { return }
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        heardBuffer += heardBuffer.isEmpty ? text : " " + text

        heardDecisionTask?.cancel()
        let quiet = intakeTuning.completionSilence
        heardDecisionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(quiet * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.decideHeard()
        }
    }

    private func decideHeard() async {
        guard !stopExitInProgress, state != .idle else { return }
        let text = heardBuffer
        heardBuffer = ""
        guard !text.isEmpty else { return }
        let verdict = IntakePlanner.verdict(
            IntakePlanner.Situation(
                segment: IntakePlanner.Segment(
                    text: text,
                    isFinalized: true,
                    // The decision only runs after the debounce elapsed.
                    silenceAfter: intakeTuning.completionSilence),
                selfSpeaking: speakerAudioLive,
                // Acoustic path gets first refusal — do not submit the same speech twice.
                acousticPathBusy: state != .listening(utteranceActive: false)),
            tuning: intakeTuning)

        switch verdict {
        case .admit(let query):
            if await interceptStopListening(query) { return }
            emit(.finalTranscript(query))
            await submitTurn(query: query, superseding: false)
        case .remember(let line):
            emit(.heardSpeech(line))
        case .hold:
            break
        }
    }
}
