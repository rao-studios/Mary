//
//  VoicePipeline+StopListening.swift
//  MaryVoice
//
//  WHAT: Wake remainder → first turn; deterministic "stop listening" exit.
//  IN:   WakeWordListener remainder / runTurn / continuous admit
//  OUT:  .stopListeningCommand | submitTurn | canned playback
//

import Foundation

extension VoicePipeline {

    // MARK: - Wake-word session control

    /// Submit a query as if just transcribed (wake remainder → first turn).
    /// Emits `.finalTranscript`. Refused unless quietly listening.
    @discardableResult
    public func primeTurn(query: String) async -> Bool {
        guard state == .listening(utteranceActive: false) else { return false }
        // Wake remainder "stop listening" must end the session before emit.
        if await interceptStopListening(query) { return true }
        emit(.finalTranscript(query))
        await submitTurn(query: query, superseding: false)
        return true
    }

    /// Speak one short canned line through proactive-floor machinery.
    /// Dropped (not held) when the room is not quiet. Not the ambient door.
    @discardableResult
    public func speakCannedLine(_ line: String) async -> Bool {
        guard !line.isEmpty else { return false }
        guard !proactive.followUpSpeaking, !proactive.followUpCutInProgress, !generationActive,
              state == .listening(utteranceActive: false)
        else { return false }
        return await performCannedPlayback(line)
    }

    // MARK: - "Stop listening" (deterministic session exit)

    /// Every seam that turns finished text into a turn asks here first.
    /// OUT: performStopListening — responder never sees the words.
    func interceptStopListening(_ text: String) async -> Bool {
        guard let ack = config.stopListeningAck, WakePlanner.isStopListening(text) else {
            return false
        }
        await performStopListening(transcript: text, ack: ack)
        return true
    }

    /// Session exit; no model sees the words. PIN: close logical listening first
    /// (ack's wake phrase cannot become an utterance); keep the input graph up
    /// until `flush` reports playback, then stop the mic and emit.
    private func performStopListening(transcript: String, ack: String) async {
        // A second ingress observes the first logical stop and cannot compete.
        guard !stopExitInProgress else { return }
        stopExitInProgress = true
        let exitID = UUID()
        stopExitID = exitID
        micLoopTask?.cancel()
        micLoopTask = nil
        partialTask?.cancel()
        partialTask = nil
        proactiveTask?.cancel()
        proactiveTask = nil
        proactive.forceStop()
        heardDecisionTask?.cancel()
        heardDecisionTask = nil
        continuousTask?.cancel()
        continuousTask = nil
        heardBuffer = ""
        // `continuous.endSession()` is owned by `stop()`, not this path.
        transition(to: .speaking)
        // Room is quiet by construction; the claim cuts nothing audible.
        guard let lease = await voiceFloor.claim(), stopExitID == exitID else { return }
        _ = await speaker.feed(ack, lease: lease)
        // Sewn owns request bounds; this await ends after playback, not enqueue.
        _ = await speaker.flush(lease: lease)
        guard stopExitID == exitID else { return }

        // Only now may the input graph change the system audio route.
        mic?.stop()
        mic = nil
        emit(.stopListeningCommand(transcript: transcript, ack: ack))
    }
}
