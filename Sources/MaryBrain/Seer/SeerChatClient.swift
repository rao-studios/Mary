//
//  SeerChatClient.swift
//  MaryBrain
//
//  Streams chat completions from the local Seer server. SSE reading follows
//  Sis's NetworkService: `data: ` lines, `[DONE]` terminator, one refresh-
//  and-retry on 401. The reader NEVER stops at the last text token — the
//  contribution rides a trailing chunk with empty choices.
//

import Foundation

/// Injectable SSE seam: open a request, get (status, line stream).
public protocol SeerSSETransport: Sendable {
    func open(_ request: URLRequest) async throws
        -> (status: Int, lines: AsyncThrowingStream<String, Error>)
}

public enum SeerChatError: LocalizedError {
    case notAuthenticated
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in to Seer."
        case .http(let status): return "Seer chat failed (\(status))."
        }
    }
}

public actor SeerChatClient: SeerChatProviding {

    private var baseURL: URL
    private let session: SeerSession
    private var personalTotemID: String?
    /// Empty = Seer's default model. Sent as the request `model` otherwise.
    private var chatModel: String = ""
    private let transport: any SeerSSETransport
    /// Read at REQUEST time, not configure time: "is a document focused" is a
    /// per-turn fact, and `configure` only runs when Settings change. Default
    /// = general, which is exactly the hardcoded `aggregate: true` this
    /// replaces — an install that never wires a provider behaves as before.
    private var retrievalScope: @Sendable (String) -> RetrievalScope = { _ in .general }

    public init(
        baseURL: URL,
        session: SeerSession,
        personalTotemID: String? = nil,
        transport: any SeerSSETransport = URLSessionSSETransport()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.personalTotemID = personalTotemID
        self.transport = transport
    }

    public func configure(
        baseURL: URL,
        personalTotemID: String?,
        chatModel: String = "",
        retrievalScope: (@Sendable (String) -> RetrievalScope)? = nil
    ) {
        self.baseURL = baseURL
        self.personalTotemID = personalTotemID
        self.chatModel = chatModel
        if let retrievalScope { self.retrievalScope = retrievalScope }
    }

    // MARK: - SeerChatProviding

    public func isReady() async -> Bool {
        await session.isAuthenticated
    }

    public func ownerID() async -> String? {
        await session.userID
    }

    public nonisolated func stream(
        messages: [SeerChatMessage],
        instructions: String?
    ) -> AsyncThrowingStream<SeerChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.run(
                    messages: messages,
                    instructions: instructions,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        messages: [SeerChatMessage],
        instructions: String?,
        continuation: AsyncThrowingStream<SeerChatEvent, Error>.Continuation
    ) async {
        do {
            // Token FIRST even though its guard comes later: on a cold boot
            // `validToken()` is what signs in, and that sign-in mints the
            // owner id the scope below needs.
            let initialToken = await session.validToken()
            guard let owner = await session.userID else {
                // Never signed in — no owner id, so the scope is unbuildable
                // and there is nothing truthful to trace. The only path that
                // throws before `.scoped`.
                throw SeerChatError.notAuthenticated
            }

            // ONE scope value feeds both the trace and the wire — hoisted so
            // the `.scoped` event can never describe a different request than
            // the bytes below encode.
            let scope = SeerWire.scope(
                ownerID: owner,
                personalTotemID: personalTotemID,
                retrieval: retrievalScope(owner)
            )
            // Yielded BEFORE the auth guard and the transport open: an
            // attempt that dies signed-out or mid-open still traces, so the
            // pane reads "asked, nothing back" rather than "no retrieval
            // asked" — the attempts that never finish are the ones worth
            // seeing (`AmbientTraceLog`'s unfinished-turns rationale).
            continuation.yield(.scoped(SeerRequestTrace(scope: scope, transport: .sse)))
            guard var token = initialToken else {
                throw SeerChatError.notAuthenticated
            }
            let body = try JSONEncoder().encode(SeerWire.ChatRequest(
                messages: messages,
                model: chatModel.isEmpty ? nil : chatModel,
                instructions: instructions,
                seer: scope
            ))

            var attempt = try await transport.open(chatRequest(body: body, bearer: token))
            if attempt.status == 401 {
                guard let fresh = await session.refreshAfter401() else {
                    throw SeerChatError.notAuthenticated
                }
                token = fresh
                attempt = try await transport.open(chatRequest(body: body, bearer: token))
            }
            guard attempt.status == 200 else {
                throw SeerChatError.http(attempt.status)
            }

            var autoMemory = false
            for try await line in attempt.lines {
                if Task.isCancelled { break }
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(SeerWire.StreamChunk.self, from: data) else {
                    continue   // undecodable chunks are skipped, matching Sis
                }
                if let text = chunk.choices.first?.delta.content, !text.isEmpty {
                    continuation.yield(.token(text))
                }
                if let contribution = chunk.contribution {
                    continuation.yield(.contribution(contribution))
                }
                autoMemory = chunk.autoMemory   // last chunk value wins
            }
            if autoMemory {
                continuation.yield(.autoMemory(true))
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func chatRequest(body: Data, bearer: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.httpBody = body
        // IDLE timeout. The WALL CLOCK is on the session
        // (`StreamingHTTP.resourceTimeout`) — this number alone never bounded
        // anything, because an SSE stream sending heartbeats and no `data:`
        // chunks resets it on every byte. See `StreamingHTTP`.
        request.timeoutInterval = StreamingHTTP.idleTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        return request
    }
}

// MARK: - URLSession transport

public struct URLSessionSSETransport: SeerSSETransport {
    public init() {}

    public func open(_ request: URLRequest) async throws
        -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        // NOT `URLSession.shared`: its configuration's
        // `timeoutIntervalForResource` is seven days, so a live-but-silent
        // stream here had no ceiling at all. See `StreamingHTTP`.
        let (bytes, response) = try await StreamingHTTP.session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let pump = Task {
                do {
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
        return (status, lines)
    }
}
