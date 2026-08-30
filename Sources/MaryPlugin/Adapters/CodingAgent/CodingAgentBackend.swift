//
//  CodingAgentBackend.swift
//  MaryPlugin
//
//  WHAT: Provider-neutral coding-agent seam.
//  IN:   composition root (Runtime)
//  OUT:  CodingAgentSessions
//  PIN:  MaryPlugin never loads an MLX model; MaryBrain implements this.
//

import Foundation

public enum CodingAgentDelivery: Sendable, Equatable {
    /// Return once running; speak later only on failure.
    case background
    /// Wait for a terminal state (pair-program verification).
    case awaited
}

public struct CodingAgentRun: Sendable, Equatable {
    public var sessionID: String
    public var summary: String
    public var ok: Bool

    public init(sessionID: String, summary: String, ok: Bool) {
        self.sessionID = sessionID
        self.summary = summary
        self.ok = ok
    }
}

public struct CodingAgentCompletion: Sendable, Equatable {
    public var handle: String
    public var delivery: CodingAgentDelivery
    public var ok: Bool
    public var summary: String
    public var task: String
    public var workdir: String

    public init(
        handle: String, delivery: CodingAgentDelivery, ok: Bool,
        summary: String, task: String, workdir: String
    ) {
        self.handle = handle
        self.delivery = delivery
        self.ok = ok
        self.summary = summary
        self.task = task
        self.workdir = workdir
    }
}

/// Coding-agent runner. Runtime injects; nil means the faculty is off.
public protocol CodingAgentBackend: Sendable {
    func isPrepared() async -> Bool
    func unpreparedSummary() async -> String
    func prepare(modelID: String) async throws
    func downloadProgress() async -> Double
    func run(
        brief: String,
        workdir: String,
        delivery: CodingAgentDelivery
    ) async throws -> CodingAgentRun
    func resume(
        sessionID: String,
        message: String,
        workdir: String
    ) async throws -> CodingAgentRun
    func cancel(sessionID: String) async
}

public extension CodingAgentBackend {
    func unpreparedSummary() async -> String {
        "The coding agent has no model yet. Open Settings, download the coding model, and select it."
    }
}

public enum CodingAgentBackendError: Error, LocalizedError, Sendable {
    case notPrepared
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "The coding agent is not ready."
        case .cancelled:
            return "The coding-agent session was stopped."
        case .failed(let reason):
            return reason
        }
    }
}
