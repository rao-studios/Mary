//
//  SeerSkillClient.swift
//  MaryBrain
//
//  One bounded skill-invocation round through Seer's `/v1/skills/complete`.
//  Auth follows SeerCompleteClient: bearer from the shared session, one
//  refresh-and-retry on 401. Spoken turns stay on the chat client; corpus
//  annotation stays on `/v1/complete`. This lane only synthesizes invocations —
//  Mary still dispatches tools on device.
//

import Foundation

public protocol SeerSkillTransport: Sendable {
    func post(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

public enum SeerSkillError: LocalizedError, Equatable {
    case notAuthenticated
    case http(Int)
    case unreachable(String)
    case emptyReply

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in to Seer."
        case .http(let status): return "Seer skills complete failed (\(status))."
        case .unreachable(let reason): return "Seer is unreachable: \(reason)"
        case .emptyReply: return "Seer skills complete returned nothing."
        }
    }
}

public struct SeerSkillRound: Sendable {
    public var text: String
    public var invocations: [ModelSkillInvocation]

    public init(text: String, invocations: [ModelSkillInvocation]) {
        self.text = text
        self.invocations = invocations
    }
}

/// The skill-synthesis seam onto `/v1/skills/complete`. Tests script it.
public protocol SeerSkillProviding: Sendable {
    func isReady() async -> Bool
    func complete(
        instructions: String?,
        messages: [SeerChatMessage],
        skills: [ModelSkillSchema]
    ) async throws -> SeerSkillRound
}

public actor SeerSkillClient: SeerSkillProviding {

    private var baseURL: URL
    private let session: SeerSession
    private let transport: any SeerSkillTransport

    public init(
        baseURL: URL,
        session: SeerSession,
        transport: any SeerSkillTransport = URLSessionSkillTransport()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.transport = transport
    }

    public func configure(baseURL: URL) {
        self.baseURL = baseURL
    }

    public func isReady() async -> Bool {
        await session.isAuthenticated
    }

    public func complete(
        instructions: String?,
        messages: [SeerChatMessage],
        skills: [ModelSkillSchema]
    ) async throws -> SeerSkillRound {
        guard var token = await session.validToken() else {
            throw SeerSkillError.notAuthenticated
        }

        let body = try JSONEncoder().encode(SeerWire.SkillsCompleteRequest(
            instructions: instructions,
            messages: messages,
            tools: skills.isEmpty ? nil : skills.map(SeerWire.SkillTool.from),
            maxTokens: 800,
            temperature: 0))

        var attempt = try await open(body: body, bearer: token)
        if attempt.status == 401 {
            guard let fresh = await session.refreshAfter401() else {
                throw SeerSkillError.notAuthenticated
            }
            token = fresh
            attempt = try await open(body: body, bearer: token)
        }
        guard attempt.status == 200 else {
            throw SeerSkillError.http(attempt.status)
        }
        guard let response = try? JSONDecoder().decode(
            SeerWire.SkillsCompleteResponse.self, from: attempt.body)
        else {
            throw SeerSkillError.emptyReply
        }
        let invocations = response.toolCalls.enumerated().map { index, call in
            ModelSkillInvocation(
                id: "seer-\(UUID().uuidString.prefix(8))-\(index)",
                name: call.name,
                argumentsJSON: call.arguments.isEmpty ? "{}" : call.arguments)
        }
        if invocations.isEmpty, response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SeerSkillError.emptyReply
        }
        return SeerSkillRound(text: response.text, invocations: invocations)
    }

    private func open(body: Data, bearer: String) async throws -> (status: Int, body: Data) {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1/skills/complete"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        do {
            return try await transport.post(request)
        } catch let error as SeerSkillError {
            throw error
        } catch {
            throw SeerSkillError.unreachable(error.localizedDescription)
        }
    }
}

public struct URLSessionSkillTransport: SeerSkillTransport {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    public init() {}

    public func post(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await Self.session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
