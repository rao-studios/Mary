//
//  AnalyzerFeed.swift
//  MaryVoice
//
//  WHAT: Mic frames → the one format SpeechAnalyzer accepts.
//  IN:   ContinuousSpeechTranscriber.appendContinuous
//  OUT:  AnalyzerInput buffers (or drop)
//  PIN:  Mic Float32 into the analyzer is a SIGTRAP — convert or drop.
//

import AVFoundation
import os

final class AnalyzerFeed {

    private static let log =
        Logger(subsystem: "nyc.rao.mary", category: "voice.continuous")

    /// Format `SpeechAnalyzer.bestAvailableAudioFormat` named.
    let target: AVAudioFormat

    /// Stateful resampler — reused across buffers; rebuilt when input format changes.
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(target: AVAudioFormat) {
        self.target = target
    }

    /// Buffer in `target`'s format, or nil to drop this frame.
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

        // Rate conversion changes frame count; slack absorbs resampler delay.
        // One convert call takes ~4096 input frames — do not batch before here.
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        else { return nil }

        // Input block is @Sendable but called synchronously before convert returns.
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
