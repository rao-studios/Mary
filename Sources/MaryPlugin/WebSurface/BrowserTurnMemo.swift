//
//  BrowserTurnMemo.swift
//  MaryPlugin
//
//  WHAT: What this turn already searched for, and where it landed.
//  IN:   the search recipe  OUT: the search recipe, one round later
//  PIN:  A TURN THAT SEARCHES TWICE FOR THE SAME THING IS A LOOP. The model runs a
//        search, gets an answer, is nudged to continue, and searches again — and the
//        second search cannot even prove itself, because typing the same query into the
//        address bar changes neither the address nor the title, so the settle reports
//        that nothing happened and the turn ends on a refusal for work that had already
//        succeeded.
//        ONE TURN, NOT A CACHE. Cleared by `AbilityRuntime.beginTurn` alongside every
//        other per-turn memo. A page is not still the page it was five minutes ago, and
//        this must never be the reason Mary believes it is.
//

import Foundation
import os

public final class BrowserTurnMemo: Sendable {

    public struct Landing: Sendable, Equatable {
        public var query: String
        /// What the page became — spoken, never an address.
        public var destination: String

        public init(query: String, destination: String) {
            self.query = query
            self.destination = destination
        }
    }

    private let box = OSAllocatedUnfairLock<[Landing]>(initialState: [])

    public static let shared = BrowserTurnMemo()

    public init() {}

    /// A new turn remembers nothing.
    public func beginTurn() {
        box.withLock { $0.removeAll() }
    }

    public func record(query: String, destination: String) {
        box.withLock { landings in
            landings.removeAll { matches($0.query, query) }
            landings.append(Landing(query: query, destination: destination))
        }
    }

    /// Where this turn already took that request, if it did.
    public func landing(for query: String) -> Landing? {
        box.withLock { landings in
            landings.last { matches($0.query, query) }
        }
    }

    /// LOOSELY, because the model rarely repeats itself word for word — it drops an
    /// article, adds "please", or re-words the request it just made.
    func matches(_ remembered: String, _ asked: String) -> Bool {
        let a = SpokenReference.normalized(remembered)
        let b = SpokenReference.normalized(asked)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }
}
