//
//  SemanticIntentIndex.swift
//  MaryBrain
//
//  WHAT: Embedding operate / perceive / compose / ask / converse from
//        package-authored seeds (`ability.triggers.intentSeeds`).
//  IN:   RoutingQuery string
//  OUT:  AmbientEngine.embeddingIntent
//  PIN:  Halt / confirm / edit / revise / architect stay lexical — never
//        entered here. Fail closed → converse. Corpus is package data, not a
//        fixed dictionary: any ability may seed its own intent seeds.
//
import MaryAmbient
import MaryFoundation
import Foundation

public struct SemanticIntentIndex: Sendable {

    public static let floor: Float = 0.62
    public static let margin: Float = 0.04

    /// Two different-intent seeds this close at build time are ambiguous
    /// authoring — an unresolved tie the corpus itself created — and are
    /// dropped from both sides rather than left to win one turn at random.
    public static let conflictCeiling: Float = 0.95

    /// The intents an embedding verdict may settle. `halt`/`decide`/`revise`/
    /// `architect` are deterministic or classifier-owned and never entered
    /// via embeddings — see `AmbientEngine.classify`'s ordering.
    public static let eligibleIntents: Set<AmbientIntent> =
        [.operate, .compose, .perceive, .ask, .converse]

    /// The one hard-coded seed set left: greetings and small talk are the
    /// null class no ability owns, so nothing would ever seed it otherwise.
    public static let builtInConverseSeeds: [String] = [
        "hello",
        "how are you",
        "what do you think about that",
        "tell me a joke",
        "thanks",
        "good morning",
    ]

    public struct Verdict: Sendable, Equatable {
        public var intent: AmbientIntent
        public var score: Float
        public var runnerUp: AmbientIntent?
        public var runnerUpScore: Float

        public init(
            intent: AmbientIntent,
            score: Float,
            runnerUp: AmbientIntent? = nil,
            runnerUpScore: Float = 0
        ) {
            self.intent = intent
            self.score = score
            self.runnerUp = runnerUp
            self.runnerUpScore = runnerUpScore
        }
    }

    private struct Entry: Sendable {
        var intent: AmbientIntent
        var positives: [[Float]]
    }

    private let entries: [Entry]
    private let vectorizer: any UtteranceVectorizer

    public var entryCount: Int { entries.count }

    /// One seed, before it is known which intent it will land under.
    private struct Seed {
        var intent: AmbientIntent
        var text: String
        var vector: [Float]
    }

    /// Every installed package's own habits, plus the built-in converse
    /// baseline. Built off the turn path, in the same breath as the Ability
    /// and Skill embedding indexes — see `AbilityLibrary+PackageLifecycle`.
    public static func build(
        records: [AbilityPackageRecord],
        vectorizer: any UtteranceVectorizer,
        templates: UtteranceTemplateExpander? = nil
    ) -> SemanticIntentIndex? {
        var seeds: [Seed] = []
        var skipped = 0
        var unknownIntentKeys = 0

        func addSeed(_ intent: AmbientIntent, _ text: String) {
            guard let raw = vectorizer.vector(for: text) else {
                skipped += 1
                return
            }
            seeds.append(Seed(
                intent: intent, text: text,
                vector: AmbientVectorMath.normalized(raw)))
        }

        for record in records {
            for (key, terms) in record.package.ability.triggers.intentSeeds {
                guard let intent = AmbientIntent(rawValue: key),
                      eligibleIntents.contains(intent)
                else {
                    unknownIntentKeys += 1
                    continue
                }
                // A seed may carry `{application}`; it becomes one seed per
                // pointable application. A seed without a slot is itself.
                let expanded = templates?.expand(
                    terms, for: record.package.ability.id) ?? terms
                for term in expanded where !term.isEmpty {
                    addSeed(intent, term)
                }
            }
        }
        for term in builtInConverseSeeds {
            addSeed(.converse, term)
        }

        // Conflict resolution: a seed pair from DIFFERENT intents this close
        // is ambiguous authoring — drop both rather than let build order
        // decide which intent silently wins a turn.
        var conflicted = Set<Int>()
        var conflicts = 0
        for i in seeds.indices {
            guard !conflicted.contains(i) else { continue }
            for j in seeds.indices where j > i {
                guard !conflicted.contains(j), seeds[i].intent != seeds[j].intent
                else { continue }
                if AmbientVectorMath.dot(seeds[i].vector, seeds[j].vector) >= conflictCeiling {
                    conflicted.insert(i)
                    conflicted.insert(j)
                    conflicts += 1
                }
            }
        }
        let survivors = seeds.enumerated()
            .filter { !conflicted.contains($0.offset) }
            .map(\.element)

        var byIntent: [AmbientIntent: [[Float]]] = [:]
        for seed in survivors {
            byIntent[seed.intent, default: []].append(seed.vector)
        }
        let entries = byIntent.map { Entry(intent: $0.key, positives: $0.value) }
        guard !entries.isEmpty else { return nil }
        let dim = entries.first?.positives.first?.count ?? 0
        MaryBrain.turnLog.info(
            "embed generate — intent entries=\(entries.count, privacy: .public) dim=\(dim, privacy: .public) skipped=\(skipped, privacy: .public) unknownKeys=\(unknownIntentKeys, privacy: .public) conflicts=\(conflicts, privacy: .public) habits=\(RoutingHabitStore.shared.count, privacy: .public)")
        return SemanticIntentIndex(entries: entries, vectorizer: vectorizer)
    }

    private init(entries: [Entry], vectorizer: any UtteranceVectorizer) {
        self.entries = entries
        self.vectorizer = vectorizer
    }

    /// Best intent at or above the floor with a margin over the runner-up.
    public func classify(
        _ query: String,
        habits: RoutingHabitStore = .shared,
        floor: Float = floor,
        margin: Float = margin
    ) -> Verdict? {
        guard let raw = vectorizer.vector(for: RoutingQuery.firstLine(query)) else { return nil }
        let needle = AmbientVectorMath.normalized(raw)
        var scored: [(AmbientIntent, Float)] = []
        for entry in entries {
            let positives = entry.positives
                + habits.vectors(intent: entry.intent.rawValue, ok: true, vectorizer: vectorizer)
            let best = positives.map { AmbientVectorMath.dot($0, needle) }.max() ?? -1
            let negatives = habits.vectors(
                intent: entry.intent.rawValue, ok: false, vectorizer: vectorizer)
            let bestNegative = negatives.map { AmbientVectorMath.dot($0, needle) }.max() ?? -1
            if bestNegative >= 0, best - bestNegative < SemanticAbilityRequestIndex.defaultNegativeMargin {
                continue
            }
            scored.append((entry.intent, best))
        }
        scored.sort { $0.1 > $1.1 }
        guard let first = scored.first, first.1 >= floor else { return nil }
        let second = scored.dropFirst().first
        if let second, first.1 - second.1 < margin { return nil }
        return Verdict(
            intent: first.0,
            score: first.1,
            runnerUp: second?.0,
            runnerUpScore: second?.1 ?? 0)
    }
}
