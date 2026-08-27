//
//  KokoroAudioProcessor.swift
//  Sis
//
//  Created by Ritesh Pakala Rao on 12/23/25.
//
//  AVAudio graph chain (tone shaping & style only):
//
//    playerNode → timePitch → eq → reverb → mainMixerNode
//
//  Note: de-essing and rumble removal are handled upstream by KokoroDSP
//  on the raw float samples (matching FluidAudio exactly). This graph
//  only applies tonal shaping from TTSSpeechStyle.
//
//  Default state is flat / transparent (gains 0, reverb 0 %).
//  KokoroDSP handles de-essing and rumble on the raw samples.
//  TTSSpeechStyle.apply() sets non-neutral values before each utterance.
//  TimePitch: rate 1.0, pitch 0 cents — adjusted per TTSSpeechStyle
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

    /// Attach all nodes and wire: playerNode → timePitch → eq → reverb → mainMixerNode
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

    /// Apply a TTSSpeechStyle's resolved audio parameters to all nodes.
    /// Call this before starting the engine for the next utterance.
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
