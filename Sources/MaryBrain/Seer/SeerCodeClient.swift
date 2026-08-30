//
//  SeerCodeClient.swift
//  MaryBrain
//
//  One bounded coding-invocation round through Seer's `/v1/code/complete`.
//  Same auth as SeerSkillClient. Mary never sends a model id. File tools
//  still run on device through CodingAgentWorkspace.
//

import Foundation

public actor SeerCodeClient: SeerSkillProviding {

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
            maxTokens: 2048,
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
                id: "code-\(UUID().uuidString.prefix(8))-\(index)",
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
            url: baseURL.appendingPathComponent("v1/code/complete"))
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
