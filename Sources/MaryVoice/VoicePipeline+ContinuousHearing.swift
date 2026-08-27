//
//  VoicePipeline+ContinuousHearing.swift
//  MaryVoice
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
            // DEGRADED, NOT DEAD. The acoustic path is untouched, so a missing
            // model or a denied authorization costs continuous hearing and
            // nothing else — and it says so rather than presenting as a
            // feature that silently does nothing.
            emit(.continuousUnavailable(error.localizedDescription))
            return
        }
        guard !terminated else {
            // Teardown may have raced a slow model download/session begin. Its
            // first detached end could have run before begin completed, so a
            // second private cleanup is required after the late begin lands.
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
        // HER OWN VOICE, REFUSED AT THE DOOR. `speakerAudioLive` is the
        // pipeline's existing "audio is playing" bit; without this she
        // transcribes her own TTS and can answer herself.
        guard !speakerAudioLive else { return }
        // Volatile spans may still be rewritten. They are useful for a live
        // caption and worthless for a decision, so nothing accumulates them.
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
                    // The decision only runs after the debounce elapsed, so
                    // the silence is known to have been at least this long.
                    silenceAfter: intakeTuning.completionSilence),
                selfSpeaking: speakerAudioLive,
                // THE ACOUSTIC PATH GETS FIRST REFUSAL. Anything other than a
                // quiet, armed pipeline means the VAD loop already owns this
                // speech, and admitting here too would submit it twice.
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
