//
//  PCMBytes.swift
//  MaryVoice
//
//  WHAT: Socket deltas → float32 LE samples. Trailing partial word dropped.
//  IN:   SewnTTSEngine / KokoroStreamSpeaker.enqueueRemotePCM
//  OUT:  playback / ChunkEdgeDSP
//

import Foundation

enum PCMBytes {
    /// Interpret raw bytes as float32 little-endian mono. Drop a trailing partial word.
    static func floats(fromFloat32LE data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float32>.size
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        samples.withUnsafeMutableBytes { dest in
            data.copyBytes(to: dest, from: 0..<(count * MemoryLayout<Float32>.size))
        }
        return samples
    }
}
