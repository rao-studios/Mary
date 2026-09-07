//
//  SewnSkillClient.swift
//  MaryBrain
//
//  WHAT: One bounded skill-invocation round through `/v1/skills/complete`.
//  IN:   MarySewnSkillEngine
//  OUT:  invocation synthesis; Mary still dispatches on device
//
import Foundation

public protocol SewnSkillTransport: Sendable {
    func post(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

public enum SewnSkillError: LocalizedError, Equatable {
    case notAuthenticated
    case http(Int)
    case unreachable(String)
    case emptyReply

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in to Sewn."
        case .http(let status): return "Sewn skills complete failed (\(status))."
        case .unreachable(let reason): return "Sewn is unreachable: \(reason)"
        case .emptyReply: return "Sewn skills complete returned nothing."
        }
    }
}

public struct SewnSkillRound: Sendable {
    public var text: String
    public var invocations: [ModelSkillInvocation]

    public init(text: String, invocations: [ModelSkillInvocation]) {
        self.text = text
        self.invocations = invocations
    }
}

/// The skill-synthesis seam onto `/v1/skills/complete`. Tests script it.
public protocol SewnSkillProviding: Sendable {
    func isReady() async -> Bool
    func complete(
        instructions: String?,
        messages: [SewnChatMessage],
        skills: [ModelSkillSchema]
    ) async throws -> SewnSkillRound
}

public actor SewnSkillClient: SewnSkillProviding {

    private var baseURL: URL
    private let session: SewnSession
    private let transport: any SewnSkillTransport
    private var provider: LLMEngineChoice?

    public init(
        baseURL: URL,
        session: SewnSession,
        transport: any SewnSkillTransport = URLSessionSkillTransport()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.transport = transport
    }

    public func configure(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Which backend Sewn uses for this lane. Separate from `configure`: the
    /// servers applier must not reset the user's choice.
    public func setProvider(_ provider: LLMEngineChoice?) {
        self.provider = provider
    }

    public func isReady() async -> Bool {
        await session.isAuthenticated
    }

    public func complete(
        instructions: String?,
        messages: [SewnChatMessage],
        skills: [ModelSkillSchema]
    ) async throws -> SewnSkillRound {
        guard var token = await session.validToken() else {
            throw SewnSkillError.notAuthenticated
        }

        let body = try JSONEncoder().encode(SewnWire.SkillsCompleteRequest(
            instructions: instructions,
            messages: messages,
            tools: skills.isEmpty ? nil : skills.map(SewnWire.SkillTool.from),
            maxTokens: 800,
            temperature: 0,
            provider: provider))

        var attempt = try await open(body: body, bearer: token)
        if attempt.status == 401 {
            guard let fresh = await session.refreshAfter401() else {
                throw SewnSkillError.notAuthenticated
            }
            token = fresh
            attempt = try await open(body: body, bearer: token)
        }
        guard attempt.status == 200 else {
            throw SewnSkillError.http(attempt.status)
        }
        guard let response = try? JSONDecoder().decode(
            SewnWire.SkillsCompleteResponse.self, from: attempt.body)
        else {
            throw SewnSkillError.emptyReply
        }
        let invocations = response.toolCalls.enumerated().map { index, call in
            ModelSkillInvocation(
                id: "sewn-\(UUID().uuidString.prefix(8))-\(index)",
                name: call.name,
                argumentsJSON: call.arguments.isEmpty ? "{}" : call.arguments)
        }
        if invocations.isEmpty, response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SewnSkillError.emptyReply
        }
        return SewnSkillRound(text: response.text, invocations: invocations)
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
        } catch let error as SewnSkillError {
            throw error
        } catch {
            throw SewnSkillError.unreachable(error.localizedDescription)
        }
    }
}

public struct URLSessionSkillTransport: SewnSkillTransport {
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
