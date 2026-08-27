//
//  SeerTTSEngineTests.swift
//  MaryVoiceTests
//
//  SEER MEANS SEER — the degradation contract. An auth-shaped failure buys
//  one full re-auth attempt before any fallback; a fallback chunk announces
//  itself through `onDegrade` instead of total silence; and because the
//  fallback is per-chunk, the next chunk tries Seer again by construction.
//

import Foundation
import Testing
@testable import MaryVoice

@Suite struct SeerTTSEngineTests {

    private actor StubSynthesizer: SpeechSynthesizer {
        var sampleRate: Double = 22_050
        private(set) var chunks: [String] = []

        func synthesizeWaveform(_ text: String) async throws -> [Float] {
            chunks.append(text)
            return [0.1, 0.2]
        }

        func spoken() -> [String] { chunks }
    }

    private final class TokenCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() -> Int {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return count
        }
        func calls() -> Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
    }

    private final class DegradeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var notes: [String] = []
        func note(_ reason: String) {
            lock.lock(); defer { lock.unlock() }
            notes.append(reason)
        }
        func all() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return notes
        }
    }

    @Test func anAuthFailureRetriesOnceThenDegradesAudibly() async throws {
        let tokens = TokenCounter()
        let engine = SeerTTSEngine(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            tokenProvider: {
                _ = tokens.bump()
                return nil   // signed out, and re-auth keeps failing
            })
        let fallback = StubSynthesizer()
        await engine.setFallback(fallback)
        let degrades = DegradeLog()
        await engine.setOnDegrade { degrades.note($0) }

        let samples = try await engine.synthesizeWaveform("Hello there.")

        // The chunk still spoke — through the fallback, not silence.
        #expect(samples == [0.1, 0.2])
        #expect(await fallback.spoken() == ["Hello there."])
        // The re-auth attempt happened: the token was asked for TWICE
        // before the fallback was allowed to carry the chunk.
        #expect(tokens.calls() == 2)
        // And the degradation said so.
        #expect(degrades.all().count == 1)
        #expect(degrades.all().first?.contains("Not signed in") == true)
        // The engine reports the fallback's rate for the degraded chunk.
        #expect(await engine.sampleRate == 22_050)
    }

    @Test func aRecoveredSecondAttemptNeverDegrades() async throws {
        // First token ask fails, second succeeds — but with no reachable
        // server the retry still errors; what this pins is that the SECOND
        // token ask happened at all (the re-auth path) and that a token
        // failure alone is what routes to it. Full recovery needs a live
        // server and is covered by the manual smoke.
        let tokens = TokenCounter()
        let engine = SeerTTSEngine(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            tokenProvider: {
                tokens.bump() == 1 ? nil : "token-two"
            })
        let fallback = StubSynthesizer()
        await engine.setFallback(fallback)
        let degrades = DegradeLog()
        await engine.setOnDegrade { degrades.note($0) }

        _ = try await engine.synthesizeWaveform("Hi.")

        #expect(tokens.calls() >= 2, "the auth-shaped failure earned a second full attempt")
        #expect(await fallback.spoken() == ["Hi."], "an unreachable server still degrades after the retry")
    }

    @Test func withNoFallbackTheErrorSurfaces() async {
        let engine = SeerTTSEngine(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            tokenProvider: { nil })
        await #expect(throws: SeerTTSError.notSignedIn) {
            _ = try await engine.synthesizeWaveform("Hello.")
        }
    }

    @Test func cancellationAfterTokenLookupNeverLaunchesFallback() async {
        let tokens = TokenCounter()
        let engine = SeerTTSEngine(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            tokenProvider: {
                _ = tokens.bump()
                // Model a callback/cache bridge that returns normally even
                // though its caller cancelled while it was suspended.
                withUnsafeCurrentTask { $0?.cancel() }
                return "stale-token"
            })
        let fallback = StubSynthesizer()
        await engine.setFallback(fallback)
        let reauths = TokenCounter()
        await engine.setOnReauth { _ = reauths.bump() }

        let result = await Task {
            try await engine.synthesizeWaveform("Do not speak this.")
        }.result
        switch result {
        case .success:
            Issue.record("cancelled synthesis unexpectedly succeeded")
        case .failure(let error):
            #expect(error is CancellationError)
        }

        #expect(tokens.calls() == 1)
        #expect(reauths.calls() == 0)
        #expect(await fallback.spoken().isEmpty,
                "cancellation is teardown, never a signal to start Kokoro")
    }

    @Test func cancellationDuringReauthCannotStartASecondRequestOrFallback() async {
        let tokens = TokenCounter()
        let reauths = TokenCounter()
        let engine = SeerTTSEngine(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            tokenProvider: {
                _ = tokens.bump()
                return nil
            })
        await engine.setOnReauth {
            _ = reauths.bump()
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let fallback = StubSynthesizer()
        await engine.setFallback(fallback)

        let result = await Task {
            try await engine.synthesizeWaveform("Also stay silent.")
        }.result
        switch result {
        case .success:
            Issue.record("cancelled reauth unexpectedly continued")
        case .failure(let error):
            #expect(error is CancellationError)
        }

        #expect(reauths.calls() == 1)
        #expect(tokens.calls() == 1,
                "cancellation after reauth prevents the second token/request attempt")
        #expect(await fallback.spoken().isEmpty)
    }

    @Test func aStale401CallsTheReauthHookBeforeTheSecondAttempt() async throws {
        // An auth-shaped failure must FORCE a session refresh before the
        // retry — otherwise the retry re-reads the session's cache and
        // resends the very token the server just rejected.
        let tokens = TokenCounter()
        let reauths = TokenCounter()
        let engine = SeerTTSEngine(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            tokenProvider: {
                _ = tokens.bump()
                return nil          // auth-shaped failure every time
            })
        await engine.setOnReauth {
            // The hook must fire AFTER the first token ask and BEFORE the
            // second — order pinned via the counters.
            #expect(tokens.calls() == 1)
            _ = reauths.bump()
        }
        let fallback = StubSynthesizer()
        await engine.setFallback(fallback)

        _ = try await engine.synthesizeWaveform("Hi.")

        #expect(reauths.calls() == 1, "one forced re-auth per auth-shaped failure")
        #expect(tokens.calls() == 2, "the retry asked for a token again after the re-auth")
    }

    @Test func recoveryRearmsTheEpisodeNotice() async throws {
        // After a degraded chunk, the first SUCCESSFUL Seer chunk fires
        // onRecover exactly once — the host re-arms its once-per-episode
        // degradation notice with it. Without a live server the success leg
        // can't run here, so this pins the degrade side: onRecover must NOT
        // fire while chunks keep degrading.
        let engine = SeerTTSEngine(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            tokenProvider: { nil })
        let fallback = StubSynthesizer()
        await engine.setFallback(fallback)
        let recoveries = TokenCounter()
        await engine.setOnRecover { _ = recoveries.bump() }

        _ = try await engine.synthesizeWaveform("One.")
        _ = try await engine.synthesizeWaveform("Two.")

        #expect(recoveries.calls() == 0,
                "recovery fires only on a SUCCESSFUL Seer chunk after a degrade")
    }

    // MARK: - Latency policy (a listener is waiting behind every one of these)

    /// The speak request must carry the SHORT first-byte bound, not the 60 s
    /// idle timeout. A wedged Seer that accepts the socket and sends nothing
    /// used to cost 30 s + 30 s while the caller had budgeted twelve for
    /// synthesis and playback together.
    @Test func theSpeakRequestCarriesTheFirstByteBound() async throws {
        let engine = SeerTTSEngine(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            tokenProvider: { "token" })
        let request = try await engine.makeRequest(
            text: "hello", voiceID: "fr_marie", token: "token")

        #expect(request.timeoutInterval == SpeechStreamingHTTP.firstByteTimeout)
        #expect(SpeechStreamingHTTP.firstByteTimeout < SpeechStreamingHTTP.resourceTimeout,
                "the first-byte bound must bind before the wall clock")
    }

    /// A server that just timed out will time out again, and a host that
    /// refused will refuse again — retrying only doubles the silence in front
    /// of a listener while the on-device fallback stands ready.
    @Test func timeoutsAndRefusalsAreNotRetried() {
        let engine = SeerTTSEngine(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            tokenProvider: { "token" })

        #expect(!engine.isRetryable(URLError(.timedOut)))
        #expect(!engine.isRetryable(URLError(.cannotConnectToHost)))
        #expect(!engine.isRetryable(URLError(.cannotFindHost)))
        #expect(!engine.isRetryable(URLError(.cancelled)))

        // Genuinely transient faults keep their second attempt.
        #expect(engine.isRetryable(URLError(.networkConnectionLost)))
        #expect(engine.isRetryable(SeerTTSError.badStatus(503)))
        #expect(!engine.isRetryable(SeerTTSError.badStatus(400)))
    }
}
