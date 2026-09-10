//
//  SewnCodeClient.swift
//  MaryBrain
//
//  WHAT: One bounded coding round through `/v1/code/complete`.
//  IN:   MarySewnCodingEngine
//  OUT:  invocation; file tools still run on device
//  PIN:  Mary never sends a model id.
//
import Foundation

public actor SewnCodeClient: SewnSkillProviding {

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
            maxTokens: 2048,
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
                id: "code-\(UUID().uuidString.prefix(8))-\(index)",
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
            url: baseURL.appendingPathComponent("v1/code/complete"))
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
