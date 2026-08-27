//
//  MicFrame.swift
//  MaryVoice
//
//  Split out of MicCapture.swift (docs/DECOMPOSITION.md Wave 2) — pure
//  relocation, no declaration changed. Analyzer anchors for MicFrame and
//  MicCaptureLifecycleGate.allows re-pinned to this file in the same
//  commit.
//

import AVFoundation
import Accelerate
import CoreAudio
import Foundation
import os

public struct MicFrame: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    /// RMS level of this buffer, 0…1.
    public let rms: Float
    public let duration: TimeInterval

    /// Public so consumers of `WakeWordListener`'s injected frame source can
    /// synthesize frames (the app's tests drive standby without a mic).
    public init(buffer: AVAudioPCMBuffer, rms: Float, duration: TimeInterval) {
        self.buffer = buffer
        self.rms = rms
        self.duration = duration
    }
}

/// The render callback cannot synchronize with `MicCapture`'s control queue:
/// doing so would make a real-time CoreAudio thread wait on graph teardown.
/// This tiny lock only protects the session generation, so callbacks and a
/// stop request can reject stale work without touching the audio graph.
final class MicCaptureLifecycleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var acceptingWork = false

    /// Starts a new generation. A `MicCapture` owns at most one live stream.
    func begin() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !acceptingWork else { return nil }
        generation &+= 1
        acceptingWork = true
        return generation
    }

    /// Closes the current generation immediately, before graph teardown gets
    /// its turn on the serial control queue.
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
