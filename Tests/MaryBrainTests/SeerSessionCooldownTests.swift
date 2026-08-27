//
//  SeerSessionCooldownTests.swift
//  MaryBrainTests
//
//  THE SIGN-IN COOLDOWN. An unauthenticated session used to make EVERY
//  spoken chunk pay one refresh plus up to two full 15-second sign-in round
//  trips before its fallback voice could speak — a per-sentence stall for as
//  long as the server stayed down. A failed sign-in now parks further
//  attempts for `signInCooldown`; `refreshAfter401` bypasses the park (an
//  explicit server signal earns a real attempt); new credentials clear it.
//

import Foundation
import Testing
@testable import MaryBrain

@Suite struct SeerSessionCooldownTests {

    private final class PostCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func note(_ request: URLRequest) {
            lock.lock(); defer { lock.unlock() }
            paths.append(request.url?.lastPathComponent ?? "?")
        }
        func all() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return paths
        }
    }

    private func failingSession(counter: PostCounter) -> SeerSession {
        SeerSession(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            email: "x@y.z", password: "pw",
            post: { request in
                counter.note(request)
                return (Data(), 503)
            })
    }

    @Test func aFailedSignInArmsTheCooldown() async {
        let counter = PostCounter()
        let session = failingSession(counter: counter)

        #expect(await session.validToken() == nil)
        let afterFirst = counter.all().count
        #expect(afterFirst >= 1, "the first ask genuinely tried the server")

        // Within the cooldown, the next ask makes ZERO further HTTP calls —
        // it answers nil fast instead of stalling the chunk.
        #expect(await session.validToken() == nil)
        #expect(counter.all().count == afterFirst)
    }

    @Test func refreshAfter401BypassesTheCooldown() async {
        let counter = PostCounter()
        let session = failingSession(counter: counter)

        _ = await session.validToken()          // arms the cooldown
        let armed = counter.all().count
        _ = await session.refreshAfter401()     // explicit server signal
        #expect(counter.all().count > armed,
                "a 401 earns a real attempt even mid-cooldown")
    }

    @Test func configureClearsTheCooldown() async {
        let counter = PostCounter()
        let session = failingSession(counter: counter)

        _ = await session.validToken()          // arms the cooldown
        let armed = counter.all().count
        await session.configure(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            email: "new@y.z", password: "pw2")
        _ = await session.validToken()
        #expect(counter.all().count > armed,
                "new credentials deserve a fresh attempt")
    }
}
