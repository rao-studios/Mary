//
//  SeerChatClientTests.swift
//  MaryBrainTests
//
//  SSE parsing, 401-refresh-retry, trailing-contribution capture, and session
//  bookkeeping over scripted transports — no live server.
//

import XCTest
@testable import MaryBrain
@testable import MaryAdapters
@testable import MaryAmbient

// MARK: - Scripted seams

/// Scripted HTTP for SeerSession: pops one (status, body) per call.
private final class ScriptedPost: @unchecked Sendable {
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

/// Scripted SSE transport: pops one (status, lines) attempt per open().
private final class ScriptedTransport: SeerSSETransport, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [(Int, [String])]
    private(set) var openedRequests: [URLRequest] = []

    init(_ attempts: [(Int, [String])]) {
        self.attempts = attempts
    }

    func open(_ request: URLRequest) async throws
        -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        lock.lock()
        openedRequests.append(request)
        let attempt = attempts.isEmpty ? (599, []) : attempts.removeFirst()
        lock.unlock()
        let lines = AsyncThrowingStream<String, Error> { continuation in
            for line in attempt.1 { continuation.yield(line) }
            continuation.finish()
        }
        return (attempt.0, lines)
    }
}

private let signInBody = """
{"access_token":"tok-1","refresh_token":"ref-1","expires_in":3600,"user_id":"OWNER-ABC"}
"""

private func makeSession(_ post: ScriptedPost) -> SeerSession {
    SeerSession(
        baseURL: URL(string: "http://127.0.0.1:8080")!,
        email: "a@b.c", password: "pw",
        post: { try await post.post($0) }
    )
}

// MARK: - Session tests

final class SeerSessionTests: XCTestCase {

    func testSignInStoresLowercasedUserID() async {
        let post = ScriptedPost([(200, signInBody)])
        let session = makeSession(post)
        let error = await session.signIn()
        XCTAssertNil(error)
        let authenticated = await session.isAuthenticated
        XCTAssertTrue(authenticated)
        let owner = await session.userID
        XCTAssertEqual(owner, "owner-abc", "Seer lowercases the JWT subject; ids must line up")
    }

    func testSignInFailureSurfacesStatus() async {
        let post = ScriptedPost([(400, "{}")])
        let session = makeSession(post)
        let error = await session.signIn()
        XCTAssertNotNil(error)
        let authenticated = await session.isAuthenticated
        XCTAssertFalse(authenticated)
    }

    func testValidTokenReusesFreshToken() async {
        let post = ScriptedPost([(200, signInBody)])
        let session = makeSession(post)
        await session.signIn()
        let token = await session.validToken()
        XCTAssertEqual(token, "tok-1")
        XCTAssertEqual(post.requests.count, 1, "no extra HTTP for a fresh token")
    }

    func testValidTokenSignsInWhenNeverAuthenticated() async {
        let post = ScriptedPost([(200, signInBody)])
        let session = makeSession(post)
        let token = await session.validToken()
        XCTAssertEqual(token, "tok-1")
    }

    func testRefreshAfter401UsesRefreshEndpointThenSignInFallback() async {
        let refreshed = """
        {"access_token":"tok-2","refresh_token":"ref-2","expires_in":3600,"user_id":"owner-abc"}
        """
        let post = ScriptedPost([(200, signInBody), (200, refreshed)])
        let session = makeSession(post)
        await session.signIn()
        let token = await session.refreshAfter401()
        XCTAssertEqual(token, "tok-2")
        XCTAssertTrue(post.requests[1].url!.path.hasSuffix("auth/refresh"))

        // Refresh dead → falls back to a full sign-in.
        let post2 = ScriptedPost([(200, signInBody), (401, "{}"), (200, signInBody)])
        let session2 = makeSession(post2)
        await session2.signIn()
        let token2 = await session2.refreshAfter401()
        XCTAssertEqual(token2, "tok-1")
        XCTAssertTrue(post2.requests[2].url!.path.hasSuffix("auth/sign-in"))
    }
}

// MARK: - Chat client tests

final class SeerChatClientTests: XCTestCase {

    private func makeClient(
        transport: ScriptedTransport,
        post: ScriptedPost = ScriptedPost([(200, signInBody)])
    ) async -> SeerChatClient {
        let session = makeSession(post)
        await session.signIn()
        return SeerChatClient(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            session: session,
            personalTotemID: "totem-1",
            transport: transport
        )
    }

