//
//  SeerTTSTests.swift
//  MaryVoiceTests
//
//  The /v1/speak wire header and PCM split — the part of SeerTTSEngine that
//  can silently corrupt audio if it drifts.
//

import Foundation
import Testing
@testable import MaryVoice

@Suite struct SeerTTSTests {

    private func headerBytes(rate: UInt32 = 24_000, channels: UInt16 = 1, bits: UInt16 = 32) -> Data {
        var data = Data()
        withUnsafeBytes(of: rate.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: channels.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: bits.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    @Test func splitParsesHeaderAndRebasesPCM() throws {
        var payload = headerBytes()
        let samples: [Float] = [0.25, -0.5, 1.0]
        samples.withUnsafeBytes { payload.append(contentsOf: $0) }

        let (header, pcm) = try SeerPCMHeader.split(payload)
        #expect(header == SeerPCMHeader(sampleRate: 24_000, channels: 1, bits: 32))
        // The slice must be rebased — PCMBytes.floats indexes from zero.
        let decoded = PCMBytes.floats(fromFloat32LE: pcm)
        #expect(decoded == samples)
    }

    @Test func splitRejectsShortPayload() {
        #expect(throws: SeerTTSError.malformedHeader) {
            _ = try SeerPCMHeader.split(Data([1, 2, 3]))
        }
    }

    @Test func splitRejectsUnexpectedFormat() {
        // Stereo or non-float widths would decode to garbage — refuse loudly.
        #expect(throws: SeerTTSError.malformedHeader) {
            _ = try SeerPCMHeader.split(headerBytes(channels: 2) + Data(count: 8))
        }
        #expect(throws: SeerTTSError.malformedHeader) {
            _ = try SeerPCMHeader.split(headerBytes(bits: 16) + Data(count: 8))
        }
        #expect(throws: SeerTTSError.malformedHeader) {
            _ = try SeerPCMHeader.split(headerBytes(rate: 4_000) + Data(count: 8))
        }
    }

    @Test func emptyPCMAfterHeaderIsAllowedBySplit() throws {
        // The engine treats zero samples as .emptyAudio; split itself is fine.
        let (_, pcm) = try SeerPCMHeader.split(headerBytes())
        #expect(pcm.isEmpty)
        #expect(PCMBytes.floats(fromFloat32LE: pcm).isEmpty)
    }
}
