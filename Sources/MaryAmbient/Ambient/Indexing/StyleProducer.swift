//
//  StyleProducer.swift
//  MaryAmbient
//
//  WHAT: Who is learning, and what they are learning about — ability, not application.
//  OUT:  StyleEvidence / Corpus pane / persistence (one document per producer)
//  PIN:  Profile keyed by ability so a second app realizing the same craft can read it.
//
import MaryFoundation
import Foundation
import os

/// One ability that learns, and what it is bound to.
public struct StyleProducer: Sendable, Equatable {
    /// The subject a durable profile is filed under.
    public var ability: AbilityID
    /// Plugin owners this ability is observed through — `["xcode"]`,
    /// `["scrivener", "pages", "textedit"]`. Ordered for stable rendering.
    public var applications: [String]
    /// Notations it reads. EMPTY IS MEANINGFUL: prose has no language rung, and
    /// a producer that declares none files nothing there rather than inventing
    /// a name for "English".
    public var languages: [String]
    /// The line the rendered block opens with. Producer-supplied because "How
    /// this person writes code" is a lie in a manuscript.
    public var heading: String

    public init(
        ability: AbilityID,
        applications: [String],
        languages: [String] = [],
        heading: String
    ) {
        self.ability = ability
        self.applications = applications
        self.languages = languages
        self.heading = heading
    }

    /// Does this producer observe through `application`?
    public func observes(application: String) -> Bool {
        applications.contains(application)
    }
}

/// The registered producers, in registration order. Iterated by persistence (one document
/// per producer), by the Corpus pane (one section per producer), and by each crawl (which
/// carries its own producer so it never has to ask who it is).
public final class StyleProducerRegistry: @unchecked Sendable {

    public static let shared = StyleProducerRegistry()

    private let box = OSAllocatedUnfairLock<[StyleProducer]>(initialState: [])

    public init() {}

    /// Register, or replace the registration for the same ability. Idempotent
    /// so a re-boot of the stack does not accumulate duplicates.
    public func register(_ producer: StyleProducer) {
        box.withLock { producers in
            if let index = producers.firstIndex(where: { $0.ability == producer.ability }) {
                producers[index] = producer
            } else {
                producers.append(producer)
            }
        }
    }

    public func all() -> [StyleProducer] {
        box.withLock { $0 }
    }

    public func producer(for ability: AbilityID) -> StyleProducer? {
        box.withLock { $0.first { $0.ability == ability } }
    }

    /// The producer observing through this application, if any.
    public func producer(observing application: String) -> StyleProducer? {
        box.withLock { $0.first { $0.observes(application: application) } }
    }

    public func reset() {
        box.withLock { $0 = [] }
    }
}
