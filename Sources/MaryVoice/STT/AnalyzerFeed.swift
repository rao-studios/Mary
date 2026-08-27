//
//  AnalyzerFeed.swift
//  MaryVoice
//
//  MIC FRAMES → THE ONE FORMAT THE ON-DEVICE RECOGNIZER ACCEPTS.
//
//  This exists because handing `SpeechAnalyzer` the microphone's own format
//  is not a degradation, it is a CRASH. Measured 2026-08-15 across three
//  consecutive launches: the tap runs Float32, `prepareToAnalyze(in:)`
//  accepted it, and the first buffer to reach the recognizer tripped
//
//      Failed precondition: Audio sample data must be 16-bit signed integers
//
//  inside SpeechFramework — a Swift precondition, so the process died on
//  SIGTRAP with no error anyone could catch. It only surfaced once AirPods
//  connected because their 24 kHz rate is one the analyzer accepts outright;
//  the built-in mic's 48 kHz was refused earlier, at `prepareToAnalyze`,
//  where a thrown error still had somewhere to go.
//
//  So the rule this type enforces is absolute: nothing reaches the analyzer
//  that is not already in the format the analyzer asked for. A frame that
//  cannot be converted is DROPPED — it is one buffer of room noise, and the
//  alternative is the trap above.
//

import AVFoundation
import os

final class AnalyzerFeed {

    private static let log =
        Logger(subsystem: "nyc.rao.mary", category: "voice.continuous")

    /// The format `SpeechAnalyzer.bestAvailableAudioFormat` named.
    let target: AVAudioFormat

    /// Stateful — it carries resampler phase across buffers, so it is reused
    /// rather than rebuilt per frame, and rebuilt only when the INPUT format
    /// changes. That change is exactly what a mid-session device swap looks
    /// like from here: the mic rebuilds its tap on the new hardware's rate
    /// and the analyzer, one converter later, never notices.
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(target: AVAudioFormat) {
        self.target = target
    }

    /// The buffer in `target`'s format, or nil to drop this frame.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }

        if converter == nil || inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            inputFormat = buffer.format
            if converter == nil {
                Self.log.error("continuous STT: no converter from the mic format to the analyzer's")
            }
        }
        guard let converter else { return nil }

        // Rate conversion changes the frame count; the slack absorbs the
        // resampler's internal delay on the first buffers.
        //
        // One call converts at most ~4096 input frames (measured): the input
        // block is asked for more data once, answers `.noDataNow`, and
        // anything past that ceiling in a SINGLE buffer would be dropped.
        // The tap asks for 1024-frame buffers, so this is documentation
        // rather than a live limit — but it is the reason a caller must not
        // batch frames before handing them here.
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        else { return nil }

        // The input block is `@Sendable` by declaration but is called
        // synchronously, on this thread, before `convert` returns — the
        // buffer never actually crosses a boundary.
        nonisolated(unsafe) let source = buffer
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return source
        }
        switch status {
        case .haveData, .inputRanDry:
            return output.frameLength > 0 ? output : nil
        case .endOfStream:
            return nil
        case .error:
            Self.log.error(
                "continuous STT: buffer conversion failed: \(error?.localizedDescription ?? "unknown")")
            return nil
        @unknown default:
            return nil
        }
    }
}
