//
//  KokoroEngine+PublicAPI.swift
//  MaryVoice
//
//  WHAT: speak / synthesizeWaveform / synthesize.
//  IN:   KokoroEngine.swift (same actor)
//  OUT:  waveform → playback helpers
//

import Foundation
import AVFoundation
@preconcurrency import CoreML
import Accelerate

extension KokoroEngine {

    // MARK: - Public API

    /// Synthesize and play `text`. Neutral: player→mixer. Other styles: timePitch / EQ / reverb.
    public func speak(_ text: String, style: TTSSpeechStyle = .neutral) async throws {
        let waveform = try await synthesizeWaveform(text)
        if style.isNeutral {
            try await playSimple(waveform)
        } else {
            try await playStyled(waveform, style: style)
        }
    }

    /// Synthesize `text` and return raw float samples (post-DSP, ready for playback).
    public func synthesizeWaveform(_ text: String) async throws -> [Float] {
        try Task.checkCancellation()
        guard !loadedModels.isEmpty else { throw TTSError.modelsNotLoaded }
        guard let voice = currentVoice else { throw TTSError.noVoiceLoaded }

        // 1. Phonemize using the largest available token window so we get the full
        //    untruncated IDs — we need the true count to pick the right model.
        let probeMaxTokens = loadedModels.last!.variant.maxTokens
        let (probeIDs, pronunciationReport) = await phonemizer.phonemize(text, maxTokens: probeMaxTokens)
        // Phonemization and Core ML may bridge work that does not itself throw
        // on cancellation. A stopped speaker must discard that stale result
        // instead of carrying it into inference or a later session's queue.
        try Task.checkCancellation()
        lastPronunciationReport = pronunciationReport
        for continuation in pronunciationContinuations.values {
            continuation.yield(pronunciationReport)
        }
        let probeCount = probeIDs.count  // BOS + phonemes + EOS

        // 2. Select the smallest model whose token window fits the input.
        guard let selected = selectModel(for: probeCount) else { throw TTSError.modelsNotLoaded }
        let variant   = selected.variant
        let model     = selected.model
        let maxTokens = variant.maxTokens

        // Update sampleRate to reflect the chosen model (used by playback helpers below).
        sampleRate = variant.sampleRate

        // 3. Truncate IDs to the selected model's token window if needed, then use
        //    those as the actual count for the voice embedding lookup.
        let ids: [Int32]
        if probeIDs.count > maxTokens {
            // Keep BOS + up to (maxTokens-2) phonemes + EOS
            ids = Array(probeIDs.prefix(maxTokens - 1)) + [0]
        } else {
            ids = probeIDs
        }
        let actualCount = ids.count

        print("🎯 Selected model '\(variant.name)' for \(actualCount) tokens (probe=\(probeCount))")

        // 4. Voice embedding keyed by actual token count (FluidAudio behaviour)
        guard let embedding = voice.embedding(for: actualCount) else {
            throw TTSError.noVoiceLoaded
        }
        let embDim = embedding.count

        // 5. Build MLMultiArray inputs — pad ids to maxTokens
        let inputIDs = try MLMultiArray(shape: [1, NSNumber(value: maxTokens)], dataType: .int32)
        let inputPtr = inputIDs.dataPointer.bindMemory(to: Int32.self, capacity: maxTokens)
        inputPtr.initialize(repeating: 0, count: maxTokens)
        ids.withUnsafeBufferPointer { buf in
            inputPtr.update(from: buf.baseAddress!, count: buf.count)
        }

        // Attention mask: 1 for every real token (0..<actualCount), 0 for padding
        let mask    = try MLMultiArray(shape: [1, NSNumber(value: maxTokens)], dataType: .int32)
        let maskPtr = mask.dataPointer.bindMemory(to: Int32.self, capacity: maxTokens)
        maskPtr.initialize(repeating: 0, count: maxTokens)
        for i in 0..<min(actualCount, maxTokens) { maskPtr[i] = 1 }

        let refS   = try MLMultiArray(shape: [1, NSNumber(value: embDim)], dataType: .float32)
        let refPtr = refS.dataPointer.bindMemory(to: Float.self, capacity: embDim)
        embedding.withUnsafeBufferPointer { buf in
            refPtr.update(from: buf.baseAddress!, count: buf.count)
        }

        // random_phases MUST be zeroed — random values cause garbled output
        let phases    = try MLMultiArray(shape: [1, 9], dataType: .float32)
        let phasesPtr = phases.dataPointer.bindMemory(to: Float.self, capacity: 9)
        phasesPtr.initialize(repeating: 0, count: 9)

        // 6. Run model
        print("🧠 Running inference (actualCount=\(actualCount), embDim=\(embDim))...")
        try Task.checkCancellation()
        let result = try await model.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
            "input_ids":      MLFeatureValue(multiArray: inputIDs),
            "ref_s":          MLFeatureValue(multiArray: refS),
            "random_phases":  MLFeatureValue(multiArray: phases),
            "attention_mask": MLFeatureValue(multiArray: mask),
        ]))
        // Core ML prediction may finish normally after its parent task was
        // cancelled. Never turn that obsolete output into playable PCM.
        try Task.checkCancellation()

        guard let audioArray = result.featureValue(for: "audio")?.multiArrayValue else {
            throw TTSError.predictionFailed("Missing 'audio' output")
        }

        // 7. Extract waveform — trim to audio_length_samples if provided
        var effectiveCount = audioArray.count
        if let lenArray = result.featureValue(for: "audio_length_samples")?.multiArrayValue,
           lenArray.count > 0 {
            let n = lenArray[0].intValue
            if n > 0 && n <= audioArray.count { effectiveCount = n }
        }
        effectiveCount = min(max(effectiveCount, 1), variant.maxSamples)

        var waveform = [Float](repeating: 0, count: effectiveCount)
        switch audioArray.dataType {
        case .float32:
            let ptr = audioArray.dataPointer.bindMemory(to: Float.self, capacity: audioArray.count)
            waveform.withUnsafeMutableBufferPointer { buf in
                buf.baseAddress!.update(from: ptr, count: effectiveCount)
            }
        case .float16:
            let ptr = audioArray.dataPointer.bindMemory(to: UInt16.self, capacity: audioArray.count)
            for i in 0..<effectiveCount { waveform[i] = Float(Float16(bitPattern: ptr[i])) }
        default:
            for i in 0..<effectiveCount { waveform[i] = audioArray[i].floatValue }
        }

        let duration = Double(effectiveCount) / sampleRate
        print("🔊 \(effectiveCount) samples (\(String(format: "%.2f", duration))s)")

        // 8. Post-processing — matches FluidAudio exactly:
        //    normalize first, then rumble removal, then de-essing (-3 dB @ 6 kHz)
        KokoroDSP.applyPostProcessing(&waveform, sampleRate: Float(sampleRate))

        return waveform
    }

    /// Synthesize to an AVAudioPCMBuffer at the model's native sample rate.
    public func synthesize(_ text: String) async throws -> AVAudioPCMBuffer {
        try pcmBuffer(from: try await synthesizeWaveform(text), sampleRate: sampleRate)
    }

}
