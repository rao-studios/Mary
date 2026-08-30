//
//  KokoroEngine.swift
//  MaryVoice
//
//  WHAT: On-device Kokoro TTS (FluidAudio CoreML, no SDK).
//  IN:   KokoroStreamSpeaker / speak()
//  OUT:  waveform → KokoroDSP / playback
//  PIN:  Injectable actor (not MainActor singleton); macOS-only.
//

import Foundation
import AVFoundation
@preconcurrency import CoreML
import Accelerate

// MARK: - KokoroEngine

public actor KokoroEngine {

    public internal(set) var isLoaded  = false
    public internal(set) var isSpeaking = false

    struct LoadedModel {
        let variant: TTSVariant
        let model:   MLModel
    }
    /// All loaded models, sorted by maxTokens ascending (smallest first).
    var loadedModels: [LoadedModel] = []
    /// Sample rate of the most recently used model — kept in sync by synthesizeWaveform.
    public internal(set) var sampleRate: Double = 24_000

    let phonemizer = KokoroPhonemizer()
    let g2p        = KokoroG2P()
    var currentVoice: KokoroVoice?

    // Neutral and styled playback share engine/player. postProcessor == nil → neutral.
    var effectsEngine: AVAudioEngine?
    var effectsPlayer: AVAudioPlayerNode?
    var postProcessor: KokoroAudioProcessor?

    var configChangeObserver: NSObjectProtocol?

    /// Where models were loaded from — G2P validation reloads.
    var modelsDirectory: URL?

    /// Trace of the most recent synthesis.
    public internal(set) var lastPronunciationReport: PronunciationReport?
    var pronunciationContinuations: [UUID: AsyncStream<PronunciationReport>.Continuation] = [:]

    public init() {
        // Rebuild effects engine on hardware-rate change. Registered lazily on first load.
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    func observeConfigurationChangesIfNeeded() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.teardownEffectsEngine() }
        }
    }

}
