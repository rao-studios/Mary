//
//  EmbeddingCalibrationTests.swift
//  MaryBrainTests
//
//  WHAT: The real target query, through the REAL NLEmbedding asset — not the
//        orthogonal-cluster fake `EmbeddingRoutingTests` uses. Opt-in: run
//        with `MARY_EMBEDDING_CALIBRATION=1 swift test` on a Mac that has
//        the on-device English embedding asset. Skipped everywhere else,
//        including ordinary `swift test` and CI.
//  OUT:  SemanticIntentIndex + SemanticSkillRequestIndex, built from the
//        shipped `Abilities/` packages exactly as production builds them.
//  PIN:  This suite measures; it does not guess. If the with-world variant
//        ever fails here, the fix is to decide from THIS measurement —
//        classifying the query's first line, widening the corpus, or
//        raising/lowering a threshold — not to assume one in advance.
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

@Suite struct EmbeddingCalibrationTests {

    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["MARY_EMBEDDING_CALIBRATION"] == "1"
    }

    private static let screenshotOpen =
        "Can you open Apple Music and play the RAO playlist"
    private static let screenshotInApp =
        "Can you play the RAO playlist in Apple Music"

    private struct Environment {
        var snapshot: AbilityRuntimeSnapshot
        var intent: SemanticIntentIndex
        var skills: SemanticSkillRequestIndex
    }

    /// Every shipped package, exactly as `AbilityLibrary+PackageLifecycle`
    /// builds the production snapshot — no fixture, no fake vectorizer.
    private static func environment() throws -> Environment? {
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
              let skillIndex = SemanticSkillRequestIndex.build(
                records: records, vectorizer: vectorizer)
        else { return nil }
        let abilityIndex = SemanticAbilityRequestIndex.build(
            records: records, vectorizer: vectorizer)
        let snapshot = AbilityRuntimeSnapshot(
            records: records,
            validation: .init(),
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: MaryAdapterCatalog.adapters(),
                observers: MaryAdapterCatalog.observers()),
            semanticIndex: abilityIndex,
            semanticSkillIndex: skillIndex,
            semanticIntentIndex: intent)
        return Environment(snapshot: snapshot, intent: intent, skills: skillIndex)
    }

    private static func assertUniquePlayPlaylist(
        _ query: String, store: RoutingHabitStore
    ) throws {
        guard let env = try environment() else { return }
        let verdict = try #require(
            env.intent.classify(query, habits: store),
            "did not classify at all: \"\(query)\"")
        #expect(verdict.intent == .operate, "\"\(query)\" classified \(verdict.intent), not operate")
        let winner = try #require(
            EmbeddingRouting.uniqueWinner(
                affinities: env.skills.affinities(in: query, habits: store),
                snapshot: env.snapshot),
            "\"\(query)\" had no unique Skill winner")
        #expect(
            winner.skill.id == SkillID("multimedia.play-playlist"),
            "\"\(query)\" uniquely picked \(winner.skill.id.rawValue), not multimedia.play-playlist")
    }

    /// Bare utterance — no world, no history. The floor case.
    // MARK: - Warm remarks, measured

    /// A KIND SENTENCE MUST NOT DISPATCH ANYTHING.
    ///
    /// THE BUG THIS EXISTS FOR: "You've done so much" dispatched
    /// `stop_dictation`. The path was corpus, not code — `writing.mary` seeded
    /// the stop-dictation fixture "That's it, we're done dictating.", which
    /// teaches a VALEDICTORY SHAPE rather than an act. The warm remark scored
    /// 0.67 against it, cleared the floor as the only skill in the field, and
    /// a lone unique winner is enough to promote a fail-closed converse turn
    /// to `operate` and reach the no-model dispatch.
    ///
    /// THE LESSON, AND IT GENERALISES: a phrase that is SAFE AS AN EXACT
    /// WHOLE-UTTERANCE MATCH is not automatically safe as an EMBEDDING SEED.
    /// The deterministic tier can hold "we are done" harmlessly — it matches
    /// that string and nothing else. The same words in a corpus teach the
    /// shape of every fond goodbye. Seed IMPERATIVES THAT NAME THE ACT
    /// ("Stop taking this down."), never statements that the work is finished.
    ///
    /// The assertion is one-directional on purpose: these sentences must reach
    /// no Skill. What Mary SAYS back is the model's business.
    @Test func warmRemarksReachNoSkill() throws {
        guard let environment = try Self.environment() else { return }
        guard let skills = SemanticSkillRequestIndex.build(
            records: environment.snapshot.records,
            vectorizer: try #require(NLUtteranceVectorizer.shared))
        else { return }

        let remarks = [
            "You've done so much",
            "thank you for everything",
            "that's really kind of you",
            "we're all done here",
            "that's it",
            "you have done a lot",
        ]
        var report: [String] = []
        var dispatchable: [String] = []
        for remark in remarks {
            let over = skills.affinities(in: remark)
                .filter { $0.value >= EmbeddingRouting.floor }
                .sorted { $0.value > $1.value }
            report.append("warm [\(remark)] -> \(over.isEmpty ? "none" : over.map { "\($0.key.rawValue)=\(String(format: "%.2f", $0.value))" }.joined(separator: " "))")
            // A lone winner needs no margin to be "unique", so ANY Skill over
            // the floor here is one promotion away from acting.
            if !over.isEmpty {
                dispatchable.append("[\(remark)] -> \(over.map(\.key.rawValue))")
            }
        }
        print(report.joined(separator: "\n"))
        #expect(dispatchable.isEmpty, "a warm remark reached a Skill: \(dispatchable)")
    }

    /// The genuine act still routes — the fix must not have bought silence by
    /// making stop-dictation unreachable.
    @Test func theRealStopStillReachesItsSkill() throws {
        guard let environment = try Self.environment() else { return }
        guard let skills = SemanticSkillRequestIndex.build(
            records: environment.snapshot.records,
            vectorizer: try #require(NLUtteranceVectorizer.shared))
        else { return }

        for utterance in ["stop dictating", "stop writing this down"] {
            let best = skills.affinities(in: utterance)
                .sorted { $0.value > $1.value }
                .first
            print("stop [\(utterance)] -> \(best.map { "\($0.key.rawValue)=\(String(format: "%.2f", $0.value))" } ?? "none")")
            #expect(
                best?.key.rawValue == "writing.stop-dictation",
                "[\(utterance)] should still name the stop Skill")
            #expect((best?.value ?? 0) >= EmbeddingRouting.floor)
        }
    }

    // MARK: - Application expertise, measured

    /// DOES NAMING AN APPLICATION RECALL ITS ABILITY?
    ///
    /// MEASURED FINDING, recorded here because it bounds what this seam can be
    /// trusted for: recall over seven similar applications is OVER-INCLUSIVE at
    /// the 0.62 floor. "Read me this browser tab" recalls Pages; "my manuscript
    /// app" recalls Safari. Both survive with the expertise habits stripped
    /// entirely, so they come from aliases and summaries, not from authored
    /// sentences — this is the index being generous, not the corpus being wrong.
    ///
    /// A SECOND FINDING, from the run that produced this test: habits that
    /// share a sentence FRAME across sibling packages ("read me the X", "what
    /// is in my Y") make recall strictly broader, because the distinguishing
    /// word is a small fraction of a short sentence vector. The shipped
    /// habits were re-authored to distinct shapes on that measurement.
    ///
    /// THE MARGIN THAT CAME OUT OF THIS. The gap report below is what
    /// `defaultDominanceMargin` was chosen from: on "read me this browser tab"
    /// the genuine sibling sits 0.043 behind the leader and the bystander
    /// 0.068, so 0.05 keeps one and cuts the other. It measurably fixed that
    /// probe (three applications down to the two browsers).
    ///
    /// IT CANNOT FIX A WRONG LEADER, and one probe still has one: "my
    /// manuscript app" puts SAFARI on top — its authored seed "what is the
    /// reader view showing" collides on the "…showing me" frame, the same
    /// sentence-shape collision that shows up whenever sibling packages share
    /// a phrasing. The margin then keeps the wrong leader and cuts the right
    /// runner-up. That is corpus work, not threshold work.
    ///
    /// Over-recall costs roster WIDTH, not a wrong act — the arbiter and
    /// eligibility still gate every Skill — so this reports the full picture
    /// and asserts the invariant the rule does guarantee.
    ///
    /// Probes are PARAPHRASES, never the authored sentences — an habit
    /// tuned to its own probe measures the probe.
    @Test func namingAnApplicationRecallsItsExpertise() throws {
        guard let environment = try Self.environment() else { return }
        let snapshot = environment.snapshot

        // CATEGORY, NOT IDENTITY, is the bar that matters. Pages and TextEdit
        // are genuinely alike, and recalling both for a note is imprecise
        // rather than wrong. Recalling a BROWSER for a manuscript scopes the
        // turn to an application from another world entirely — that is the
        // failure worth asserting.
        let category: [String: String] = [
            "pages": "prose", "textedit": "prose", "scrivener": "prose",
            "xcode": "code",
            "chrome": "browser", "safari": "browser",
            "apple-music": "music",
        ]
        let cases: [(String, String)] = [
            ("why won't this compile in the IDE", "code"),
            ("what is my manuscript app showing me", "prose"),
            ("read me this browser tab", "browser"),
            ("put a record on in the music app", "music"),
            ("type this into my plain text editor", "prose"),
        ]
        var report: [String] = []
        var wrong: [String] = []
        for (utterance, expected) in cases {
            // THE GAP REPORT the dominance margin is chosen from: every scored
            // expertise ability and how far it sits below the leader.
            let scored = snapshot.abilityAffinities(in: utterance)
                .filter { category[$0.key.rawValue] != nil }
                .sorted { $0.value > $1.value }
            if let lead = scored.first?.value {
                let gaps = scored.map {
                    String(format: "%@ %.3f(-%.3f)%@",
                           $0.key.rawValue, $0.value, lead - $0.value,
                           category[$0.key.rawValue] == expected ? "" : "*")
                }
                report.append("  gaps [\(utterance)] \(gaps.joined(separator: "  "))")
            }
            let apps = snapshot.requestedAbilities(in: utterance)
                .map(\.rawValue)
                .filter { category[$0] != nil }
            report.append(
                "expertise [\(utterance)] -> \(apps.sorted().joined(separator: ",").ifEmpty("none"))")
            let mistaken = apps.filter { category[$0] != expected }
            if !mistaken.isEmpty {
                wrong.append("[\(utterance)] wanted \(expected), also recalled \(mistaken.sorted())")
            }
            // THE INVARIANT THE DOMINANCE RULE GUARANTEES: nothing recalled
            // may sit further than the margin behind the leader. Asserted
            // against the REAL model, where the floor alone let half the
            // installed expertise through together.
            if let lead = scored.first?.value {
                for (id, score) in scored where apps.contains(id.rawValue) {
                    #expect(
                        score >= lead - SemanticAbilityRequestIndex.defaultDominanceMargin,
                        "[\(utterance)] recalled \(id.rawValue) at \(score), \(lead - score) behind the leader")
                }
            }
            // AND IT MUST STILL DISCRIMINATE — recalling every category is the
            // same as recalling nothing.
            let categories = Set(apps.compactMap { category[$0] })
            #expect(categories.count < 4, "[\(utterance)] recalled every category")
        }
        print(report.joined(separator: "\n"))
        print("expertise over-recall (known, roster width only): \(wrong)")
    }

    // MARK: - Window verbs, measured

    /// WHAT THE DELETED WINDOW GATE USED TO DECIDE. Listing windows and
    /// raising them were told apart by a five-word veto ("forward", "front",
    /// "raise", "unhide", "restore"); they are now told apart by the corpus,
    /// and a tie hands the turn to the model rather than guessing.
    ///
    /// Zero-argument verbs had NO fixtures before this phase — the hand-written
    /// gate meant the corpus never had to distinguish them.
    @Test func windowVerbsSeparateThroughTheShippedCorpus() throws {
        guard let environment = try Self.environment() else { return }
        let snapshot = environment.snapshot
        let offered = Set(
            snapshot.skills
                .filter { $0.skill.modelExposure.enabled }
                .map(\.reference.invocationName))

        // PARAPHRASES, NOT FIXTURES. A probe that repeats a seeded sentence
        // measures memorisation; these are how someone might actually put it.
        let cases: [(String, String)] = [
            ("show me everything I have open", "list_app_windows"),
            ("which windows are up right now", "list_app_windows"),
            ("raise them all to the front", "bring_all_windows_forward"),
            ("surface every window for me", "bring_all_windows_forward"),
            ("blow this up to fill the screen", "make_window_full_screen"),
            ("take this out of full screen", "exit_full_screen"),
        ]
        var report: [String] = []
        var wrong: [String] = []
        for (utterance, expected) in cases {
            let verdict = TurnTriage.verdict(
                query: utterance, registry: snapshot, offeredNames: offered)
            let picked = verdict.uniqueSkill?.reference.invocationName
            let promoted = verdict.promotedByUniqueSkill ? " promoted" : ""
            report.append(
                "window [\(utterance)] -> \(picked ?? "none")  intent=\(verdict.intent?.rawValue ?? "nil")\(promoted)")
            // THE DIRECTION THAT ACTS. Picking nothing costs a model round;
            // picking the WRONG verb moves the user's windows.
            if let picked, picked != expected {
                wrong.append("[\(utterance)] picked \(picked), expected \(expected)")
            }
        }
        print(report.joined(separator: "\n"))
        #expect(wrong.isEmpty, "\(wrong)")
    }

    // MARK: - The transform family, measured

    /// WHAT THE FORTY-VERB LIST USED TO ANSWER. `namesTransform` gated offer
    /// detection on both sides — the user asking for a change, and Mary's own
    /// reply proposing one — and a miss there quietly closes the acceptance
    /// road while a false positive arms a write.
    ///
    /// The floor that matters is the NEGATIVE one: a sentence that names no
    /// transformation must not join the family, because that is the direction
    /// that types something nobody asked for.
    @Test func theTransformFamilyResolvesThroughTheShippedCorpus() throws {
        guard let environment = try Self.environment() else { return }
        guard let index = SemanticSeedFamilyIndex.build(
            records: environment.snapshot.records,
            vectorizer: try #require(NLUtteranceVectorizer.shared))
        else { return }

        // DELIBERATELY NOT SEEDS. A probe that is itself in the corpus scores
        // 1.00 and measures nothing; these are paraphrases the packages have
        // never seen, so the number is generalization.
        let transforms = [
            "make it shorter",
            "trim this down a bit",
            "smarten up the wording here",
            "tidy up this method",
            "give the opening another pass",
        ]
        let offers = [
            "Should I clean that up for you?",
            "Do you want me to shorten it?",
        ]
        let notTransforms = [
            "what time is it",
            "read me the first paragraph",
            "what does this function do",
            "play some music",
            "how are you today",
        ]
        var report: [String] = []
        func score(_ text: String) -> Float {
            index.bestScore(SemanticSeedFamilyIndex.transform, in: text) ?? -1
        }
        for text in transforms + offers + notTransforms {
            report.append(String(format: "transform %.2f  [%@]", score(text), text))
        }
        print(report.joined(separator: "\n"))

        // THE DIRECTION THAT WRITES. A false positive here arms an offer road
        // that ends in typed bytes, so this half is asserted; the recall half
        // is reported and read.
        for text in notTransforms {
            #expect(
                !index.matches(SemanticSeedFamilyIndex.transform, in: text),
                "[\(text)] must not read as a transformation")
        }
    }

    // MARK: - The discipline axis, measured

    /// WHAT THE DELETED WORD LIST USED TO ANSWER, asked of the real model and
    /// the shipped corpus instead. `FocusOverride` carried fifty hand-picked
    /// cues ("readme", "docstring", "manuscript", "proofread"); these are the
    /// sentences it existed to get right, and they are now a measurement
    /// rather than an enumeration.
    ///
    /// A MISS HERE IS A CORPUS RESULT, not a reason to reinstate a list: the
    /// repair is habits on `coding.mary` / `writing.mary`, or a threshold
    /// moved on the strength of this run.
    /// AWARENESS IS A FACULTY, NOT A CRAFT THE USER ASKS FOR — and the axis
    /// it joined is scored against every discipline's authored corpus. Its
    /// package therefore carries no intent seeds and two bare tokens, so
    /// the sentences that need it stay the sentences already spoken to
    /// coding: a judgment question about code must still read as coding, and
    /// must never resolve to the thing that goes and looks it up.
    ///
    /// It also sorts FIRST in the registry (package ids order the axis, and
    /// "awareness" precedes "coding"), so a leak here would not be a tie —
    /// it would be a win.
    @Test func awarenessNeverAnswersForTheCraftItServes() throws {
        guard let environment = try Self.environment() else { return }
        let registry = environment.snapshot
        #expect(registry.disciplines.contains(AbilityID("awareness")),
                "precondition: the faculty is installed as a discipline")
        #expect(registry.disciplines.first == AbilityID("awareness"),
                "precondition: it sorts first, so a leak would win outright")

        let aboutCode = [
            "what do you think about this code",
            "is this function right",
            "refactor this function",
            "why does the build fail",
        ]
        var report: [String] = []
        for utterance in aboutCode {
            let verdict = registry.discipline(in: utterance)
            report.append("[\(utterance)] -> \(verdict?.rawValue ?? "none")")
        }
        print(report.joined(separator: "\n"))
        for utterance in aboutCode {
            #expect(registry.discipline(in: utterance) != WorkspaceFocus(AbilityID("awareness")),
                    "[\(utterance)]")
        }
    }

    @Test func disciplineCuesResolveThroughTheShippedCorpus() throws {
        guard let environment = try Self.environment() else { return }
        let registry = environment.snapshot

        let coding: [String] = [
            "refactor this function",
            "why does the build fail",
            "add a breakpoint here",
            "proofread my README",
        ]
        let writing: [String] = [
            "tighten this paragraph",
            "how does this chapter read",
            "rewrite the synopsis",
            "proofread this scene",
        ]
        var report: [String] = []
        for utterance in coding {
            let verdict = registry.discipline(in: utterance)
            report.append("coding  [\(utterance)] -> \(verdict?.rawValue ?? "none")")
        }
        for utterance in writing {
            let verdict = registry.discipline(in: utterance)
            report.append("writing [\(utterance)] -> \(verdict?.rawValue ?? "none")")
        }
        // MEASURED, THEN PRINTED. The suite's contract is that it reports what
        // the model actually does; the assertion below is the floor that
        // matters — a cue must never resolve to the WRONG craft, which is the
        // failure that silently routes a manuscript turn into Xcode.
        print(report.joined(separator: "\n"))
        for utterance in coding {
            #expect(registry.discipline(in: utterance) != .writing, "[\(utterance)]")
        }
        for utterance in writing {
            #expect(registry.discipline(in: utterance) != .coding, "[\(utterance)]")
        }
    }

    /// THE DISCIPLINES ARE WHATEVER SHIPPED. Pins the roster against the real
    /// packages so a paradigm typo in a `.mary` shows up as a missing craft.
    @Test func theShippedGraphDeclaresItsDisciplines() throws {
        guard let environment = try Self.environment() else { return }
        let disciplines = environment.snapshot.disciplines
        #expect(disciplines.contains(.coding))
        #expect(disciplines.contains(.writing))
        #expect(!disciplines.contains(AbilityID("xcode")), "an editor is expertise")
    }

    @Test func bareUtterancesUniquelyPickPlayPlaylist() throws {
        let store = RoutingHabitStore()
        try Self.assertUniquePlayPlaylist(Self.screenshotOpen, store: store)
        try Self.assertUniquePlayPlaylist(Self.screenshotInApp, store: store)
    }

    /// The composed multi-line query — utterance plus snapshot plus recent
    /// turns, exactly as `RoutingQuery.compose` builds it in production. A
    /// real NLEmbedding sees the whole string, unlike the fake cluster
    /// vectorizer (which only ever looks at the first line) — this is the
    /// one measurement `EmbeddingRoutingTests` cannot make.
    @Test func composedSnapshotAndHistoryQueriesStillUniquelyPickPlayPlaylist() throws {
        let store = RoutingHabitStore()
        for utterance in [Self.screenshotOpen, Self.screenshotInApp] {
            let query = RoutingQuery.compose(
                utterance: utterance,
                world: AmbientWorld.Snapshot(
                    sense: .workspace,
                    attention: .applications,
                    applicationID: "com.apple.dt.Xcode"),
                recentUserTurns: ["what's the time", "how's the weather"])
            try Self.assertUniquePlayPlaylist(query, store: store)
        }
    }
}
