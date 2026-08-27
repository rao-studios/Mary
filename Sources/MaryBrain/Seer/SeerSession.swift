//
//  SeerSession.swift
//  MaryBrain
//
//  Seer account session: sign in at boot, hand out a valid Bearer token,
//  refresh proactively near expiry and reactively after a 401. Tokens live
//  only in this actor — never persisted; every app boot signs in fresh.
//  Follows Sis's NetworkService retry discipline: refresh at most once per
//  failure, then surface the error.
//

import Foundation

public actor SeerSession {

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
        post: @escaping HTTPPost = SeerSession.urlSessionPost
    ) {
        self.baseURL = baseURL
        self.email = email
        self.password = password
        self.post = post
    }

    public var isAuthenticated: Bool {
        accessToken != nil && userID != nil
    }

    /// HOW LONG A FAILED SIGN-IN PARKS FURTHER ATTEMPTS. Without this, an
    /// unauthenticated session made EVERY spoken chunk pay one refresh plus
    /// up to two full 15-second sign-in round trips before its fallback voice
    /// could speak — a mid-paragraph stall, per sentence, for as long as the
    /// server stayed down. During the cooldown `validToken` answers nil
    /// immediately; the moment it elapses, the next chunk tries again.
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
            let body = try JSONEncoder().encode(SeerWire.SignInRequest(email: email, password: password))
            let (data, status) = try await post(request(path: "v1/auth/sign-in", body: body, bearer: nil))
            guard status == 200 else {
                signInCooldownUntil = Date().addingTimeInterval(Self.signInCooldown)
                return "Seer sign-in failed (\(status))."
            }
            apply(try JSONDecoder().decode(SeerWire.SessionResponse.self, from: data))
            signInCooldownUntil = nil
            return nil
        } catch {
            signInCooldownUntil = Date().addingTimeInterval(Self.signInCooldown)
            return "Seer sign-in failed: \(error.localizedDescription)"
        }
    }

    /// A token good for a request right now — refreshing (or re-signing-in)
    /// first when the current one is missing or near expiry. A recent failed
    /// sign-in answers nil FAST rather than paying the round trip again;
    /// `refreshAfter401` deliberately bypasses that (an explicit server
    /// signal earns a real attempt).
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
            let body = try JSONEncoder().encode(SeerWire.RefreshRequest(refreshToken: refreshToken))
            let (data, status) = try await post(request(path: "v1/auth/refresh", body: body, bearer: nil))
            guard status == 200 else { return false }
            apply(try JSONDecoder().decode(SeerWire.SessionResponse.self, from: data))
            return true
        } catch {
            return false
        }
    }

    private func apply(_ session: SeerWire.SessionResponse) {
        accessToken = session.accessToken
        refreshToken = session.refreshToken
        expiresAt = Date().addingTimeInterval(session.expiresIn)
        // Seer's TokenValidator lowercases the JWT subject; match it so
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
    ///
    /// `timeoutInterval` above is an IDLE timer; the WALL CLOCK is
    /// `timeoutIntervalForResource`, and on the shared session that is SEVEN
    /// DAYS. Sign-in and refresh sit in front of every spoken chunk
    /// (`validToken()` is the first line of Seer synthesis), so against a
    /// wedged-but-listening server that unbounded ceiling was pure invisible
    /// latency ahead of a caller that had already budgeted its own deadline.
    /// Twenty seconds covers a slow round trip and refuses to cover a hang.
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
