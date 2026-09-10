//
//  StreamingHTTP.swift
//  MaryBrain
//
//  WHAT: Streaming HTTP must have a wall clock, not only an idle timer.
//  IN:   Sewn SSE / HTTP streams
//  OUT:  bounded URLSession
//  PIN:  timeoutIntervalForRequest is idle; resource timeout lives on the session.
//
import Foundation

enum StreamingHTTP {

    /// IDLE timeout — the gap between bytes. Thinking models (Inkling) can deliberate well past URLSession's 60 s default before emitting their first token
    static let idleTimeout: TimeInterval = 300

    /// WALL CLOCK for the whole request, first byte to last.
    static let resourceTimeout: TimeInterval = 120

    /// The session every SSE consumer in this package streams on.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = idleTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
