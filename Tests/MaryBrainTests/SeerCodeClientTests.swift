//
//  SeerCodeClientTests.swift
//  MaryBrainTests
//

import XCTest
@testable import MaryBrain

private final class ScriptedCodePost: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Int, Data)]

    init(_ responses: [(Int, String)]) {
        self.responses = responses.map { ($0.0, Data($0.1.utf8)) }
    }

    func post(_ request: URLRequest) async throws -> (Data, Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !responses.isEmpty else { return (Data(), 599) }
        let (status, body) = responses.removeFirst()
        return (body, status)
    }
}

private final class ScriptedCodeTransport: SeerSkillTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [(Int, Data)]
    private(set) var openedRequests: [URLRequest] = []

    init(_ attempts: [(Int, String)]) {
        self.attempts = attempts.map { ($0.0, Data($0.1.utf8)) }
    }

    func post(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        lock.lock()
        openedRequests.append(request)
        let attempt = attempts.isEmpty ? (599, Data()) : attempts.removeFirst()
        lock.unlock()
        return attempt
    }
}

private let signInBody = """
{"access_token":"tok-1","refresh_token":"ref-1","expires_in":3600,"user_id":"OWNER-ABC"}
"""

final class SeerCodeClientTests: XCTestCase {

    private func makeClient(
        transport: ScriptedCodeTransport
    ) async -> SeerCodeClient {
        let post = ScriptedCodePost([(200, signInBody)])
        let session = SeerSession(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            email: "a@b.c", password: "pw",
            post: { try await post.post($0) })
        await session.signIn()
        return SeerCodeClient(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            session: session,
            transport: transport)
    }

    func testPostsToCodeCompleteWithNoModelField() async throws {
        let transport = ScriptedCodeTransport([(200, """
        {"text":"","tool_calls":[{"name":"apply_patch","arguments":"{\\"path\\":\\"A.swift\\",\\"patch\\":\\"+x\\"}"}]}
        """)])
        let client = await makeClient(transport: transport)
        let schema = ModelSkillSchema(
            name: "apply_patch", description: "patch",
            parameters: [
                .init(name: "path", type: "string", description: "file", required: true)
            ])
        let round = try await client.complete(
            instructions: "Edit.",
            messages: [SeerChatMessage(role: "user", content: "add a guard")],
            skills: [schema])
        XCTAssertEqual(round.invocations.count, 1)
        XCTAssertEqual(round.invocations[0].name, "apply_patch")
        let request = try XCTUnwrap(transport.openedRequests.first)
        XCTAssertEqual(request.url?.path, "/v1/code/complete")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(object["model"])
        XCTAssertNil(object["seer"])
        XCTAssertEqual(object["max_tokens"] as? Int, 2048)
    }
}

final class CodingAgentTurnLoopTests: XCTestCase {

    func testLoopStopsWhenTheRoundHasNoCalls() async throws {
        var history: [(role: String, text: String)] = [(role: "user", text: "hi")]
        let run = try await CodingAgentTurnLoop.run(
            sessionID: "s",
            workdir: "/tmp",
            history: &history,
            isCancelled: { false },
            generate: { _ in ("all done", []) })
        XCTAssertTrue(run.ok)
        XCTAssertEqual(run.summary, "all done")
    }

    func testHostedEngineIsUnpreparedWhenTheStackIsOff() async {
        let client = ScriptedCodeProvider(round: SeerSkillRound(text: "ok", invocations: []))
        let engine = MarySeerCodingEngine(
            client: client, stackEnabled: { false })
        let prepared = await engine.isPrepared()
        XCTAssertFalse(prepared)
        let hint = await engine.unpreparedSummary()
        XCTAssertTrue(hint.lowercased().contains("seer"))
    }
}

private struct ScriptedCodeProvider: SeerSkillProviding {
    let round: SeerSkillRound
    func isReady() async -> Bool { true }
    func complete(
        instructions: String?,
        messages: [SeerChatMessage],
        skills: [ModelSkillSchema]
    ) async throws -> SeerSkillRound {
        round
    }
}
