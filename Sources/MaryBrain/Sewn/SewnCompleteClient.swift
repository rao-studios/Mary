//
//  SewnCompleteClient.swift
//  MaryBrain
//
//  WHAT: One bounded generation through `/v1/complete`.
//  IN:   SewnUnitAnnotator (JSON object, nothing else)
//  OUT:  parsed object
//  PIN:  Not a voice lane — chat always wraps persona/RAG/Gita.
//
import Foundation

/// Injectable POST seam, the non-streaming sibling of `SewnSSETransport`.
public protocol SewnCompleteTransport: Sendable {
    func post(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

public enum SewnCompleteError: LocalizedError, Equatable {
    case notAuthenticated
    case http(Int)
    case unreachable(String)
    case emptyReply

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in to Sewn."
        case .http(let status): return "Sewn complete failed (\(status))."
        case .unreachable(let reason): return "Sewn is unreachable: \(reason)"
        case .emptyReply: return "Sewn complete returned no text."
        }
    }
}

/// The annotator's seam onto `/v1/complete`. Tests script it; the app wires
/// `SewnCompleteClient`. Spoken turns must not reuse this protocol.
public protocol SewnCompleteProviding: Sendable {
    func isReady() async -> Bool
    /// `maxTokens` DEFAULTS TO THE ANNOTATOR'S BUDGET, and is a parameter
    /// because this seam is a process-wide singleton with two callers. A
    /// constant raised for the drafter would silently raise it for every unit
    /// in a corpus pass; a caller that needs a whole recipe says so here.
    func complete(
        instructions: String?,
        messages: [SewnChatMessage],
        maxTokens: Int
    ) async throws -> String
}

extension SewnCompleteProviding {
    public func complete(
        instructions: String?,
        messages: [SewnChatMessage]
    ) async throws -> String {
        try await complete(
            instructions: instructions,
            messages: messages,
            maxTokens: SewnCompleteBudget.annotation)
    }
}

/// What each caller of `/v1/complete` needs to finish its answer.
public enum SewnCompleteBudget {
    /// One precis and a handful of labels.
    public static let annotation = 256
    /// A whole recipe: title, summary, inputs and up to eight blocks. Sewn
    /// clamps at 2048; the headroom is deliberate, because a reply cut off
    /// mid-object reaches the caller as unparsable rather than as short.
    public static let recipe = 1500
    /// A feeling line and a shader of up to ninety lines. Under Sewn's clamp
    /// with room for the fence, because a shader cut off mid-function reaches
    /// the page as a compile error rather than as short.
    public static let shader = 2000
}

public actor SewnCompleteClient: SewnCompleteProviding {

    private var baseURL: URL
    private let session: SewnSession
    private let transport: any SewnCompleteTransport
    private var provider: LLMEngineChoice?

    public init(
        baseURL: URL,
        session: SewnSession,
        transport: any SewnCompleteTransport = URLSessionCompleteTransport()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.transport = transport
    }

    public func configure(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Which backend answers annotation and the Studio drafter. Separate from
    /// `configure` for the same reason as the other lanes.
    public func setProvider(_ provider: LLMEngineChoice?) {
        self.provider = provider
    }

    public func isReady() async -> Bool {
        await session.isAuthenticated
    }

    public func complete(
        instructions: String?,
        messages: [SewnChatMessage],
        maxTokens: Int = SewnCompleteBudget.annotation
    ) async throws -> String {
        guard var token = await session.validToken() else {
            throw SewnCompleteError.notAuthenticated
        }

        let body = try JSONEncoder().encode(SewnWire.CompleteRequest(
            instructions: instructions,
            messages: messages,
            maxTokens: maxTokens,
            temperature: 0,
            provider: provider))

        var attempt = try await open(body: body, bearer: token)
        if attempt.status == 401 {
            guard let fresh = await session.refreshAfter401() else {
                throw SewnCompleteError.notAuthenticated
            }
            token = fresh
            attempt = try await open(body: body, bearer: token)
        }
        guard attempt.status == 200 else {
            throw SewnCompleteError.http(attempt.status)
        }
        guard let response = try? JSONDecoder().decode(
                SewnWire.CompleteResponse.self, from: attempt.body),
              !response.text.isEmpty else {
            throw SewnCompleteError.emptyReply
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
        } catch let error as SewnCompleteError {
            throw error
        } catch {
            throw SewnCompleteError.unreachable(error.localizedDescription)
        }
    }
}

// MARK: - URLSession transport

public struct URLSessionCompleteTransport: SewnCompleteTransport {
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
