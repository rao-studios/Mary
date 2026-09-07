//
//  SewnProvidersClient.swift
//  MaryBrain
//
//  WHAT: What backends the local Sewn can actually serve, and warming the
//        on-device one before a turn waits on it.
//  IN:   MaryRuntime.applyEngine / the Settings status row
//  OUT:  SewnProviderStatus per backend
//  PIN:  A backend Mary cannot reach is reported with Sewn's own reason —
//        the picker says why rather than letting the first turn fail.
//
import Foundation

public struct SewnProviderStatus: Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var available: Bool
    public var isDefault: Bool
    /// "cold" | "loading" | "ready" | "failed" | "unconfigured"
    public var state: String
    /// 0…1 while an on-device model loads.
    public var progress: Double?
    public var model: String
    public var reason: String?

    public var choice: LLMEngineChoice? { LLMEngineChoice(rawValue: id) }
    public var isLoading: Bool { state == "loading" }

    public init(
        id: String, displayName: String, available: Bool, isDefault: Bool,
        state: String, progress: Double?, model: String, reason: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.available = available
        self.isDefault = isDefault
        self.state = state
        self.progress = progress
        self.model = model
        self.reason = reason
    }
}

public enum SewnProvidersError: LocalizedError, Equatable {
    case notAuthenticated
    case http(Int)
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in to Sewn."
        case .http(let status): return "Sewn providers failed (\(status))."
        case .unreachable(let reason): return "Sewn is unreachable: \(reason)"
        }
    }
}

/// The status seam. Tests script it; the app wires `SewnProvidersClient`.
public protocol SewnProvidersProviding: Sendable {
    func statuses() async throws -> [SewnProviderStatus]
    func warmLocal() async throws
}

public actor SewnProvidersClient: SewnProvidersProviding {

    private var baseURL: URL
    private let session: SewnSession
    private let transport: any SewnCompleteTransport

    public init(
        baseURL: URL,
        session: SewnSession,
        transport: any SewnCompleteTransport = URLSessionCompleteTransport()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.transport = transport
    }

    public func configure(baseURL: URL) {
        self.baseURL = baseURL
    }

    public func statuses() async throws -> [SewnProviderStatus] {
        let body = try await get("v1/providers")
        guard let response = try? JSONDecoder().decode(Wire.Response.self, from: body)
        else { return [] }
        return response.providers.map {
            SewnProviderStatus(
                id: $0.id,
                displayName: $0.displayName ?? $0.id,
                available: $0.available,
                isDefault: $0.isDefault ?? false,
                state: $0.state,
                progress: $0.progress,
                model: $0.model ?? "",
                reason: $0.reason)
        }
    }

    public func warmLocal() async throws {
        _ = try await post("v1/providers/local/warm")
    }

    // MARK: - Transport

    private func get(_ path: String) async throws -> Data {
        try await send(path: path, method: "GET")
    }

    private func post(_ path: String) async throws -> Data {
        try await send(path: path, method: "POST")
    }

    private func send(path: String, method: String) async throws -> Data {
        guard var token = await session.validToken() else {
            throw SewnProvidersError.notAuthenticated
        }
        var attempt = try await open(path: path, method: method, bearer: token)
        if attempt.status == 401 {
            guard let fresh = await session.refreshAfter401() else {
                throw SewnProvidersError.notAuthenticated
            }
            token = fresh
            attempt = try await open(path: path, method: method, bearer: token)
        }
        guard (200...299).contains(attempt.status) else {
            throw SewnProvidersError.http(attempt.status)
        }
        return attempt.body
    }

    private func open(
        path: String, method: String, bearer: String
    ) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        do {
            return try await transport.post(request)
        } catch {
            throw SewnProvidersError.unreachable(error.localizedDescription)
        }
    }

    private enum Wire {
        struct Response: Decodable {
            var providers: [Provider]
        }

        struct Provider: Decodable {
            var id: String
            var displayName: String?
            var available: Bool
            var isDefault: Bool?
            var state: String
            var progress: Double?
            var model: String?
            var reason: String?

            enum CodingKeys: String, CodingKey {
                case id, available, state, progress, model, reason
                case displayName = "display_name"
                case isDefault = "default"
            }
        }
    }
}
