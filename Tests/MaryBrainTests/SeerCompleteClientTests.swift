//
//  SeerCompleteClientTests.swift
//  MaryBrainTests
//
//  `/v1/complete` bytes: the path, the JSON contract, and the absence of a
//  `seer` RAG object. Scripted transport, no live server.
//

import XCTest
@testable import MaryBrain

private final class ScriptedCompletePost: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Int, Data)]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [(Int, String)]) {
        self.responses = responses.map { ($0.0, Data($0.1.utf8)) }
    }

    func post(_ request: URLRequest) async throws -> (Data, Int) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        guard !responses.isEmpty else { return (Data(), 599) }
        let (status, body) = responses.removeFirst()
        return (body, status)
    }
}

private final class ScriptedCompleteTransport: SeerCompleteTransport, @unchecked Sendable {
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

final class SeerCompleteClientTests: XCTestCase {

    private func makeClient(
        transport: ScriptedCompleteTransport,
        post: ScriptedCompletePost = ScriptedCompletePost([(200, signInBody)])
    ) async -> SeerCompleteClient {
        let session = SeerSession(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            email: "a@b.c", password: "pw",
            post: { try await post.post($0) })
        await session.signIn()
        return SeerCompleteClient(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            session: session,
            transport: transport)
    }

    func testPostsToCompleteAndOmitsTheSeerScope() async throws {
        let transport = ScriptedCompleteTransport([(200, #"{"text":"{\"precis\":\"a\",\"labels\":[\"b\"]}"}"#)])
        let client = await makeClient(transport: transport)
        let text = try await client.complete(
            instructions: InferenceUnitAnnotator.systemPrompt,
            messages: [SeerChatMessage(role: "user", content: "struct Foo {}")])

        XCTAssertEqual(text, "{\"precis\":\"a\",\"labels\":[\"b\"]}")
        XCTAssertEqual(transport.openedRequests.count, 1)
        let request = try XCTUnwrap(transport.openedRequests.first)
        XCTAssertEqual(request.url?.path, "/v1/complete")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-1")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(object["seer"], "complete must not send a RAG scope")
        XCTAssertEqual(object["instructions"] as? String, InferenceUnitAnnotator.systemPrompt)
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "struct Foo {}")
        XCTAssertEqual(object["max_tokens"] as? Int, 256)
        if let temperature = object["temperature"] as? NSNumber {
            XCTAssertEqual(temperature.doubleValue, 0)
        } else {
            XCTFail("complete must send temperature 0")
        }
    }

    func test401RefreshesAndRetriesOnce() async throws {
        let post = ScriptedCompletePost([
            (200, signInBody),
            (200, """
            {"access_token":"tok-2","refresh_token":"ref-2","expires_in":3600,"user_id":"OWNER-ABC"}
            """),
        ])
        let transport = ScriptedCompleteTransport([
            (401, #"{"error":"expired"}"#),
            (200, #"{"text":"ok"}"#),
        ])
        let client = await makeClient(transport: transport, post: post)
        let text = try await client.complete(
            instructions: "be json",
            messages: [SeerChatMessage(role: "user", content: "hi")])
        XCTAssertEqual(text, "ok")
        XCTAssertEqual(transport.openedRequests.count, 2)
        XCTAssertEqual(
            transport.openedRequests.last?.value(forHTTPHeaderField: "Authorization"),
            "Bearer tok-2")
    }

    func testEmptyTextIsAnError() async throws {
        let transport = ScriptedCompleteTransport([(200, #"{"text":""}"#)])
        let client = await makeClient(transport: transport)
        do {
            _ = try await client.complete(
                instructions: nil,
                messages: [SeerChatMessage(role: "user", content: "hi")])
            XCTFail("empty text must not succeed")
        } catch SeerCompleteError.emptyReply {
            // expected
        }
    }

    func testCompleteResponseReadsOutputWhenTextIsAbsent() throws {
        let decoded = try JSONDecoder().decode(
            SeerWire.CompleteResponse.self,
            from: Data(#"{"output":"hello from output"}"#.utf8))
        XCTAssertEqual(decoded.text, "hello from output")
    }

    func testCompleteResponseReadsChatChoices() throws {
        let decoded = try JSONDecoder().decode(
            SeerWire.CompleteResponse.self,
            from: Data(#"{"choices":[{"message":{"content":"from choices"}}]}"#.utf8))
        XCTAssertEqual(decoded.text, "from choices")
    }

    func testCompleteClientAcceptsOutputKey() async throws {
        let transport = ScriptedCompleteTransport([(200, #"{"output":"ok"}"#)])
        let client = await makeClient(transport: transport)
        let text = try await client.complete(
            instructions: nil,
            messages: [SeerChatMessage(role: "user", content: "hi")])
        XCTAssertEqual(text, "ok")
    }
}
