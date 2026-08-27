//
//  SeerWSTransport.swift
//  MaryBrain
//
//  Injectable WebSocket seam for the realtime Seer route, mirroring
//  SeerSSETransport: tests script frames offline, the app wires URLSession.
//  First WebSocket usage in the repo.
//

import Foundation

/// One WebSocket frame, either direction.
public enum SeerWSFrame: Sendable {
    case text(String)
    case data(Data)
}

/// A live connection: an inbound frame stream plus send/close.
public struct SeerWSConnection: Sendable {
    public let frames: AsyncThrowingStream<SeerWSFrame, Error>
    public let send: @Sendable (SeerWSFrame) async throws -> Void
    public let close: @Sendable () -> Void

    public init(
        frames: AsyncThrowingStream<SeerWSFrame, Error>,
        send: @escaping @Sendable (SeerWSFrame) async throws -> Void,
        close: @escaping @Sendable () -> Void
    ) {
        self.frames = frames
        self.send = send
        self.close = close
    }
}

public protocol SeerWSTransport: Sendable {
    func connect(_ request: URLRequest) async throws -> SeerWSConnection
}

/// URLSessionWebSocketTask-based transport. Upgrade failures (including 401)
/// surface as the first `receive()` error — the realtime client treats any
/// pre-frame failure as "fall back to the classic route", whose own
/// refresh-and-retry then applies.
public struct URLSessionWSTransport: SeerWSTransport {
    public init() {}

    public func connect(_ request: URLRequest) async throws -> SeerWSConnection {
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()

        let frames = AsyncThrowingStream<SeerWSFrame, Error> { continuation in
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

        return SeerWSConnection(
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
