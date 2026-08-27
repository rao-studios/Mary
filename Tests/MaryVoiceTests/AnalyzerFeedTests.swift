//
//  AnalyzerFeedTests.swift
//  MaryVoiceTests
//
//  THE CRASH THIS GUARDS: feeding the microphone's own Float32 buffers to
//  `SpeechAnalyzer` killed the process on SIGTRAP —
//  "Failed precondition: Audio sample data must be 16-bit signed integers" —
//  the moment AirPods connected, because their 24 kHz rate is one the
//  analyzer accepts where the built-in mic's 48 kHz had been refused up
//  front. So the assertion in every row below is the same one: whatever the
//  hardware hands us, what leaves this type is in the analyzer's format.
//

import AVFoundation
import Foundation
import Testing
@testable import MaryVoice

@Suite struct AnalyzerFeedTests {

    /// What the on-device recognizer asks for.
    private var analyzerFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false)!
    }

    /// What the tap produces, at whatever rate the hardware runs.
    private func micBuffer(sampleRate: Double, frames: AVAudioFrameCount = 1024)
        -> AVAudioPCMBuffer
    {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        // A real room's noise floor, not silence: a converter handed all
        // zeros can't distinguish "converted" from "produced nothing".
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            channel[i] = 0.1 * sin(Float(i) * 0.05)
        }
        return buffer
    }

    /// 24 kHz is the AirPods rate that crashed live.
    @Test(arguments: [24_000.0, 48_000.0, 16_000.0, 44_100.0])
    func everyHardwareRateArrivesAsSixteenBit(rate: Double) throws {
        let feed = AnalyzerFeed(target: analyzerFormat)
        let converted = try #require(feed.convert(micBuffer(sampleRate: rate)))

        #expect(converted.format.commonFormat == .pcmFormatInt16)
        #expect(converted.format.sampleRate == 16_000)
        #expect(converted.format.channelCount == 1)
        #expect(converted.frameLength > 0)
        #expect(converted.int16ChannelData != nil)
    }

    /// NO AUDIO IS LOST ACROSS A SESSION, which is the property that
    /// actually decides whether she hears the room: a converter that dropped
    /// even 15 ms out of every 100 would still pass every format assertion
    /// above and transcribe gibberish.
    ///
    /// Ten tap-sized buffers at 48 kHz — 10240 frames — must come out as
    /// 10240/3 at 16 kHz, give or take the few frames the resampler's filter
    /// holds while priming. Holding ONE converter for the whole session is
    /// what keeps that cost to once per device instead of once per frame.
    @Test func nothingIsLostAcrossASessionOfFrames() throws {
        let feed = AnalyzerFeed(target: analyzerFormat)
        var produced = 0
        for _ in 0..<10 {
            let converted = try #require(feed.convert(micBuffer(sampleRate: 48_000, frames: 1024)))
            produced += Int(converted.frameLength)
        }
        let expected = 10 * 1024 / 3
        #expect(abs(produced - expected) <= 8)
    }

    /// A DEVICE SWAP MID-SESSION is a change of INPUT format, and the whole
    /// point of holding the converter is that it rebuilds itself when that
    /// happens instead of feeding the analyzer the new rate raw — which is
    /// the crash, arriving a second time by another road.
    @Test func aMidSessionRateChangeStillConvertsToTheAnalyzerFormat() throws {
        let feed = AnalyzerFeed(target: analyzerFormat)
        _ = try #require(feed.convert(micBuffer(sampleRate: 48_000)))

        // AirPods connect; the tap rebuilds at 24 kHz.
        let afterSwap = try #require(feed.convert(micBuffer(sampleRate: 24_000)))
        #expect(afterSwap.format == analyzerFormat)

        // And back again when they go away.
        let afterRevert = try #require(feed.convert(micBuffer(sampleRate: 48_000)))
        #expect(afterRevert.format == analyzerFormat)
    }

    /// Already in the analyzer's format: no conversion, no copy.
    @Test func amatchingFormatPassesStraightThrough() throws {
        let feed = AnalyzerFeed(target: analyzerFormat)
        let buffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: 512)!
        buffer.frameLength = 512
        let converted = try #require(feed.convert(buffer))
        #expect(converted === buffer)
    }
}
