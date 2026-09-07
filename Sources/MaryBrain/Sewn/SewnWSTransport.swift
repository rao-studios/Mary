//
//  SewnWSTransport.swift
//  MaryBrain
//
//  WHAT: Injectable WebSocket seam for the realtime Sewn route.
//  IN:   SewnRealtimeClient
//  OUT:  tests script frames; app wires URLSession
//
import Foundation

/// One WebSocket frame, either direction.
public enum SewnWSFrame: Sendable {
    case text(String)
    case data(Data)
}

/// A live connection: an inbound frame stream plus send/close.
public struct SewnWSConnection: Sendable {
    public let frames: AsyncThrowingStream<SewnWSFrame, Error>
    public let send: @Sendable (SewnWSFrame) async throws -> Void
    public let close: @Sendable () -> Void

    public init(
        frames: AsyncThrowingStream<SewnWSFrame, Error>,
        send: @escaping @Sendable (SewnWSFrame) async throws -> Void,
        close: @escaping @Sendable () -> Void
    ) {
        self.frames = frames
        self.send = send
        self.close = close
    }
}

public protocol SewnWSTransport: Sendable {
    func connect(_ request: URLRequest) async throws -> SewnWSConnection
}

/// URLSessionWebSocketTask-based transport. Upgrade failures (including 401) surface as the first `receive()` error
public struct URLSessionWSTransport: SewnWSTransport {
    public init() {}

    public func connect(_ request: URLRequest) async throws -> SewnWSConnection {
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()

        let frames = AsyncThrowingStream<SewnWSFrame, Error> { continuation in
            let pump = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        switch message {
                        case .string(let text): continuation.yield(.text(text))
                        case .data(let data):   continuation.yield(.data(data))
                        @unknown default:       break
                        }
                    }
                    continuation.finish()
                } catch {
                    // The server closes the socket after turn.end — a receive
                    // error on a normally-closed socket is the clean ending.
                    if task.closeCode == .normalClosure || task.closeCode == .goingAway {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in
                pump.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }

        return SewnWSConnection(
            frames: frames,
            send: { frame in
                switch frame {
                case .text(let text): try await task.send(.string(text))
                case .data(let data): try await task.send(.data(data))
                }
            },
            close: { task.cancel(with: .normalClosure, reason: nil) }
        )
    }
}
