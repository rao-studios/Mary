//
//  DanceCalibrationTests.swift
//  MaryBrainTests
//
//  WHAT: The sentences the dance exists for reach it through the real triage —
//        and a greeting does not.
//  OUT:  TurnTriage.verdict over the shipped corpus
//  PIN:  OPT-IN, like EmbeddingCalibrationTests, for the same reason: the
//        on-device embedding asset. "How are you" is a built-in converse seed;
//        "how are you feeling" is the dance's. The margin between them is
//        measured here, never assumed.
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct DanceCalibrationTests {

    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["MARY_EMBEDDING_CALIBRATION"] == "1"
    }

    private static func registry() throws -> AbilityRuntime.Snapshot? {
        guard enabled else { return nil }
        guard let vectorizer = NLUtteranceVectorizer.shared else { return nil }
        guard let abilities = InstalledPackages.installed() else { return nil }
        let records = try FileManager.default
            .contentsOfDirectory(at: abilities, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "mary" }
            .map { url -> AbilityPackageRecord in
                AbilityPackageRecord(
                    package: try AbilityPackageCodec.load(from: url),
                    source: .sourceTree, sourceURL: url,
                    validation: .init(), rawData: Data())
            }
        guard let intent = SemanticIntentIndex.build(records: records, vectorizer: vectorizer),
              let skills = SemanticSkillRequestIndex.build(records: records, vectorizer: vectorizer)
        else { return nil }
        return AbilityRuntime.Snapshot(
            records: records,
            validation: .init(),
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: MaryAdapterCatalog.adapters()
                    + [AffordancePlugin(), CodingAgentAdapter(),
                       DancePlugin(compose: UnavailableDanceComposer())],
                observers: MaryAdapterCatalog.observers()),
            semanticIndex: SemanticAbilityRequestIndex.build(records: records, vectorizer: vectorizer),
            semanticSkillIndex: skills,
            semanticIntentIndex: intent)
    }

    private static func verdict(_ query: String, in registry: AbilityRuntime.Snapshot) -> TurnTriage.Verdict {
        TurnTriage.verdict(
            query: query, registry: registry,
            offeredNames: Set(registry.skills.map(\.reference.invocationName)),
            habits: RoutingHabitStore())
    }

    /// The act, the mood and the stop each win the skill tier alone and read
    /// as an act — the whole no-model lane, minus the dispatch.
    @Test func theDanceSentencesReadAsActsAndWinAlone() throws {
        guard let registry = try Self.registry() else { return }
        let cases: [(String, SkillID)] = [
            ("Let's dance.", "dance.start"),
            ("Dance for me.", "dance.start"),
            ("How are you feeling?", "dance.mood"),
            ("How do you feel right now?", "dance.mood"),
            ("What do you think I feel like right now?", "dance.mood"),
            ("Show me your mood.", "dance.mood"),
            ("Stop dancing.", "dance.stop"),
        ]
        var report: [String] = []
        for (sentence, expected) in cases {
            let verdict = Self.verdict(sentence, in: registry)
            let top = verdict.skillAffinities.sorted { $0.value > $1.value }.prefix(3)
                .map { "\($0.key.rawValue)=\(String(format: "%.2f", $0.value))" }
            report.append("dance [\(sentence)] intent=\(verdict.intent.map(\.rawValue) ?? "nil") score=\(String(format: "%.2f", verdict.intentScore)) unique=\(verdict.uniqueSkill?.skill.id.rawValue ?? "none") promoted=\(verdict.promotedByUniqueSkill) top: \(top.joined(separator: " "))")
            #expect(verdict.uniqueSkill?.skill.id == expected, "\(sentence) did not win alone: \(top)")
            #expect(verdict.intent == .operate, "\(sentence) read as \(verdict.intent.map(\.rawValue) ?? "nil"), not an act")
        }
        print(report.joined(separator: "\n"))
    }

    /// A GREETING STAYS SMALL TALK. "How are you" is a built-in converse seed
    /// and must keep scoring as one, whatever the dance's corpus holds.
    @Test func aGreetingIsNotAMood() throws {
        guard let registry = try Self.registry() else { return }
        for sentence in ["How are you?", "hello", "how are you doing"] {
            let verdict = Self.verdict(sentence, in: registry)
            print("dance greeting [\(sentence)] intent=\(verdict.intent.map(\.rawValue) ?? "nil") score=\(String(format: "%.2f", verdict.intentScore)) unique=\(verdict.uniqueSkill?.skill.id.rawValue ?? "none")")
            #expect(verdict.intent != .operate, "\(sentence) read as an act")
            #expect(!verdict.promotedByUniqueSkill, "\(sentence) was promoted to an act")
        }
    }
}

extension DanceCalibrationTests {

    /// THE DISTANCE BETWEEN A GREETING AND A QUESTION ABOUT A FEELING, printed
    /// so the seed that separates them is chosen by measurement. A seed within
    /// `SemanticIntentIndex.conflictCeiling` of "how are you" would drop the
    /// greeting's own seed at build, which is worse than losing the sentence.
    @Test func theFeelingSeedsAreMeasuredAgainstTheGreeting() throws {
        guard Self.enabled, let vectorizer = NLUtteranceVectorizer.shared else { return }
        func vector(_ text: String) -> [Float]? {
            vectorizer.vector(for: text).map(AmbientVectorMath.normalized)
        }
        guard let greeting = vector("how are you"),
              let question = vector("how are you feeling"),
              let today = vector("how are you feeling today")
        else { return }
        let candidates = [
            "how are you feeling", "how are you feeling today", "how are you feeling right now",
            "how do you feel", "how are you feeling mary", "tell me how you are feeling",
            "are you feeling okay", "what is your mood",
        ]
        var lines: [String] = []
        for candidate in candidates {
            guard let v = vector(candidate) else { continue }
            lines.append(String(
                format: "seed [%@] · greeting %.3f · \"how are you feeling\" %.3f · \"…today\" %.3f",
                candidate, AmbientVectorMath.dot(v, greeting), AmbientVectorMath.dot(v, question),
                AmbientVectorMath.dot(v, today)))
        }
        print(lines.joined(separator: "\n"))
        #expect(AmbientVectorMath.dot(question, greeting) < 1)
    }
}
