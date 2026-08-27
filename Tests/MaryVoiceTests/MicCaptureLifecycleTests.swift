//
//  MicCaptureLifecycleTests.swift
//  MaryVoiceTests
//
//  The lifecycle gate is deliberately independent of AVAudioEngine so the
//  stop/rebuild ordering can be tested without opening real audio hardware.
//

import Foundation
import Testing
@testable import MaryVoice

@Suite struct MicCaptureLifecycleTests {

    @Test func stopImmediatelyRejectsWorkFromTheLiveGeneration() throws {
        let gate = MicCaptureLifecycleGate()
        let generation = try #require(gate.begin())
        #expect(gate.allows(generation))

        gate.requestStop()

        #expect(!gate.allows(generation))
    }

    @Test func staleCallbacksCannotEnterAReplacementGeneration() throws {
        let gate = MicCaptureLifecycleGate()
        let retiredGeneration = try #require(gate.begin())
        gate.requestStop()

        let replacementGeneration = try #require(gate.begin())

        #expect(replacementGeneration != retiredGeneration)
        #expect(!gate.allows(retiredGeneration))
        #expect(gate.allows(replacementGeneration))
    }

    @Test func staleFinishCannotCloseANewerCapture() throws {
        let gate = MicCaptureLifecycleGate()
        let retiredGeneration = try #require(gate.begin())
        gate.requestStop()
        let replacementGeneration = try #require(gate.begin())

        gate.finish(retiredGeneration)

        #expect(gate.allows(replacementGeneration))
    }

    @Test func repeatedStopIsIdempotentAcrossConcurrentCallers() async throws {
        let gate = MicCaptureLifecycleGate()
        let generation = try #require(gate.begin())

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask { gate.requestStop() }
            }
        }

        #expect(!gate.allows(generation))
        #expect(gate.begin() != nil)
    }
}