    private func collect(_ client: SeerChatClient) async throws -> [SeerChatEvent] {
        var events: [SeerChatEvent] = []
        let stream = client.stream(
            messages: [SeerChatMessage(role: "user", content: "hi")],
            instructions: "be brief")
        for try await event in stream { events.append(event) }
        return events
    }

    func testTokensAndTrailingContribution() async throws {
        let transport = ScriptedTransport([(200, [
            #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#,
            #"data: {"choices":[{"delta":{"content":" there."}}]}"#,
            "ignore me — not a data line",
            #"data: {"choices":[],"contribution":{"owners":[{"totem_id":"t1","owner_id":"o1","spans":[{"lower":0,"upper":5}],"royalty":1.0,"influence":{"d1":0.7},"document_ids":["d1"]}],"total_cost":0}}"#,
            "data: [DONE]",
            #"data: {"choices":[{"delta":{"content":"NEVER"}}]}"#,
        ])])
        let client = await makeClient(transport: transport)
        let events = try await collect(client)

        var text = ""
        var contribution: SeerContribution?
        for event in events {
            switch event {
            case .token(let token): text += token
            case .contribution(let value): contribution = value
            case .scoped: break   // every request leads with its scope trace
            case .autoMemory: XCTFail("no auto_memory scripted")
            case .phase, .audio, .ttsFailed: XCTFail("realtime-only event from the classic client")
            }
        }
        XCTAssertEqual(text, "Hello there.")
        XCTAssertEqual(contribution?.owners.count, 1)
        let owner = contribution?.owners.first
        XCTAssertEqual(owner?.totemID, "t1")
        XCTAssertEqual(owner?.spans, [SeerContribution.TextSpan(lower: 0, upper: 5)])
        XCTAssertEqual(owner?.influence["d1"], 0.7)
    }

    func testAutoMemoryLastValueWinsAndYieldsOnce() async throws {
        let transport = ScriptedTransport([(200, [
            #"data: {"choices":[{"delta":{"content":"a"}}],"auto_memory":false}"#,
            #"data: {"choices":[{"delta":{"content":"b"}}],"auto_memory":true}"#,
            "data: [DONE]",
        ])])
        let client = await makeClient(transport: transport)
        let events = try await collect(client)
        let autoMemoryEvents = events.filter {
            if case .autoMemory(let value) = $0 { return value }
            return false
        }
        XCTAssertEqual(autoMemoryEvents.count, 1)
    }

    func testNoAutoMemoryEventWhenLastChunkSaysFalse() async throws {
        let transport = ScriptedTransport([(200, [
            #"data: {"choices":[{"delta":{"content":"a"}}],"auto_memory":true}"#,
            #"data: {"choices":[],"auto_memory":false}"#,
            "data: [DONE]",
        ])])
        let client = await makeClient(transport: transport)
        let events = try await collect(client)
        let sawAutoMemory = events.contains {
            if case .autoMemory = $0 { return true }
            return false
        }
        XCTAssertFalse(sawAutoMemory, "last chunk value wins, matching Sis")
    }

