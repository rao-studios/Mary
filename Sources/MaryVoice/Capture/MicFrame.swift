//
//  MicFrame.swift
//  MaryVoice
//
//  WHAT: One captured PCM buffer plus RMS.
//  IN:   MicCapture tap / test frame sources
//  OUT:  VoicePipeline / WakeWordListener / EnergyVAD
//
//  Sibling of MicCapture.swift (lifecycle gate lives here).
//

import AVFoundation
import Accelerate
import CoreAudio
import Foundation
import os

public struct MicFrame: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    /// RMS of this buffer, 0…1. Consumer: UI meter / VAD.
    public let rms: Float
    public let duration: TimeInterval

    /// Public so WakeWordListener's injected source can synthesize frames.
    public init(buffer: AVAudioPCMBuffer, rms: Float, duration: TimeInterval) {
        self.buffer = buffer
        self.rms = rms
        self.duration = duration
    }
}

/// Session generation lock. Render callback must not wait on MicCapture's
/// control queue. OUT: allow/reject stale tap work without touching the graph.
final class MicCaptureLifecycleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var acceptingWork = false

    /// Starts a new generation. A MicCapture owns at most one live stream.
    func begin() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !acceptingWork else { return nil }
        generation &+= 1
        acceptingWork = true
        return generation
    }

    /// Close the current generation immediately, before graph teardown.
    func requestStop() {
        lock.lock()
        acceptingWork = false
        lock.unlock()
    }

    func finish(_ expectedGeneration: UInt64) {
        lock.lock()
        if generation == expectedGeneration {
            acceptingWork = false
        }
        lock.unlock()
    }

    func allows(_ expectedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return acceptingWork && generation == expectedGeneration
    }
}
