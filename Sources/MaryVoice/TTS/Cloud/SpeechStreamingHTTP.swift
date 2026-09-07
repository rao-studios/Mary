//
//  SpeechStreamingHTTP.swift
//  MaryVoice
//
//  WHAT: Wall-clock + idle timeouts for cloud TTS HTTP.
//  IN:   SewnTTSEngine
//  OUT:  shared URLSession (idle 60s, first-byte 4s, resource 30s)
//  PIN:  Separate from MaryBrain StreamingHTTP — MaryVoice cannot import it.
//

import Foundation

enum SpeechStreamingHTTP {

    /// Idle gap between bytes. Unchanged at 60s — first-byte bound is what fails fast.
    static let idleTimeout: TimeInterval = 60

    /// First-byte (and inter-byte) bound for one spoken chunk. PIN: 4s so Kokoro
    /// fallback can speak inside the caller's speaking budget.
    static let firstByteTimeout: TimeInterval = 4

    /// Wall clock for the whole request. PIN: ~10× healthy synthesis; retry once.
    static let resourceTimeout: TimeInterval = 30

    /// Shared session for both cloud voices. One sentence per request — keep-alive matters.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = idleTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        // Fail if unreachable; Kokoro fallback is standing behind this call.
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