    func test401RefreshesOnceAndRetries() async throws {
        let refreshed = """
        {"access_token":"tok-2","refresh_token":"ref-2","expires_in":3600,"user_id":"owner-abc"}
        """
        let post = ScriptedPost([(200, signInBody), (200, refreshed)])
        let transport = ScriptedTransport([
            (401, []),
            (200, [#"data: {"choices":[{"delta":{"content":"ok"}}]}"#, "data: [DONE]"]),
        ])
        let client = await makeClient(transport: transport, post: post)
        let events = try await collect(client)

        XCTAssertEqual(transport.openedRequests.count, 2)
        XCTAssertEqual(
            transport.openedRequests[1].value(forHTTPHeaderField: "Authorization"),
            "Bearer tok-2")
        var text = ""
        for case .token(let token) in events { text += token }
        XCTAssertEqual(text, "ok")
    }

    func testNon200Throws() async {
        let transport = ScriptedTransport([(502, [])])
        let client = await makeClient(transport: transport)
        do {
            _ = try await collect(client)
            XCTFail("should throw")
        } catch let error as SeerChatError {
            guard case .http(502) = error else {
                return XCTFail("wrong error \(error)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// Auth dies with the owner id already known (signed in once, token now
    /// unrecoverable): the `.scoped` trace must lead and THEN the throw
    /// follows, so the exchange row reads "asked, nothing back" rather than
    /// "no retrieval asked".
    func testUnauthenticatedRunYieldsScopedThenThrows() async {
        // Signed in once (owner id minted), token already expired, and every
        // refresh / re-sign-in from here on fails (script exhausted → 599).
        let expiredBody = """
        {"access_token":"tok-1","refresh_token":"ref-1","expires_in":0,"user_id":"OWNER-ABC"}
        """
        let post = ScriptedPost([(200, expiredBody)])
        let transport = ScriptedTransport([])
        let client = await makeClient(transport: transport, post: post)

        var events: [SeerChatEvent] = []
        do {
            let stream = client.stream(
                messages: [SeerChatMessage(role: "user", content: "hi")],
                instructions: nil)
            for try await event in stream { events.append(event) }
            XCTFail("expected notAuthenticated")
        } catch let error as SeerChatError {
            guard case .notAuthenticated = error else {
                return XCTFail("wrong error \(error)")
            }
        } catch {
            return XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(events.count, 1)
        guard case .scoped(let request)? = events.first else {
            return XCTFail("the scope trace precedes the auth throw")
        }
        XCTAssertEqual(request.ownerID, "owner-abc")
        XCTAssertEqual(request.transport, .sse)
        XCTAssertTrue(transport.openedRequests.isEmpty, "nothing went on the wire")
    }

    func testRequestBodyShape() async throws {
        let transport = ScriptedTransport([(200, ["data: [DONE]"])])
        let client = await makeClient(transport: transport)
        _ = try await collect(client)

        let request = transport.openedRequests[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-1")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["max_tokens"] as? Int, 1200)
        XCTAssertEqual(json["instructions"] as? String, "be brief")
        // Identifies Mary so the server applies SUPPORT framing to retrieved
        // context; rides the realtime turn.start too (same ChatRequest).
        XCTAssertEqual(json["client"] as? String, "mary")
        let seer = try XCTUnwrap(json["seer"] as? [String: Any])
        XCTAssertEqual(seer["owner_id"] as? String, "owner-abc")
        XCTAssertEqual(seer["scope"] as? String, "personal")
        XCTAssertEqual(seer["personal_totem_id"] as? String, "totem-1")
        XCTAssertNotNil(seer["request_id"])
        // Unscoped turn = today's shape, byte for byte: aggregate true (it
        // used to be hardcoded), and NO groups key at all, so an old server
        // and a new one see the identical request.
        XCTAssertEqual(seer["aggregate"] as? Bool, true)
        XCTAssertNil(seer["groups"], "no document in view → no group filter")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, "hi")
    }

    /// The scoped case, matched against seer-server's `SeerRequest`: `groups`
    /// decodes as `[Seer.Group]` OBJECTS whose `id`/`label`/`owner_id` are
    /// REQUIRED, and `aggregate: false` is what makes the group filter
    /// exclusive rather than additive. Sending bare strings here would throw
    /// inside the server's decoder and fail the whole request — this pin is
    /// the only thing standing between that and a silent outage.
    func testRequestBodyShapeWhenADocumentIsFocused() async throws {
        let transport = ScriptedTransport([(200, ["data: [DONE]"])])
        let client = await makeClient(transport: transport)
        await client.configure(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            personalTotemID: "totem-1",
            retrievalScope: { owner in
                DepositSubject(app: "pages", documentIdentity: "Essay.pages")
                    .retrievalScope(ownerID: owner)
            })
        _ = try await collect(client)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(transport.openedRequests[0].httpBody)) as? [String: Any])
        let seer = try XCTUnwrap(json["seer"] as? [String: Any])
        XCTAssertEqual(seer["aggregate"] as? Bool, false,
                       "false = search ONLY these groups, per Seer's own doc comment")
        let groups = try XCTUnwrap(seer["groups"] as? [[String: Any]])
        // FOUR groups, not one. Sending the scope group alone with
        // aggregate:false made Seer's own long-term memory unreachable on
        // every focused turn — and focused is the NORMAL state. The document
        // group leads; memory, resonance and the legacy owner-wide pool ride
        // along as background. The pool is where every EYELESS deposit lands
        // (a calendar or reminders action has no workspace to file under), so
        // dropping it made the user's schedule unreachable whenever a document
        // happened to be open.
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups.map { $0["id"] as? String }.dropFirst(),
                       ["memory-owner-abc", "resonance-owner-abc", "mary-context-owner-abc"],
                       "verbatim server ids: Seer+AutoMemory.swift / Realtime.swift")
        for group in groups {
            XCTAssertEqual(group["owner_id"] as? String, "owner-abc")
        }
        XCTAssertEqual(groups[0]["label"] as? String, "Pages — Essay.pages")
        let id = try XCTUnwrap(groups[0]["id"] as? String)
        XCTAssertTrue(id.hasPrefix("mary-scope-"), "got \(id)")
        // Deposit and retrieval must name the SAME group — the whole scheme
        // is silent if they don't, because nothing errors, results just stop.
        XCTAssertEqual(
            id,
            DepositSubject(app: "pages", documentIdentity: "Essay.pages")
                .groupID(ownerID: "owner-abc"))
    }

    /// The `.scoped` trace and the encoded body come from ONE `SeerWire.scope`
    /// value — the hoist in `run` — so the first yielded event must equal the
    /// wire's own `seer` object field for field. A trace minted separately
    /// could drift from the bytes and explain nothing.
    func testFirstEventIsScopedAndEqualsTheEncodedBodyScope() async throws {
        let transport = ScriptedTransport([(200, ["data: [DONE]"])])
        let client = await makeClient(transport: transport)
        await client.configure(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            personalTotemID: "totem-1",
            retrievalScope: { owner in
                DepositSubject(app: "pages", documentIdentity: "Essay.pages")
                    .retrievalScope(ownerID: owner)
            })
        let events = try await collect(client)

        guard case .scoped(let request)? = events.first else {
            return XCTFail("the scope trace must lead the stream, before any token")
        }
        XCTAssertEqual(request.transport, .sse)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(transport.openedRequests[0].httpBody)) as? [String: Any])
        let seer = try XCTUnwrap(json["seer"] as? [String: Any])
        XCTAssertEqual(request.id, seer["request_id"] as? String)
        XCTAssertEqual(request.ownerID, seer["owner_id"] as? String)
        XCTAssertEqual(request.aggregate, seer["aggregate"] as? Bool)
        XCTAssertEqual(request.personalTotemID, seer["personal_totem_id"] as? String)
        let bodyGroups = try XCTUnwrap(seer["groups"] as? [[String: Any]])
        XCTAssertEqual(request.groups.map(\.id), bodyGroups.map { $0["id"] as? String ?? "" })
        XCTAssertEqual(request.groups.map(\.label), bodyGroups.map { $0["label"] as? String ?? "" })
        XCTAssertNil(seer["entities"], "no hints in this scope → none on the wire")
        XCTAssertEqual(request.relationshipHints, [])
    }

    func testContributionJSONRoundTrip() throws {
        let contribution = SeerContribution(
            owners: [SeerContribution.Owner(
                totemID: "t1", ownerID: "o1",
                documentIDs: ["d1"], influence: ["d1": 0.5],
                royalty: 0.8, spans: [.init(lower: 2, upper: 9)])],
            totalCost: 1.5)
        let json = try XCTUnwrap(contribution.jsonString)
        let decoded = try XCTUnwrap(SeerContribution.fromJSON(json))
        XCTAssertEqual(decoded, contribution)
        XCTAssertEqual(decoded.owners.first?.spans, [SeerContribution.TextSpan(lower: 2, upper: 9)])
    }

    func testTextSpanClamping() {
        let text = "Hello"
        XCTAssertNil(SeerContribution.TextSpan(lower: -1, upper: 3).range(in: text))
        XCTAssertNil(SeerContribution.TextSpan(lower: 3, upper: 3).range(in: text))
        XCTAssertNil(SeerContribution.TextSpan(lower: 9, upper: 12).range(in: text))
        let clamped = SeerContribution.TextSpan(lower: 2, upper: 99).range(in: text)
        XCTAssertEqual(clamped.map { String(text[$0]) }, "llo")
        let exact = SeerContribution.TextSpan(lower: 0, upper: 5).range(in: text)
        XCTAssertEqual(exact.map { String(text[$0]) }, "Hello")
    }
}
