//
//  DictationSession.swift
//  MaryAdapter
//
//  A HELD WRITING DESTINATION — one slot, opened on purpose, closed on
//  purpose.
//
//  THE PROBLEM IT SOLVES. Dictating a scene into a manuscript, every sentence
//  was a fresh turn: classified for intent, routed to an Ability, arbitrated
//  into a roster, and only then typed. Forty sentences meant forty chances for
//  a classifier to read prose as a command, and the reported failure was
//  exactly that — "writing | type_at_cursor is unavailable: does not match its
//  Ability-level routing policy", over and over, at the speed the user could
//  repeat themselves. The gates that produced it are fixed. But a novelist
//  mid-scene should not be paying for classification they never wanted: the
//  fluent thing is to say so ONCE and then just talk.
//
//  So a session is a lease on the caret. While it is held, an utterance is
//  prose unless it is one of a very small number of addressed control phrases.
//  No intent, no roster, no model. A session cannot resolve into a routing
//  refusal because it never asks a routing question.
//
//  THE THIRD OF A FAMILY, and the distinction matters. `StagedWritingSurface`
//  is a HINT: one slot, non-consuming, thirty seconds, cleared by the write
//  that lands in it. `TypingSession` is a REMAINDER: what was left unsaid when
//  a passage was interrupted. This is a LEASE: long-lived, explicitly opened,
//  and it refuses rather than decaying silently. Folding any two of those into
//  one type would make a freshness window mean two things.
//
//  IT PINS THE EXACT TEXT ELEMENT, not the app and not the window. Scrivener
//  with a different document open is a different caret, and prose aimed at
//  chapter three must not land in chapter nine because both are Scrivener.
//
//  THE VERBS LIVE HERE TOO, uninstalled by default — the `PausedTypingSession`
//  idiom. The reasoning core opens, extends and closes a session without ever
//  naming the typer. The contract declares; the typer under Adapters/
//  installs; a process with no typer has no caret to hold and every verb
//  answers so. That last property is why the idiom stays even now that one
//  target holds both sides and nothing stops `MaryBrain` naming the typer.
//

import Foundation
import os

public final class DictationSession: @unchecked Sendable {

    public static let shared = DictationSession()

    /// The proven caret, and what has been said into it.
    public struct Held: Sendable, Equatable {
        public let bundleID: String
        /// The FAMILY, for frontmost checks — Scrivener 3 and 4 are both
        /// "still in Scrivener".
        public let matchPrefix: String
        public let spokenName: String
        /// The focused window's title when the session opened: "Section 1.3".
        /// Spoken back so the user hears WHERE Mary is about to write, which
        /// is the one thing they cannot verify by listening.
        public let placeName: String?
        public let processID: pid_t
        /// `AXSelectionReader.sourceSurfaceID` — the exact focused text
        /// element. A different document is a different caret.
        public let surfaceID: UInt?
        public let openedAt: Date
        public var lastSpanAt: Date
        public var wordsTyped: Int
        /// What "scratch that" removes. One span deep, deliberately.
        public var lastSpanCharacters: Int

        public init(
            bundleID: String,
            matchPrefix: String,
            spokenName: String,
            placeName: String? = nil,
            processID: pid_t,
            surfaceID: UInt?,
            openedAt: Date = Date(),
            lastSpanAt: Date? = nil,
            wordsTyped: Int = 0,
            lastSpanCharacters: Int = 0
        ) {
            self.bundleID = bundleID
            self.matchPrefix = matchPrefix
            self.spokenName = spokenName
            self.placeName = placeName
            self.processID = processID
            self.surfaceID = surfaceID
            self.openedAt = openedAt
            self.lastSpanAt = lastSpanAt ?? openedAt
            self.wordsTyped = wordsTyped
            self.lastSpanCharacters = lastSpanCharacters
        }

        /// "Scrivener — Section 1.3", or just "Scrivener".
        public var spokenPlace: String {
            guard let placeName, !placeName.isEmpty else { return spokenName }
            return "\(spokenName) — \(placeName)"
        }
    }

