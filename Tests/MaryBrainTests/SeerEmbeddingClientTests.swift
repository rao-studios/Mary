//
//  SeerEmbeddingClientTests.swift
//  MaryBrainTests
//
//  WHAT: The `/v1/embed` contract, scripted — no server, no network.
//  PIN:  ORDER IS THE CLAIM. A vector is meaningless without knowing which
//        text made it, and a vendor that reorders or drops one would pair
//        every later sentence with the wrong vector — for the whole life of
//        the index built from them, reported by nothing.
//
import Foundation
import Testing
@testable import MaryBrain

@Suite struct SeerEmbeddingClientTests {

    @Test func vectorsComeBackInInputOrder() async throws {
        let client = Self.client(ScriptedTransport(status: 200, body: Self.body(
            model: "mistral-embed",
            // Deliberately out of order on the wire.
            vectors: [(2, [0, 0, 1]), (0, [1, 0, 0]), (1, [0, 1, 0])])))

        let batch = try await client.embed(["first", "second", "third"])

        #expect(batch.vectors == [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
        #expect(batch.model == "mistral-embed", "stamped with what made them")
    }

    /// A SHORT REPLY IS A HARD FAILURE. Silently returning two vectors for
    /// three texts is the one outcome that corrupts an index without ever
    /// looking wrong.
    @Test func aMissingVectorIsAnError() async {
        let client = Self.client(ScriptedTransport(status: 200, body: Self.body(
            model: "mistral-embed", vectors: [(0, [1, 0]), (1, [0, 1])])))

        await #expect(throws: SeerEmbeddingError.countMismatch(sent: 3, returned: 2)) {
            try await client.embed(["first", "second", "third"])
        }
    }

    @Test func anEmptyRequestNeverLeavesTheProcess() async throws {
        let transport = ScriptedTransport(status: 500, body: Data())
        let client = Self.client(transport)

        let batch = try await client.embed([])

        #expect(batch.vectors.isEmpty)
        #expect(await transport.calls == 0, "nothing to embed is not a round trip")
    }

    @Test func anUnreadableBodyIsReported() async {
        let client = Self.client(ScriptedTransport(status: 200, body: Data("nonsense".utf8)))

        await #expect(throws: SeerEmbeddingError.undecodable) {
            try await client.embed(["first"])
        }
    }

    @Test func anErrorStatusIsReported() async {
        let client = Self.client(ScriptedTransport(status: 503, body: Data()))

        await #expect(throws: SeerEmbeddingError.http(503)) {
            try await client.embed(["first"])
        }
    }

    /// Larger corpora are chunked to the vendor's batch ceiling rather than
    /// refused — a warm-up is several hundred trigger sentences.
    @Test func aLargeCorpusIsChunked() async throws {
        let texts = (0..<(SeerEmbeddingClient.maximumBatch + 5)).map { "text \($0)" }
        let transport = ChunkEchoTransport()
        let client = Self.client(transport)

        let batch = try await client.embed(texts)

        #expect(batch.vectors.count == texts.count)
        #expect(await transport.calls == 2, "one over the ceiling means two round trips")
    }

    // MARK: - Fixture

    private static func client(_ transport: any SeerEmbeddingTransport) -> SeerEmbeddingClient {
        SeerEmbeddingClient(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            // A session that hands back a token without a network round trip.
            session: SeerSession(
                baseURL: URL(string: "http://127.0.0.1:8080")!,
                email: "t@t", password: "t",
                post: { _ in
                    let json = #"{"access_token":"t","refresh_token":"r","expires_in":3600,"user_id":"u"}"#
                    return (Data(json.utf8), 200)
                }),
            transport: transport)
    }

    private static func body(model: String, vectors: [(Int, [Float])]) -> Data {
        let data = vectors.map { pair -> String in
            let floats: [String] = pair.1.map { String($0) }
            return #"{"index":\#(pair.0),"embedding":[\#(floats.joined(separator: ","))]}"#
        }
        let json = #"{"object":"list","model":"\#(model)","dimensions":3,"data":[\#(data.joined(separator: ","))]}"#
        return Data(json.utf8)
    }

    private actor ScriptedTransport: SeerEmbeddingTransport {
        let status: Int
        let body: Data
        private(set) var calls = 0

        init(status: Int, body: Data) {
            self.status = status
            self.body = body
        }

        func post(_: URLRequest) async throws -> (status: Int, body: Data) {
            calls += 1
            return (status, body)
        }
    }

    /// Answers with one vector per input it was actually sent.
    private actor ChunkEchoTransport: SeerEmbeddingTransport {
        private(set) var calls = 0

        func post(_ request: URLRequest) async throws -> (status: Int, body: Data) {
            calls += 1
            struct Sent: Decodable { let inputs: [String] }
            let sent = try JSONDecoder().decode(Sent.self, from: request.httpBody ?? Data())
            let vectors = sent.inputs.indices.map { ($0, [Float(1)]) }
            return (200, SeerEmbeddingClientTests.body(model: "mistral-embed", vectors: vectors))
        }
    }
}
