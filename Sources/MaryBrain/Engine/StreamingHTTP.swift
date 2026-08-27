//
//  StreamingHTTP.swift
//  MaryBrain
//
//  ONE RULE: a streaming HTTP response must have a WALL CLOCK on it, not only
//  an idle timer.
//
//  THE FAILURE THIS PREVENTS (confirmed against a live user session). Every
//  SSE consumer in this package opened its stream on `URLSession.shared` with
//  `request.timeoutInterval = 300` and believed itself bounded at five
//  minutes. It was not. `URLRequest.timeoutInterval` maps to
//  `timeoutIntervalForRequest`, which is an IDLE timer: it measures the gap
//  between bytes and resets on every one of them. A server that keeps the
//  connection warm — SSE comment heartbeats, a `: ping` line, a slow trickle
//  of frames carrying no `data:` payload — resets that timer forever and the
//  request NEVER times out. The wall-clock cap that would have caught it,
//  `timeoutIntervalForResource`, lives on the session CONFIGURATION (a
//  `URLRequest` has no such field at all) and defaults to SEVEN DAYS.
//
//  That is how one wedged follow-up stream could eat every later answer: the
//  brain's follow-up chain waited on a request whose only ceiling was a week.
//  The chain is bounded independently now (`MaryBrain.followUpSpeechBudget`
//  and the ladder above it); this is the floor underneath it, so a lane round
//  with no chain above it is bounded too.
//
//  Deliberately a shared session rather than a per-call one: creating a
//  `URLSession` per request leaks the connection pool and defeats keep-alive,
//  and every consumer here wants the same two numbers.
//

import Foundation

enum StreamingHTTP {

    /// IDLE timeout — the gap between bytes. Thinking models (Inkling) can
    /// deliberate well past URLSession's 60 s default before emitting their
    /// first token, so this stays generous; it is not, and never was, the
    /// thing that bounds a hung stream.
    static let idleTimeout: TimeInterval = 300

    /// WALL CLOCK for the whole request, first byte to last. Two minutes: the
    /// replies on these streams are a spoken answer or a round of Skill invocations,
    /// both of which are seconds of generation, and a lane may take TEN such
    /// rounds. Sized so a stream that is alive-but-saying-nothing dies while
    /// the user is still interested, and so the routine watchdog above it
    /// (`MaryBrain.routineWatchdogNanoseconds`) has an arithmetic to rest on
    /// rather than a guess.
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
