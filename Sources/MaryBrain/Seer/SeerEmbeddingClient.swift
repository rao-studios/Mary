//
//  SeerEmbeddingClient.swift
//  MaryBrain
//
//  WHAT: Vectors from `/v1/embed` — the tier under Apple's on-device model.
//  IN:   MaryEmbeddings, when no local vectorizer exists
//  OUT:  [[Float]], in input order, stamped with the model that made them
//  PIN:  ORDER IS THE CONTRACT. Callers match vectors to texts by position.
//        A short or reordered reply is a hard failure here rather than a
//        silent one-off that maps every later text to the wrong vector.
//
import Foundation

/// Injectable POST seam, sibling of `SeerCompleteTransport`.
public protocol SeerEmbeddingTransport: Sendable {
    func post(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

public enum SeerEmbeddingError: LocalizedError, Equatable {
    case notAuthenticated
    case http(Int)
    case unreachable(String)
    case undecodable
    /// The vendor answered with a different number of vectors than texts sent.
    case countMismatch(sent: Int, returned: Int)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in to Seer."
        case .http(let status): return "Seer embed failed (\(status))."
        case .unreachable(let reason): return "Seer is unreachable: \(reason)"
        case .undecodable: return "Seer embed returned an unreadable body."
        case .countMismatch(let sent, let returned):
            return "Seer embed returned \(returned) vectors for \(sent) texts."
        }
    }
}

/// What a batch of text came back as, and what made it.
public struct EmbeddedBatch: Sendable, Equatable {
    /// One vector per input, in input order.
    public var vectors: [[Float]]
    /// The model that produced them. STAMPED, NOT ASSUMED: vectors from two
    /// models share no space, and `AmbientVectorMath.dot` reports a dimension
    /// mismatch as −1 — a silent "no match" rather than an error.
    public var model: String

    public init(vectors: [[Float]], model: String) {
        self.vectors = vectors
        self.model = model
    }
}

/// The embedding seam. Tests script it; the app wires `SeerEmbeddingClient`.
public protocol SeerEmbeddingProviding: Sendable {
    func isReady() async -> Bool
    func embed(_ texts: [String]) async throws -> EmbeddedBatch
}

public actor SeerEmbeddingClient: SeerEmbeddingProviding {

    /// Mistral rejects batches larger than this, and Seer's own provider caps
    /// at the same number — chunk here so a corpus warm-up of several hundred
    /// sentences is one caller concern rather than a vendor error.
    public static let maximumBatch = 256

    private var baseURL: URL
    private var model: String?
    private let session: SeerSession
    private let transport: any SeerEmbeddingTransport

    public init(
        baseURL: URL,
        session: SeerSession,
        model: String? = nil,
        transport: any SeerEmbeddingTransport = URLSessionEmbeddingTransport()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.model = model
        self.transport = transport
    }

    public func configure(baseURL: URL, model: String? = nil) {
        self.baseURL = baseURL
        if let model, !model.isEmpty { self.model = model }
    }

    public func isReady() async -> Bool {
        await session.isAuthenticated
    }

    public func embed(_ texts: [String]) async throws -> EmbeddedBatch {
        guard !texts.isEmpty else { return EmbeddedBatch(vectors: [], model: model ?? "") }
        var vectors: [[Float]] = []
        var producedBy = model ?? ""
        for chunk in stride(from: 0, to: texts.count, by: Self.maximumBatch).map({
            Array(texts[$0..<min($0 + Self.maximumBatch, texts.count)])
        }) {
            let batch = try await embedOneBatch(chunk)
            vectors += batch.vectors
            producedBy = batch.model
        }
        return EmbeddedBatch(vectors: vectors, model: producedBy)
    }

    private func embedOneBatch(_ texts: [String]) async throws -> EmbeddedBatch {
        guard var token = await session.validToken() else {
            throw SeerEmbeddingError.notAuthenticated
        }
        let body = try JSONEncoder().encode(
            SeerWire.EmbedRequest(inputs: texts, model: model))

        var attempt = try await open(body: body, bearer: token)
        if attempt.status == 401 {
            guard let fresh = await session.refreshAfter401() else {
                throw SeerEmbeddingError.notAuthenticated
            }
            token = fresh
            attempt = try await open(body: body, bearer: token)
        }
        guard attempt.status == 200 else {
            throw SeerEmbeddingError.http(attempt.status)
        }
        guard let response = try? JSONDecoder().decode(
            SeerWire.EmbedResponse.self, from: attempt.body)
        else { throw SeerEmbeddingError.undecodable }

        // POSITION IS MEANING. Sort by the vendor's own index and demand one
        // vector per text; anything else would quietly pair the wrong sentence
        // with the wrong vector for the life of the index built from it.
        let ordered = response.data.sorted { $0.index < $1.index }
        guard ordered.count == texts.count else {
            throw SeerEmbeddingError.countMismatch(
                sent: texts.count, returned: ordered.count)
        }
        return EmbeddedBatch(
            vectors: ordered.map(\.embedding), model: response.model)
    }

    private func open(body: Data, bearer: String) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/embed"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        do {
            return try await transport.post(request)
        } catch let error as SeerEmbeddingError {
            throw error
        } catch {
            throw SeerEmbeddingError.unreachable(error.localizedDescription)
        }
    }
}

// MARK: - URLSession transport

public struct URLSessionEmbeddingTransport: SeerEmbeddingTransport {
    /// A small dedicated session — never `URLSession.shared`, whose resource
    /// timeout is seven days. A corpus warm-up is a handful of seconds; a turn
    /// query is well under one.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    public init() {}

    public func post(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await Self.session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
