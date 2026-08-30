//
//  KokoroAudioProcessor.swift
//  MaryVoice
//
//  WHAT: AVAudio graph for style only (tone / rate / reverb).
//  IN:   KokoroEngine.playStyled
//  OUT:  playerNode → timePitch → eq → reverb → mainMixerNode
//  PIN:  De-ess/rumble live in KokoroDSP, not this graph.
//

import AVFoundation

final class KokoroAudioProcessor {

    let timePitch = AVAudioUnitTimePitch()
    let eq        = AVAudioUnitEQ(numberOfBands: 2)
    let reverb    = AVAudioUnitReverb()

    init() {
        // Flat by default — styles write non-zero values before each utterance
        eq.globalGain = 0

        let lowShelf         = eq.bands[0]
        lowShelf.filterType  = .lowShelf
        lowShelf.frequency   = 200
        lowShelf.gain        = 0
        lowShelf.bypass      = false

        let midCut           = eq.bands[1]
        midCut.filterType    = .parametric
        midCut.frequency     = 3000
        midCut.bandwidth     = 1.0
        midCut.gain          = 0
        midCut.bypass        = false

        reverb.loadFactoryPreset(.smallRoom)
        reverb.wetDryMix = 0     // off by default; styles enable it

        timePitch.rate  = 1.0
        timePitch.pitch = 0
    }

    // MARK: - Graph

    /// Wire: playerNode → timePitch → eq → reverb → mainMixerNode
    func connect(player: AVAudioPlayerNode, to engine: AVAudioEngine, format: AVAudioFormat) {
        engine.attach(timePitch)
        engine.attach(eq)
        engine.attach(reverb)
        engine.connect(player,     to: timePitch, format: format)
        engine.connect(timePitch,  to: eq,        format: format)
        engine.connect(eq,         to: reverb,    format: format)
        engine.connect(reverb,     to: engine.mainMixerNode, format: format)
    }

    // MARK: - Style application

    /// Apply resolved audio parameters. Call before starting the engine.
    func apply(_ style: TTSSpeechStyle) {
        let p = style.audioParameters

        // EQ (2 bands — high-shelf removed, handled by KokoroDSP biquad)
        eq.globalGain    = p.globalGain
        eq.bands[0].gain = p.lowShelfGain
        eq.bands[1].gain = p.midCutGain

        // Reverb
        reverb.loadFactoryPreset(p.reverbPreset)
        reverb.wetDryMix = p.reverbMix

        // Rate / pitch
        timePitch.rate  = p.rate
        timePitch.pitch = p.pitch
    }
}
