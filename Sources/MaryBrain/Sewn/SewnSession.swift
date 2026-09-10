//
//  SewnSession.swift
//  MaryBrain
//
//  WHAT: Sewn account session — sign in, Bearer, refresh.
//  IN:   boot + 401 retry
//  OUT:  token to every Sewn client except Threads
//  PIN:  Tokens live only in this actor; never persisted.
//
import Foundation

public actor SewnSession {

    /// Injectable HTTP seam: (request) → (body, status). Tests script it.
    public typealias HTTPPost = @Sendable (URLRequest) async throws -> (Data, Int)

    private var baseURL: URL
    private var email: String
    private var password: String
    private let post: HTTPPost

    private var accessToken: String?
    private var refreshToken: String?
    private var expiresAt: Date?
    public private(set) var userID: String?

    public init(
        baseURL: URL,
        email: String,
        password: String,
        post: @escaping HTTPPost = SewnSession.urlSessionPost
    ) {
        self.baseURL = baseURL
        self.email = email
        self.password = password
        self.post = post
    }

    public var isAuthenticated: Bool {
        accessToken != nil && userID != nil
    }

    /// HOW LONG A FAILED SIGN-IN PARKS FURTHER ATTEMPTS.
    public static let signInCooldown: TimeInterval = 10
    private var signInCooldownUntil: Date?

    /// Account/server change from Settings — drops the session; the next
    /// token request signs in with the new credentials. New credentials also
    /// deserve a fresh attempt, so the cooldown clears.
    public func configure(baseURL: URL, email: String, password: String) {
        self.baseURL = baseURL
        self.email = email
        self.password = password
        accessToken = nil
        refreshToken = nil
        expiresAt = nil
        userID = nil
        signInCooldownUntil = nil
    }

    /// Signs in with the configured credentials. Returns error text or nil.
    @discardableResult
    public func signIn() async -> String? {
        do {
            let body = try JSONEncoder().encode(SewnWire.SignInRequest(email: email, password: password))
            let (data, status) = try await post(request(path: "v1/auth/sign-in", body: body, bearer: nil))
            guard status == 200 else {
                signInCooldownUntil = Date().addingTimeInterval(Self.signInCooldown)
                return "Sewn sign-in failed (\(status))."
            }
            apply(try JSONDecoder().decode(SewnWire.SessionResponse.self, from: data))
            signInCooldownUntil = nil
            return nil
        } catch {
            signInCooldownUntil = Date().addingTimeInterval(Self.signInCooldown)
            return "Sewn sign-in failed: \(error.localizedDescription)"
        }
    }

    /// A token good for a request right now — refreshing (or re-signing-in) first when the current one is missing or near expiry.
    /// PIN: A token good for a request right now — refreshing (or re-signing-in) first when the current one is missing or near…
    public func validToken() async -> String? {
        if let accessToken, let expiresAt, expiresAt.timeIntervalSinceNow > 60 {
            return accessToken
        }
        if await refresh() { return accessToken }
        if let parkedUntil = signInCooldownUntil, parkedUntil > Date() {
            return nil
        }
        if await signIn() == nil { return accessToken }
        return nil
    }

    /// The server said 401 despite our bookkeeping — force one refresh (or
    /// sign-in) and hand back the new token; nil means give up.
    public func refreshAfter401() async -> String? {
        if await refresh() { return accessToken }
        accessToken = nil
        expiresAt = nil
        if await signIn() == nil { return accessToken }
        return nil
    }

    private func refresh() async -> Bool {
        guard let refreshToken else { return false }
        do {
            let body = try JSONEncoder().encode(SewnWire.RefreshRequest(refreshToken: refreshToken))
            let (data, status) = try await post(request(path: "v1/auth/refresh", body: body, bearer: nil))
            guard status == 200 else { return false }
            apply(try JSONDecoder().decode(SewnWire.SessionResponse.self, from: data))
            return true
        } catch {
            return false
        }
    }

    private func apply(_ session: SewnWire.SessionResponse) {
        accessToken = session.accessToken
        refreshToken = session.refreshToken
        expiresAt = Date().addingTimeInterval(session.expiresIn)
        // Sewn's TokenValidator lowercases the JWT subject; match it so
        // owner-scoped ids (groups, deposits) line up.
        userID = session.userID.lowercased()
    }

    private func request(path: String, body: Data, bearer: String?) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// AUTH GETS ITS OWN SESSION, not `URLSession.shared`.
    private static let authSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        // A voice that cannot reach the server must FAIL rather than wait —
        // the caller degrades to on-device synthesis (SpeechStreamingHTTP
        // makes the same choice for the same reason).
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    public static let urlSessionPost: HTTPPost = { request in
        let (data, response) = try await authSession.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
