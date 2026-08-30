//
//  SeerSkillClientTests.swift
//  MaryBrainTests
//
//  `/v1/skills/complete` bytes: the path, the tool roster, and the absence
//  of a `seer` RAG object. Scripted transport, no live server.
//

import XCTest
@testable import MaryBrain

private final class ScriptedSkillPost: @unchecked Sendable {
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

private final class ScriptedSkillTransport: SeerSkillTransport, @unchecked Sendable {
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

final class SeerSkillClientTests: XCTestCase {

    private func makeClient(
        transport: ScriptedSkillTransport,
        post: ScriptedSkillPost = ScriptedSkillPost([(200, signInBody)])
    ) async -> SeerSkillClient {
        let session = SeerSession(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            email: "a@b.c", password: "pw",
            post: { try await post.post($0) })
        await session.signIn()
        return SeerSkillClient(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            session: session,
            transport: transport)
    }

    func testPostsToSkillsCompleteWithToolsAndOmitsTheSeerScope() async throws {
        let transport = ScriptedSkillTransport([(200, """
        {"text":"","tool_calls":[{"name":"look","arguments":"{\\"direction\\":\\"ahead\\"}"}]}
        """)])
        let client = await makeClient(transport: transport)
        let schema = ModelSkillSchema(
            name: "look",
            description: "Look at the screen",
            parameters: [
                .init(name: "direction", type: "string", description: "where", required: true)
            ])
        let round = try await client.complete(
            instructions: "Use the roster.",
            messages: [SeerChatMessage(role: "user", content: "what is this")],
            skills: [schema])

        XCTAssertEqual(round.invocations.count, 1)
        XCTAssertEqual(round.invocations[0].name, "look")
        XCTAssertTrue(round.invocations[0].argumentsJSON.contains("ahead"))
        let request = try XCTUnwrap(transport.openedRequests.first)
        XCTAssertEqual(request.url?.path, "/v1/skills/complete")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-1")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(object["seer"])
        XCTAssertEqual(object["instructions"] as? String, "Use the roster.")
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "look")
        XCTAssertEqual(object["max_tokens"] as? Int, 800)
    }

    func testEmptyTextWithNoCallsIsAnError() async throws {
        let transport = ScriptedSkillTransport([(200, #"{"text":""}"#)])
        let client = await makeClient(transport: transport)
        do {
            _ = try await client.complete(
                instructions: nil,
                messages: [SeerChatMessage(role: "user", content: "hi")],
                skills: [])
            XCTFail("empty round must not succeed")
        } catch SeerSkillError.emptyReply {
            // expected
        }
    }

    func test401RefreshesAndRetriesOnce() async throws {
        let post = ScriptedSkillPost([
            (200, signInBody),
            (200, """
            {"access_token":"tok-2","refresh_token":"ref-2","expires_in":3600,"user_id":"OWNER-ABC"}
            """),
        ])
        let transport = ScriptedSkillTransport([
            (401, #"{"error":"expired"}"#),
            (200, #"{"text":"ok"}"#),
        ])
        let client = await makeClient(transport: transport, post: post)
        let round = try await client.complete(
            instructions: nil,
            messages: [SeerChatMessage(role: "user", content: "hi")],
            skills: [])
        XCTAssertEqual(round.text, "ok")
        XCTAssertEqual(transport.openedRequests.count, 2)
        XCTAssertEqual(
            transport.openedRequests.last?.value(forHTTPHeaderField: "Authorization"),
            "Bearer tok-2")
    }
}

final class MarySeerSkillEngineTests: XCTestCase {

    func testHistoryMapsSkillResultsAsLabeledUserText() {
        let messages = MarySeerSkillEngine.messages(from: [
            BrainTurn(role: .user, text: "raise TextEdit"),
            BrainTurn(role: .assistant, text: "looking"),
            BrainTurn(
                role: .skillResult,
                text: "untitled window",
                skillName: "look"),
        ])
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].content, "raise TextEdit")
        XCTAssertEqual(messages[1].role, "assistant")
        XCTAssertEqual(messages[1].content, "looking")
        XCTAssertEqual(messages[2].role, "user")
        XCTAssertEqual(messages[2].content, "[skill result — look]: untitled window")
    }

    func testStreamYieldsHostedInvocationsWhenReady() async throws {
        let client = ScriptedSkillProvider(ready: true, round: SeerSkillRound(
            text: "",
            invocations: [
                ModelSkillInvocation(id: "1", name: "look", argumentsJSON: "{}")
            ]))
        let engine = MarySeerSkillEngine(client: client)
        var names: [String] = []
        for try await event in engine.stream(
            system: "sys", history: [BrainTurn(role: .user, text: "look")], skills: [])
        {
            if case .skillInvocation(let invocation) = event {
                names.append(invocation.name)
            }
        }
        XCTAssertEqual(names, ["look"])
    }
}

private struct ScriptedSkillProvider: SeerSkillProviding {
    let ready: Bool
    let round: SeerSkillRound

    func isReady() async -> Bool { ready }
    func complete(
        instructions: String?,
        messages: [SeerChatMessage],
        skills: [ModelSkillSchema]
    ) async throws -> SeerSkillRound {
        round
    }
}
