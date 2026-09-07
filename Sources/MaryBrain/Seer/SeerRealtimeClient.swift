//
//  SeerRealtimeClient.swift
//  MaryBrain
//
//  WHAT: Realtime turn over WebSocket (interleaved text + PCM).
//  IN:   SeerRealtimeProviding
//  OUT:  tokens + audio frames
//  PIN:  Error before first frame → invisible classic rerun; mid-turn drop keeps text.
//
import Foundation

public enum SeerRealtimeError: LocalizedError {
    case notAuthenticated
    case server(stage: String, message: String)
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:            return "Not signed in to Seer."
        case .server(let stage, let msg):  return "Seer realtime failed at \(stage): \(msg)"
        case .disconnected:                return "Seer realtime connection dropped."
        }
    }
}

/// The brain's seam onto the realtime route. Same event surface as classic
/// chat, extended with `.phase`/`.audio`/`.ttsFailed` (which the classic
/// client never emits).
public protocol SeerRealtimeProviding: Sendable {
    func isReady() async -> Bool
    func streamTurn(
        messages: [SeerChatMessage],
        instructions: String?
    ) -> AsyncThrowingStream<SeerChatEvent, Error>
}

public actor SeerRealtimeClient: SeerRealtimeProviding {

    private var baseURL: URL
    private let session: SeerSession
    private var personalTotemID: String?
    /// Empty = Seer's default chat model (drives the grounded pass).
    private var chatModel: String = ""
    /// Which backend Seer uses. Set by `setProvider`, not `configure`.
    private var provider: LLMEngineChoice?
    /// Mistral voice slug for the server-side TTS lane.
    private var voiceID: String = "fr_marie_neutral"
    private let transport: any SeerWSTransport
    /// Same per-turn read as the classic client — both transports wrap the
    /// identical `ChatRequest`, so both must carry the scope or scoping is a
    /// Settings-dependent illusion.
    private var retrievalScope: @Sendable (String) -> RetrievalScope = { _ in .general }

    public init(
        baseURL: URL,
        session: SeerSession,
        personalTotemID: String? = nil,
        transport: any SeerWSTransport = URLSessionWSTransport()
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
        voiceID: String = "fr_marie_neutral",
        retrievalScope: (@Sendable (String) -> RetrievalScope)? = nil
    ) {
        self.baseURL = baseURL
        self.personalTotemID = personalTotemID
        self.chatModel = chatModel
        self.voiceID = voiceID
        if let retrievalScope { self.retrievalScope = retrievalScope }
    }

    /// The lane's backend. Separate from `configure` — see `provider`.
    public func setProvider(_ provider: LLMEngineChoice?) {
        self.provider = provider
    }

    /// Character change from Settings — NARROWER than `configure` on purpose: identity, scope
    public func setVoiceID(_ voiceID: String) {
        self.voiceID = voiceID
    }

    // MARK: - SeerRealtimeProviding

    public func isReady() async -> Bool {
        await session.isAuthenticated
    }

    public nonisolated func streamTurn(
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
                throw SeerRealtimeError.notAuthenticated
            }

            // ONE scope value feeds both the trace and the wire — same hoist
            // as the SSE client, so the `.scoped` event can never describe a
            // different request than the turn.start below encodes.
            let scope = SeerWire.scope(
                ownerID: owner,
                personalTotemID: personalTotemID,
                retrieval: retrievalScope(owner)
            )
            // Yielded BEFORE the auth guard and connect/send: a turn that dies signed-out or on the handshake still traces, so the pane reads "asked
            continuation.yield(.scoped(SeerRequestTrace(scope: scope, transport: .realtime)))
            guard let token = initialToken else {
                throw SeerRealtimeError.notAuthenticated
            }
            let turnStart = SeerRealtimeWire.TurnStart(
                request: SeerWire.ChatRequest(
                    messages: messages,
                    model: chatModel.isEmpty ? nil : chatModel,
                    instructions: instructions,
                    provider: provider,
                    seer: scope
                ),
                tts: .init(voiceID: voiceID)
            )
            let startJSON = String(
                data: try JSONEncoder().encode(turnStart),
                encoding: .utf8
            ) ?? "{}"

            let connection = try await transport.connect(wsRequest(bearer: token))
            try await connection.send(.text(startJSON))

            var sampleRate: Double = 24_000
            var pcmRemainder = Data()
            var sawTurnEnd = false
            var forwardedAny = false

            for try await frame in connection.frames {
                if Task.isCancelled { break }
                switch frame {
                case .text(let text):
                    guard let data = text.data(using: .utf8),
                          let inbound = try? JSONDecoder().decode(SeerRealtimeWire.InboundFrame.self, from: data) else {
                        continue   // undecodable frames are skipped, matching the SSE client
                    }
                    switch inbound.type {
                    case "token":
                        if let token = inbound.text, !token.isEmpty {
                            forwardedAny = true
                            continuation.yield(.token(token))
                        }
                    case "phase":
                        if let phase = inbound.phase {
                            continuation.yield(.phase(phase))
                        }
                    case "audio.begin":
                        if let rate = inbound.sampleRate { sampleRate = rate }
                    case "tts.failed":
                        continuation.yield(.ttsFailed)
                    case "metadata":
                        if let chunk = inbound.chunk {
                            if let contribution = chunk.contribution {
                                continuation.yield(.contribution(contribution))
                            }
                            if chunk.autoMemory {
                                continuation.yield(.autoMemory(true))
                            }
                        }
                    case "turn.end":
                        sawTurnEnd = true
                    case "error":
                        // Pre-token errors mean the turn never really started — throw so the brain reruns on the classic lane.
                        if !forwardedAny {
                            throw SeerRealtimeError.server(
                                stage: inbound.stage ?? "unknown",
                                message: inbound.message ?? "unknown"
                            )
                        }
                    default:
                        break
                    }
                    if sawTurnEnd {
                        connection.close()
                    }
                case .data(let data):
                    // Frames must stay whole-float; carry a remainder so a
                    // mid-float split never corrupts the decode downstream.
                    var combined = pcmRemainder + data
                    let usable = combined.count - combined.count % 4
                    guard usable > 0 else {
                        pcmRemainder = combined
                        continue
                    }
                    pcmRemainder = combined.subdata(in: usable..<combined.count)
                    combined.removeSubrange(usable..<combined.count)
                    forwardedAny = true
                    continuation.yield(.audio(pcm: combined, sampleRate: sampleRate))
                }
                if sawTurnEnd { break }
            }

            guard sawTurnEnd || Task.isCancelled else {
                // Socket ended without turn.end — the server died mid-turn.
                throw SeerRealtimeError.disconnected
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func wsRequest(bearer: String) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        let url = (components?.url ?? baseURL).appendingPathComponent("v1/realtime/chat")
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        return request
    }
}
