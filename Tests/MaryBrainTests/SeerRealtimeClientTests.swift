//
//  SeerRealtimeClientTests.swift
//  MaryBrainTests
//
//  Frame→event mapping, PCM alignment, and the failure contract of the
//  realtime WebSocket client over a scripted transport — no live server.
//

import XCTest
@testable import MaryBrain
@testable import MaryAdapters
@testable import MaryAmbient

// MARK: - Scripted seams

private final class ScriptedWS: SeerWSTransport, @unchecked Sendable {
    struct Script {
        var frames: [SeerWSFrame] = []
        var streamError: Error?
        var connectError: Error?
    }

    private let lock = NSLock()
    private var scripts: [Script]
    private(set) var sent: [SeerWSFrame] = []
    private(set) var closed = false
    private(set) var connects = 0

    init(_ scripts: [Script]) {
        self.scripts = scripts
    }

    func connect(_ request: URLRequest) async throws -> SeerWSConnection {
        lock.lock()
        connects += 1
        let script = scripts.isEmpty ? Script() : scripts.removeFirst()
        lock.unlock()
        if let error = script.connectError { throw error }
        let frames = AsyncThrowingStream<SeerWSFrame, Error> { continuation in
            for frame in script.frames { continuation.yield(frame) }
            if let error = script.streamError {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
        return SeerWSConnection(
            frames: frames,
            send: { [weak self] frame in
                guard let self else { return }
                self.lock.lock()
                self.sent.append(frame)
                self.lock.unlock()
            },
            close: { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.closed = true
                self.lock.unlock()
            }
        )
    }
}

private final class ScriptedPost: @unchecked Sendable {
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

private let signInBody = """
{"access_token":"tok-1","refresh_token":"ref-1","expires_in":3600,"user_id":"OWNER-ABC"}
"""

private func makeClient(_ ws: ScriptedWS) async -> SeerRealtimeClient {
    let post = ScriptedPost([(200, signInBody)])
    let session = SeerSession(
        baseURL: URL(string: "http://127.0.0.1:8080")!,
        email: "a@b.c", password: "pw",
        post: { try await post.post($0) }
    )
    _ = await session.signIn()
    return SeerRealtimeClient(
        baseURL: URL(string: "http://127.0.0.1:8080")!,
        session: session,
        transport: ws
    )
}

private func pcmFrame(_ bytes: [UInt8]) -> SeerWSFrame {
    .data(Data(bytes))
}

private func collect(_ client: SeerRealtimeClient) async throws -> [SeerChatEvent] {
    var events: [SeerChatEvent] = []
    for try await event in client.streamTurn(
        messages: [SeerChatMessage(role: "user", content: "hello there")],
        instructions: "be brief"
    ) {
        events.append(event)
    }
    return events
}

// MARK: - Tests

final class SeerRealtimeClientTests: XCTestCase {

    func testSendsTurnStartEmbeddingChatRequestAndVoice() async throws {
        let ws = ScriptedWS([.init(frames: [.text(#"{"type":"turn.end"}"#)])])
        let client = await makeClient(ws)
        await client.configure(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            personalTotemID: "totem-1",
            chatModel: "",
            voiceID: "fr_marie_calm"
        )
        _ = try await collect(client)

        XCTAssertEqual(ws.sent.count, 1)
        guard case .text(let json) = ws.sent[0] else { return XCTFail("expected text frame") }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "turn.start")
        let tts = try XCTUnwrap(object["tts"] as? [String: Any])
        XCTAssertEqual(tts["voice_id"] as? String, "fr_marie_calm")
        let request = try XCTUnwrap(object["request"] as? [String: Any])
        XCTAssertNil(request["model"])   // empty chatModel omits the field
        XCTAssertEqual(request["stream"] as? Bool, true)
        let seer = try XCTUnwrap(request["seer"] as? [String: Any])
        XCTAssertEqual(seer["personal_totem_id"] as? String, "totem-1")
        XCTAssertEqual(seer["owner_id"] as? String, "owner-abc")
        XCTAssertEqual(seer["aggregate"] as? Bool, true)
        XCTAssertNil(seer["groups"], "nothing focused → today's request, unchanged")
        let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "hello there")
    }

    /// The realtime lane wraps the IDENTICAL ChatRequest, so scoping has to
    /// ride here too. Pinned separately because the failure mode is
    /// invisible: flip Settings to realtime and retrieval silently widens
    /// back to owner-wide.
    func testTurnStartCarriesTheFocusedDocumentScope() async throws {
        let ws = ScriptedWS([.init(frames: [.text(#"{"type":"turn.end"}"#)])])
        let client = await makeClient(ws)
        await client.configure(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            personalTotemID: "totem-1",
            retrievalScope: { owner in
                DepositSubject(
                    app: "xcode",
                    documentIdentity: "/Users/r/Mary/Sources/main.swift",
                    projectIdentity: "/Users/r/Mary"
                ).retrievalScope(ownerID: owner)
            })
        _ = try await collect(client)

        guard case .text(let json) = ws.sent[0] else { return XCTFail("expected text frame") }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let request = try XCTUnwrap(object["request"] as? [String: Any])
        let seer = try XCTUnwrap(request["seer"] as? [String: Any])
        XCTAssertEqual(seer["aggregate"] as? Bool, false)
        let groups = try XCTUnwrap(seer["groups"] as? [[String: Any]])
        XCTAssertEqual(groups[0]["label"] as? String, "Xcode — Mary",
                       "a coding turn scopes to the PROJECT, not the one file")
        XCTAssertEqual(groups[0]["owner_id"] as? String, "owner-abc")
        // The memory groups ride BOTH transports. Scoping the SSE lane to the
        // document alone blacked out long-term memory; fixing it there and
        // not here would present as "memory works until I switch transports
        // in Settings" — a bug with no visible cause.
        // Four now — the legacy owner-wide pool joins them, because every
        // EYELESS deposit lands there and excluding it made a focused turn
        // unable to recall anything about the user's calendar or mail.
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups.map { $0["id"] as? String }.dropFirst(),
                       ["memory-owner-abc", "resonance-owner-abc", "mary-context-owner-abc"])
    }

    /// The realtime twin of the SSE scope pin: the `.scoped` trace and the
    /// turn.start's embedded request come from ONE `SeerWire.scope` value, so
    /// the first yielded event must equal the sent frame's `seer` object.
    func testFirstEventIsScopedAndEqualsTheSentTurnStartScope() async throws {
        let ws = ScriptedWS([.init(frames: [.text(#"{"type":"turn.end"}"#)])])
        let client = await makeClient(ws)
        await client.configure(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            personalTotemID: "totem-1",
            retrievalScope: { owner in
                DepositSubject(
                    app: "xcode",
                    documentIdentity: "/Users/r/Mary/Sources/main.swift",
                    projectIdentity: "/Users/r/Mary"
                ).retrievalScope(ownerID: owner)
            })
        let events = try await collect(client)

        guard case .scoped(let request)? = events.first else {
            return XCTFail("the scope trace must lead the stream, before any frame")
        }
        XCTAssertEqual(request.transport, .realtime)

        guard case .text(let json) = ws.sent[0] else { return XCTFail("expected text frame") }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let wire = try XCTUnwrap(object["request"] as? [String: Any])
        let seer = try XCTUnwrap(wire["seer"] as? [String: Any])
        XCTAssertEqual(request.id, seer["request_id"] as? String)
        XCTAssertEqual(request.ownerID, seer["owner_id"] as? String)
        XCTAssertEqual(request.aggregate, seer["aggregate"] as? Bool)
        XCTAssertEqual(request.personalTotemID, seer["personal_totem_id"] as? String)
        let bodyGroups = try XCTUnwrap(seer["groups"] as? [[String: Any]])
        XCTAssertEqual(request.groups.map(\.id), bodyGroups.map { $0["id"] as? String ?? "" })
        XCTAssertEqual(request.groups.map(\.label), bodyGroups.map { $0["label"] as? String ?? "" })
    }

    func testFrameToEventMappingAndCleanEnd() async throws {
        let contributionJSON = #"{"owners":[{"totem_id":"t1","owner_id":"o1","spans":[{"lower":0,"upper":4}]}]}"#
        let ws = ScriptedWS([.init(frames: [
            .text(#"{"type":"phase","phase":"opening"}"#),
            .text(#"{"type":"token","phase":"opening","text":"Hi "}"#),
            .text(#"{"type":"audio.begin","sample_rate":24000,"channels":1,"bits":32,"encoding":"f32le"}"#),
            pcmFrame([0, 0, 0, 0]),
            .text(#"{"type":"phase","phase":"grounded"}"#),
            .text(#"{"type":"token","phase":"grounded","text":"there."}"#),
            .text(#"{"type":"metadata","chunk":{"choices":[],"contribution":\#(contributionJSON),"auto_memory":true}}"#),
            .text(#"{"type":"turn.end"}"#),
        ])])
        let client = await makeClient(ws)
        let events = try await collect(client)

        var tokens = ""
        var phases: [String] = []
        var audioChunks: [(Int, Double)] = []
        var sawContribution = false
        var sawAutoMemory = false
        for event in events {
            switch event {
            case .token(let text): tokens += text
            case .phase(let phase): phases.append(phase)
            case .audio(let pcm, let rate): audioChunks.append((pcm.count, rate))
            case .contribution: sawContribution = true
            case .autoMemory(let flag): sawAutoMemory = sawAutoMemory || flag
            case .scoped: break   // every turn leads with its scope trace
            case .ttsFailed: XCTFail("unexpected ttsFailed")
            }
        }
        XCTAssertEqual(tokens, "Hi there.")
        XCTAssertEqual(phases, ["opening", "grounded"])
        XCTAssertEqual(audioChunks.count, 1)
        XCTAssertEqual(audioChunks[0].0, 4)
        XCTAssertEqual(audioChunks[0].1, 24_000)
        XCTAssertTrue(sawContribution)
        XCTAssertTrue(sawAutoMemory)
        XCTAssertTrue(ws.closed)   // turn.end closes promptly
    }

    func testPCMAlignmentCarriesRemainderAcrossFrames() async throws {
        let ws = ScriptedWS([.init(frames: [
            .text(#"{"type":"token","text":"x"}"#),
            pcmFrame([1, 2, 3, 4, 5, 6]),     // 6 bytes → one float out, 2 held
            pcmFrame([7, 8]),                 // completes the held float
            .text(#"{"type":"turn.end"}"#),
        ])])
        let client = await makeClient(ws)
        let events = try await collect(client)

        let sizes = events.compactMap { event -> Int? in
            if case .audio(let pcm, _) = event { return pcm.count }
            return nil
        }
        XCTAssertEqual(sizes, [4, 4])
        // Byte order preserved across the remainder splice.
        var bytes: [UInt8] = []
        for event in events {
            if case .audio(let pcm, _) = event { bytes.append(contentsOf: pcm) }
        }
        XCTAssertEqual(bytes, [1, 2, 3, 4, 5, 6, 7, 8])
    }

    func testAudioBeginOverridesSampleRate() async throws {
        let ws = ScriptedWS([.init(frames: [
            .text(#"{"type":"audio.begin","sample_rate":22050,"channels":1,"bits":32,"encoding":"f32le"}"#),
            pcmFrame([0, 0, 0, 0]),
            .text(#"{"type":"turn.end"}"#),
        ])])
        let client = await makeClient(ws)
        let events = try await collect(client)
        guard case .audio(_, let rate)? = events.first(where: {
            if case .audio = $0 { return true }
            return false
        }) else { return XCTFail("no audio event") }
        XCTAssertEqual(rate, 22_050)
    }

    func testStreamEndWithoutTurnEndThrowsDisconnected() async {
        let ws = ScriptedWS([.init(frames: [
            .text(#"{"type":"token","text":"partial"}"#),
        ])])
        let client = await makeClient(ws)
        do {
            _ = try await collect(client)
            XCTFail("expected throw")
        } catch let error as SeerRealtimeError {
            guard case .disconnected = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// The realtime twin of the SSE auth-order pin: with the owner id known
    /// but the token unrecoverable, `.scoped` leads and THEN the throw
    /// follows — the exchange row reads "asked, nothing back", and the
    /// brain's pre-stream fallback still sees a clean pre-content failure.
    func testUnauthenticatedTurnYieldsScopedThenThrows() async {
        // Signed in once (owner id minted), token already expired, and every
        // refresh / re-sign-in from here on fails (script exhausted → 599).
        let expiredBody = """
        {"access_token":"tok-1","refresh_token":"ref-1","expires_in":0,"user_id":"OWNER-ABC"}
        """
        let post = ScriptedPost([(200, expiredBody)])
        let session = SeerSession(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            email: "a@b.c", password: "pw",
            post: { try await post.post($0) }
        )
        _ = await session.signIn()
        let ws = ScriptedWS([])
        let client = SeerRealtimeClient(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            session: session,
            transport: ws
        )

        var events: [SeerChatEvent] = []
        do {
            for try await event in client.streamTurn(
                messages: [SeerChatMessage(role: "user", content: "hi")],
                instructions: nil
            ) {
                events.append(event)
            }
            XCTFail("expected notAuthenticated")
        } catch let error as SeerRealtimeError {
            guard case .notAuthenticated = error else {
                return XCTFail("wrong error: \(error)")
            }
        } catch {
            return XCTFail("unexpected error type: \(error)")
        }
        XCTAssertEqual(events.count, 1)
        guard case .scoped(let request)? = events.first else {
            return XCTFail("the scope trace precedes the auth throw")
        }
        XCTAssertEqual(request.ownerID, "owner-abc")
        XCTAssertEqual(request.transport, .realtime)
        XCTAssertEqual(ws.connects, 0, "no connection was attempted")
    }

    func testPreTokenErrorFrameThrows() async {
        let ws = ScriptedWS([.init(frames: [
            .text(#"{"type":"error","stage":"request","message":"bad"}"#),
        ])])
        let client = await makeClient(ws)
        do {
            _ = try await collect(client)
            XCTFail("expected throw")
        } catch let error as SeerRealtimeError {
            guard case .server = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testPostTokenErrorFrameIsToleratedThroughTurnEnd() async throws {
        let ws = ScriptedWS([.init(frames: [
            .text(#"{"type":"token","text":"Opening spoke. "}"#),
            .text(#"{"type":"error","stage":"grounded","message":"model died"}"#),
            .text(#"{"type":"turn.end"}"#),
        ])])
        let client = await makeClient(ws)
        let events = try await collect(client)
        var tokens = ""
        for event in events {
            if case .token(let text) = event { tokens += text }
        }
        XCTAssertEqual(tokens, "Opening spoke. ")
    }

    func testTTSFailedFrameForwarded() async throws {
        let ws = ScriptedWS([.init(frames: [
            .text(#"{"type":"token","text":"A"}"#),
            .text(#"{"type":"tts.failed"}"#),
            .text(#"{"type":"turn.end"}"#),
        ])])
        let client = await makeClient(ws)
        let events = try await collect(client)
        XCTAssertTrue(events.contains {
            if case .ttsFailed = $0 { return true }
            return false
        })
    }
}
