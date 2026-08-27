//
//  PCMBytes.swift
//  MaryVoice
//
//  RAW BYTES OFF A SOCKET, READ AS SOUND.
//
//  A streamed voice arrives as a sequence of deltas whose boundaries have
//  nothing to do with sample boundaries: a chunk can end halfway through a
//  float. The dropped tail is the whole reason this is a named function
//  rather than an `unsafeBitCast` at the call site — a partial word
//  reinterpreted as a sample is a click in the user's ear.
//

import Foundation

enum PCMBytes {
    /// Interpret raw bytes as float32 little-endian mono samples. Any trailing
    /// partial word (a delta split mid-sample) is dropped.
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