    /// LAZY EXPIRY, checked at the next utterance — no timer and no background
    /// wake, because a session that expires while nobody is talking has
    /// nothing to expire into. Long enough to think between paragraphs, short
    /// enough that a session forgotten before lunch is not still listening
    /// after it.
    public static let idleWindow: TimeInterval = 10 * 60

    private let box = OSAllocatedUnfairLock<Held?>(initialState: nil)

    public init() {}

    /// The held caret, only while fresh. Expiry is silent: the utterance that
    /// finds a stale session is not typed and not swallowed — it falls through
    /// to the ordinary turn loop, which is the only safe direction.
    public func held(at now: Date = Date()) -> Held? {
        box.withLock { slot -> Held? in
            guard let current = slot else { return nil }
            guard now.timeIntervalSince(current.lastSpanAt) <= Self.idleWindow else {
                slot = nil
                return nil
            }
            return current
        }
    }

    public func isHeld(at now: Date = Date()) -> Bool { held(at: now) != nil }

    /// Callers PROVE the caret first — see `DictationRunner.open`. Recording an
    /// unverified target here would make every later utterance type into a
    /// guess, which is the one failure mode a held mode cannot have.
    public func open(_ held: Held) {
        box.withLock { $0 = held }
    }

    public func noteSpan(words: Int, characters: Int, at now: Date = Date()) {
        box.withLock { held in
            guard held != nil else { return }
            held?.wordsTyped += words
            held?.lastSpanCharacters = characters
            held?.lastSpanAt = now
        }
    }

    /// After a scratch there is nothing further to scratch: saying it twice
    /// removes one span and says so, rather than eating the sentence before.
    public func clearLastSpan(at now: Date = Date()) {
        box.withLock { held in
            guard held != nil else { return }
            held?.lastSpanCharacters = 0
            held?.lastSpanAt = now
        }
    }

    /// Returns the closed session so the caller can report the word count.
    @discardableResult
    public func close() -> Held? {
        box.withLock { slot -> Held? in
            defer { slot = nil }
            return slot
        }
    }

    // MARK: - The verbs the reasoning core needs

    public struct OpenResult: Sendable {
        public let held: Held?
        public let refusal: String?
        public init(held: Held?, refusal: String?) {
            self.held = held
            self.refusal = refusal
        }
        public static func opened(_ held: Held) -> OpenResult {
            .init(held: held, refusal: nil)
        }
        public static func refused(_ reason: String) -> OpenResult {
            .init(held: nil, refusal: reason)
        }
    }

    public enum SpanResult: Sendable, Equatable {
        case typed(words: Int)
        /// The caret is gone — the user moved, or the document changed. The
        /// session closes and says so; it never chases.
        case lostSurface(String)
        /// No typer installed, or nothing held.
        case unavailable
    }

    private static let hooks = OSAllocatedUnfairLock<Hooks>(initialState: .init())

    private struct Hooks {
        var open: (@Sendable (String?) async -> OpenResult)?
        var type: (@Sendable (String) async -> SpanResult)?
        var scratch: (@Sendable () async -> SpanResult)?
    }

    public static func installOpen(_ handler: @escaping @Sendable (String?) async -> OpenResult) {
        hooks.withLock { $0.open = handler }
    }

    public static func installType(_ handler: @escaping @Sendable (String) async -> SpanResult) {
        hooks.withLock { $0.type = handler }
    }

    public static func installScratch(_ handler: @escaping @Sendable () async -> SpanResult) {
        hooks.withLock { $0.scratch = handler }
    }

    public static func openSession(app: String?) async -> OpenResult {
        guard let open = hooks.withLock({ $0.open }) else {
            return .refused("Typing isn't available in this build.")
        }
        return await open(app)
    }

    public static func typeSpan(_ text: String) async -> SpanResult {
        guard let type = hooks.withLock({ $0.type }) else { return .unavailable }
        return await type(text)
    }

    public static func scratchLastSpan() async -> SpanResult {
        guard let scratch = hooks.withLock({ $0.scratch }) else { return .unavailable }
        return await scratch()
    }
}
