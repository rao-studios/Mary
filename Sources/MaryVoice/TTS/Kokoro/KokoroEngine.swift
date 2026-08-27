//
//  KokoroEngine.swift
//  MaryVoice
//
//  On-device Kokoro TTS using FluidAudio's CoreML models (no SDK dependency).
//  Faithful port of SeerTTS/KokoroTTSDemo's TTSClient with two deliberate
//  changes: the @MainActor singleton becomes an injectable actor, and the
//  iOS AVAudioSession branches are dropped (this package is macOS-only).
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
    /// The sample rate of the most recently used model — kept in sync by synthesizeWaveform.
    public internal(set) var sampleRate: Double = 24_000

    let phonemizer = KokoroPhonemizer()
    let g2p        = KokoroG2P()
    var currentVoice: KokoroVoice?

    // Both neutral and styled playback share the same engine/player pair.
    // postProcessor == nil distinguishes the neutral (no-effects) path.
    var effectsEngine: AVAudioEngine?
    var effectsPlayer: AVAudioPlayerNode?
    var postProcessor: KokoroAudioProcessor?

    var configChangeObserver: NSObjectProtocol?

    /// Where the models were loaded from — kept for G2P validation reloads.
    var modelsDirectory: URL?

    /// The trace of the most recent synthesis.
    public internal(set) var lastPronunciationReport: PronunciationReport?
    var pronunciationContinuations: [UUID: AsyncStream<PronunciationReport>.Continuation] = [:]

    public init() {
        // Rebuild effects engine when hardware changes (Bluetooth connect/disconnect,
        // headphones plug/unplug, AirPlay switch) so the graph matches the new bus rate.
        // Registered lazily on first load; actor inits can't touch self in a closure.
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
