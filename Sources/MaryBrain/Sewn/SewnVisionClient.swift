//
//  SewnVisionClient.swift
//  MaryBrain
//
//  WHAT: One bounded look through Sewn's vision route.
//  IN:   ScreenLookFaculty (base64 screenshot)
//  OUT:  JSON description
//  PIN:  No local fallback; every failure is a typed error.
//
import Foundation

/// Injectable POST seam, the non-streaming sibling of `SewnSSETransport`.
public protocol SewnVisionTransport: Sendable {
    func post(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

public enum SewnVisionError: LocalizedError, Equatable {
    case notAuthenticated
    case http(Int)
    case unreachable(String)
    case emptyDescription

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in to Sewn."
        case .http(let status): return "Sewn vision failed (\(status))."
        case .unreachable(let reason): return "Sewn is unreachable: \(reason)"
        case .emptyDescription: return "Sewn vision returned no description."
        }
    }
}

public actor SewnVisionClient {

    private var baseURL: URL
    private let session: SewnSession
    private let transport: any SewnVisionTransport

    public init(
        baseURL: URL,
        session: SewnSession,
        transport: any SewnVisionTransport = URLSessionVisionTransport()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.transport = transport
    }

    public func configure(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Describe one captured image. `appTitle`/`windowTitle` become the
    /// route's context line; `query` rides as the user's direction. The
    /// image bytes exist only for the duration of this call.
    public func describe(
        imageData: Data,
        mediaType: String,
        appTitle: String,
        windowTitle: String?,
        query: String?
    ) async throws -> String {
        guard var token = await session.validToken() else {
            throw SewnVisionError.notAuthenticated
        }

        let title = windowTitle.map { "\(appTitle) — \($0)" } ?? appTitle
        let body = try JSONEncoder().encode(SewnWire.VisionLookRequest(
            image: imageData.base64EncodedString(),
            mediaType: mediaType,
            mode: "describe",
            pageTitle: title,
            pageText: nil,
            direction: query))

        var attempt = try await open(body: body, bearer: token)
        if attempt.status == 401 {
            guard let fresh = await session.refreshAfter401() else {
                throw SewnVisionError.notAuthenticated
            }
            token = fresh
            attempt = try await open(body: body, bearer: token)
        }
        guard attempt.status == 200 else {
            throw SewnVisionError.http(attempt.status)
        }
        guard let response = try? JSONDecoder().decode(
                SewnWire.VisionLookResponse.self, from: attempt.body),
              !response.text.isEmpty else {
            throw SewnVisionError.emptyDescription
        }
        return response.text
    }

    private func open(body: Data, bearer: String) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/vision/look"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        do {
            return try await transport.post(request)
        } catch let error as SewnVisionError {
            throw error
        } catch {
            throw SewnVisionError.unreachable(error.localizedDescription)
        }
    }
}

// MARK: - URLSession transport

public struct URLSessionVisionTransport: SewnVisionTransport {
    /// A small dedicated session — never `URLSession.shared` (its resource timeout is seven days) and deliberately not `StreamingHTTP.session` (a describe hanging…
    /// PIN: A small dedicated session — never `URLSession.shared` (its resource timeout is seven days) and deliberately not…
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    public init() {}

    public func post(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await Self.session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
