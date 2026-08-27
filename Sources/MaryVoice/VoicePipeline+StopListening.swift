//
//  VoicePipeline+StopListening.swift
//  MaryVoice
//

import Foundation

extension VoicePipeline {

    // MARK: - Wake-word session control

    /// Submit a query as if it had just been transcribed — the wake
    /// listener's "Hey Mary, <request>" remainder becomes the session's
    /// first turn. Emits `.finalTranscript` so the app mirrors the user
    /// bubble exactly as for a spoken turn. Refused unless the pipeline is
    /// quietly listening: if the user is already speaking again, their live
    /// utterance outranks the primed one.
    @discardableResult
    public func primeTurn(query: String) async -> Bool {
        guard state == .listening(utteranceActive: false) else { return false }
        // "Hey Mary, stop listening" primes like any other remainder — and
        // must end the session like any other spoken stop command, checked
        // BEFORE the emit (the stop event's own arm mirrors the exchange).
        if await interceptStopListening(query) { return true }
        emit(.finalTranscript(query))
        await submitTurn(query: query, superseding: false)
        return true
    }

    /// Speak one short deterministic line (the wake greeting) through the
    /// session's own proactive-floor machinery — barge-inable, and DROPPED
    /// rather than held when the room is not quiet.
    ///
    /// DELIBERATELY NOT the responder's ambient door: `emitAmbientUtterance`
    /// books delivery verdicts into the ambient engine's governance loop (a
    /// barge-in over it stretches the engine's refractory), and it rides the
    /// follow-up chain — far too slow, and far too entangled, for "Yes?".
    @discardableResult
    public func speakCannedLine(_ line: String) async -> Bool {
        guard !line.isEmpty else { return false }
        guard !proactive.followUpSpeaking, !proactive.followUpCutInProgress, !generationActive,
              state == .listening(utteranceActive: false)
        else { return false }
        return await performCannedPlayback(line)
    }

    // MARK: - "Stop listening" (deterministic session exit)

    /// Every seam that turns finished text into a turn asks here first: the
    /// stop command must never reach the responder, whichever door the words
    /// came through (acoustic runTurn, a primed wake remainder, or a
    /// continuous-hearing admit).
    func interceptStopListening(_ text: String) async -> Bool {
        guard let ack = config.stopListeningAck, WakePlanner.isStopListening(text) else {
            return false
        }
        await performStopListening(transcript: text, ack: ack)
        return true
    }

    /// The user asked the SESSION to end, so no model sees the words.
    /// Ordering is load-bearing. Logical listening closes FIRST — no frame can
    /// reach VAD or either transcriber, so the acknowledgement's own wake phrase
    /// cannot become a new utterance. The physical input graph deliberately
    /// stays up while the acknowledgement plays: tearing it down immediately
    /// before opening output causes Bluetooth/CoreAudio to reconfigure the
    /// route in the middle of the line. Seer is allowed its own bounded request
    /// policy and Kokoro remains its fallback. `speaker.flush` then waits for
    /// scheduled buffers' `.dataPlayedBack` callbacks, not merely their
    /// enqueue, before the mic is physically stopped and the app is told to
    /// finish the session.
    private func performStopListening(transcript: String, ack: String) async {
        // A second ingress (for example, a final continuous segment already
        // dispatched before cancellation) observes the first logical stop and
        // cannot start a competing acknowledgement.
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
        // `continuous.endSession()` is deliberately NOT awaited here —
        // `stop()` (which the app runs on the event below) owns that cleanup,
        // and a slow analyzer must not stand between the user and the stop.
        transition(to: .speaking)
        // The room is quiet by construction (the command's own utterance just
        // endpointed), so the hard claim cuts nothing audible.
        guard let lease = await voiceFloor.claim(), stopExitID == exitID else { return }
        _ = await speaker.feed(ack, lease: lease)
        // No independent six-second guillotine: Seer owns its request bounds,
        // and once any PCM is scheduled this await ends only after the player
        // reports that every buffer was actually played back.
        _ = await speaker.flush(lease: lease)
        guard stopExitID == exitID else { return }

        // Only now may the input graph change the system audio route.
        mic?.stop()
        mic = nil
        emit(.stopListeningCommand(transcript: transcript, ack: ack))
    }
}
