//
//  SeerCompleteClient.swift
//  MaryBrain
//
//  WHAT: One bounded generation through `/v1/complete`.
//  IN:   SeerUnitAnnotator (JSON object, nothing else)
//  OUT:  parsed object
//  PIN:  Not a voice lane — chat always wraps persona/RAG/Gita.
//
import Foundation

/// Injectable POST seam, the non-streaming sibling of `SeerSSETransport`.
public protocol SeerCompleteTransport: Sendable {
    func post(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

public enum SeerCompleteError: LocalizedError, Equatable {
    case notAuthenticated
    case http(Int)
    case unreachable(String)
    case emptyReply

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in to Seer."
        case .http(let status): return "Seer complete failed (\(status))."
        case .unreachable(let reason): return "Seer is unreachable: \(reason)"
        case .emptyReply: return "Seer complete returned no text."
        }
    }
}

/// The annotator's seam onto `/v1/complete`. Tests script it; the app wires
/// `SeerCompleteClient`. Spoken turns must not reuse this protocol.
public protocol SeerCompleteProviding: Sendable {
    func isReady() async -> Bool
    /// `maxTokens` DEFAULTS TO THE ANNOTATOR'S BUDGET, and is a parameter
    /// because this seam is a process-wide singleton with two callers. A
    /// constant raised for the drafter would silently raise it for every unit
    /// in a corpus pass; a caller that needs a whole recipe says so here.
    func complete(
        instructions: String?,
        messages: [SeerChatMessage],
        maxTokens: Int
    ) async throws -> String
}

extension SeerCompleteProviding {
    public func complete(
        instructions: String?,
        messages: [SeerChatMessage]
    ) async throws -> String {
        try await complete(
            instructions: instructions,
            messages: messages,
            maxTokens: SeerCompleteBudget.annotation)
    }
}

/// What each caller of `/v1/complete` needs to finish its answer.
public enum SeerCompleteBudget {
    /// One precis and a handful of labels.
    public static let annotation = 256
    /// A whole recipe: title, summary, inputs and up to eight blocks. Seer
    /// clamps at 2048; the headroom is deliberate, because a reply cut off
    /// mid-object reaches the caller as unparsable rather than as short.
    public static let recipe = 1500
}

public actor SeerCompleteClient: SeerCompleteProviding {

    private var baseURL: URL
    private let session: SeerSession
    private let transport: any SeerCompleteTransport

    public init(
        baseURL: URL,
        session: SeerSession,
        transport: any SeerCompleteTransport = URLSessionCompleteTransport()
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
        maxTokens: Int = SeerCompleteBudget.annotation
    ) async throws -> String {
        guard var token = await session.validToken() else {
            throw SeerCompleteError.notAuthenticated
        }

        let body = try JSONEncoder().encode(SeerWire.CompleteRequest(
            instructions: instructions,
            messages: messages,
            maxTokens: maxTokens,
            temperature: 0))

        var attempt = try await open(body: body, bearer: token)
        if attempt.status == 401 {
            guard let fresh = await session.refreshAfter401() else {
                throw SeerCompleteError.notAuthenticated
            }
            token = fresh
            attempt = try await open(body: body, bearer: token)
        }
        guard attempt.status == 200 else {
            throw SeerCompleteError.http(attempt.status)
        }
        guard let response = try? JSONDecoder().decode(
                SeerWire.CompleteResponse.self, from: attempt.body),
              !response.text.isEmpty else {
            throw SeerCompleteError.emptyReply
        }
        return response.text
    }

    private func open(body: Data, bearer: String) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/complete"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        do {
            return try await transport.post(request)
        } catch let error as SeerCompleteError {
            throw error
        } catch {
            throw SeerCompleteError.unreachable(error.localizedDescription)
        }
    }
}

// MARK: - URLSession transport

public struct URLSessionCompleteTransport: SeerCompleteTransport {
    /// A small dedicated session — never `URLSession.shared` (its resource timeout is seven days) and deliberately not `StreamingHTTP.session` (a complete hanging…
    /// PIN: A small dedicated session — never `URLSession.shared` (its resource timeout is seven days) and deliberately not…
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
