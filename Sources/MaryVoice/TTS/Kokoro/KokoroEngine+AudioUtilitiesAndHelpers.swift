//
//  KokoroEngine+AudioUtilitiesAndHelpers.swift
//  MaryVoice
//
//  WHAT: Resample, PCM buffer, find/compile model URLs.
//  IN:   KokoroEngine.swift (same actor)
//  OUT:  hardware-rate buffers / compiled .mlmodelc
//

import Foundation
import AVFoundation
@preconcurrency import CoreML
import Accelerate

extension KokoroEngine {

    // MARK: - Audio utilities

    /// Returns the current hardware output sample rate (the output node's actual rate).
    static func hardwareSampleRate() -> Double {
        // Probe via a temporary engine to read the output node format
        let probe = AVAudioEngine()
        return probe.outputNode.outputFormat(forBus: 0).sampleRate
    }

    /// Resample `samples` from `fromRate` to `toRate` using AVAudioConverter.
    static func resample(_ samples: [Float], from fromRate: Double, to toRate: Double) throws -> [Float] {
        guard fromRate != toRate else { return samples }

        let srcFormat = AVAudioFormat(standardFormatWithSampleRate: fromRate, channels: 1)!
        let dstFormat = AVAudioFormat(standardFormatWithSampleRate: toRate,   channels: 1)!

        // Build source buffer
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let srcCh  = srcBuf.floatChannelData?[0] else {
            throw TTSError.audioConversionFailed
        }
        srcBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { srcCh.update(from: $0.baseAddress!, count: samples.count) }

        // Allocate destination buffer
        let dstFrames = AVAudioFrameCount(Double(samples.count) * toRate / fromRate) + 1
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstFrames),
              let dstCh  = dstBuf.floatChannelData?[0] else {
            throw TTSError.audioConversionFailed
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw TTSError.audioConversionFailed
        }

        var srcConsumed = false
        var convError: NSError?
        converter.convert(to: dstBuf, error: &convError) { _, outStatus in
            if srcConsumed { outStatus.pointee = .noDataNow; return nil }
            outStatus.pointee = .haveData
            srcConsumed = true
            return srcBuf
        }
        if let convError { throw convError }

        let count = Int(dstBuf.frameLength)
        return Array(UnsafeBufferPointer(start: dstCh, count: count))
    }

    func pcmBuffer(from waveform: [Float], sampleRate rate: Double) throws -> AVAudioPCMBuffer {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(waveform.count)),
              let ch  = buf.floatChannelData?[0] else {
            throw TTSError.audioConversionFailed
        }
        buf.frameLength = AVAudioFrameCount(waveform.count)
        waveform.withUnsafeBufferPointer { ch.update(from: $0.baseAddress!, count: waveform.count) }
        return buf
    }

    // MARK: - Helpers

    func findModelURL(_ name: String, in dir: URL) -> URL? {
        for ext in ["mlmodelc", "mlpackage"] {
            let url = dir.appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    func compileIfNeeded(_ url: URL) async throws -> URL {
        if url.pathExtension == "mlmodelc" { return url }
        print("⚙️ Compiling \(url.lastPathComponent)...")
        let compiled = try await MLModel.compileModel(at: url)
        let cache    = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let dest = cache.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".mlmodelc")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: compiled, to: dest)
        print("✅ Compiled → \(dest.lastPathComponent)")
        return dest
    }

}
