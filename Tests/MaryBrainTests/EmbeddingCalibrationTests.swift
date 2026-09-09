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
        var snapshot: AbilityRuntime.Snapshot
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
        let snapshot = AbilityRuntime.Snapshot(
            records: records,
            validation: .init(),
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: MaryAdapterCatalog.adapters(),
                observers: MaryAdapterCatalog.observers()),
            semanticIndex: abilityIndex,
            semanticSkillIndex: skillIndex,
            semanticIntentIndex: intent,
            semanticApplicationIndex: SemanticApplicationIndex.build(
                records: records, vectorizer: vectorizer))
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

    // MARK: - The browsing lane, measured

    /// A REQUEST FOR A PAGE REACHES THE BROWSING LANE. The bench showed "0 selected of 120"
    /// for "Can you go to a fred again video on youtube" with Chrome on the stage: browsing
    /// shipped no route fixtures, so no sentence ever cleared the floor for any of its
    /// verbs, and the only thing left on the model's menu was the roster-bypassing
    /// `act_on_screen`.
    ///
    /// PROBES ARE PARAPHRASES, never the fixtures. The diagnostic index is built with no
    /// floor so a miss prints WHERE a skill sits — the production index drops everything
    /// below 0.62 and cannot say. The habit store is fresh, so this measures the corpus and
    /// not what this machine has learned.
    @Test func browsingRequestsResolveThroughTheShippedCorpus() throws {
        guard let environment = try Self.environment() else { return }
        let snapshot = environment.snapshot
        let store = RoutingHabitStore()
        let vectorizer = try #require(NLUtteranceVectorizer.shared)
        let diagnostic = try #require(SemanticSkillRequestIndex.build(
            records: snapshot.records, vectorizer: vectorizer, threshold: 0))
        let offered = Set(
            snapshot.skills
                .filter { $0.skill.modelExposure.enabled }
                .map(\.reference.invocationName))

        func top(_ utterance: String) -> String {
            diagnostic.affinities(in: utterance, habits: store)
                .sorted { $0.value > $1.value }
                .prefix(6)
                .map { "\($0.key.rawValue)=\(String(format: "%.2f", $0.value))" }
                .joined(separator: " ")
        }
        func reached(_ verdict: TurnTriage.Verdict) -> [String] {
            verdict.skillAffinities.keys
                .compactMap { snapshot.skill(id: $0)?.reference.invocationName }
                .sorted()
        }

        // THE DIRECTION THAT ACTS: a search must pick search_web, and nothing else — the
        // confidence lane dispatches on a unique win, so a tie here costs a model round and
        // a wrong pick navigates somebody's tab.
        // THE JOURNEY TOOK THREE OF THESE, AND IS THE BETTER ANSWER TO THEM.
        //
        // PIN: ROUND 8 GAVE THE LANE A VERB FOR "FIND SOMETHING AND OPEN IT".
        // These four all used to be `search_web`, because searching was the only
        // thing the lane could do — and three of them are not asking to see a
        // list. "Find me a clip on youtube" asks to WATCH it: it names a subject
        // and a site, which is precisely what `watch_video` searches with and
        // chooses on. What still belongs to `search_web` is the sentence that
        // asks for the results themselves. Both must still be an OPERATE turn
        // reaching ONE winner, which is what this block was written to hold.
        let searches: [(String, String)] = [
            ("Can you go to a fred again video on youtube", "watch_video"),
            ("find me a fred again clip on youtube", "watch_video"),
            ("look up a fireplace video for me", "watch_video"),
            ("search the web for alpine boots", "search_web"),
        ]
        // THE SITE PATH, REPORTED. Every round of a turn projects the roster from the same
        // sentence, so the chain (open the site, fill its search box, press the first
        // video) is only reachable when its verbs are offered together. Printed, not
        // asserted: a miss here is the argument for a composite verb, not a failing build.
        let sitePath = [
            "go to youtube and search there for fred again",
            "search this site for fred again",
            "open the first video",
        ]
        // A question about the page must not become a search.
        let questions = ["what is this page", "which tab am I on"]

        var report: [String] = []
        var wrong: [String] = []
        for (utterance, wanted) in searches {
            let verdict = TurnTriage.verdict(
                query: utterance, registry: snapshot, offeredNames: offered, habits: store)
            let picked = verdict.uniqueSkill?.reference.invocationName
            report.append(
                "search [\(utterance)] -> \(picked ?? "none")  \(verdict.intentDescription)  top: \(top(utterance))")
            if verdict.intent != .operate {
                wrong.append("[\(utterance)] read as \(verdict.intent?.rawValue ?? "nil"), not operate")
            }
            if picked != wanted {
                wrong.append("[\(utterance)] picked \(picked ?? "none"), expected \(wanted)")
            }
        }
        for utterance in sitePath {
            let verdict = TurnTriage.verdict(
                query: utterance, registry: snapshot, offeredNames: offered, habits: store)
            report.append(
                "site   [\(utterance)] -> offered \(reached(verdict).joined(separator: ","))  top: \(top(utterance))")
        }
        for utterance in questions {
            let verdict = TurnTriage.verdict(
                query: utterance, registry: snapshot, offeredNames: offered, habits: store)
            let names = reached(verdict)
            report.append(
                "ask    [\(utterance)] -> \(names.joined(separator: ","))  top: \(top(utterance))")
            if names.contains("search_web") {
                wrong.append("[\(utterance)] reached search_web")
            }
        }
        print(report.joined(separator: "\n"))
        #expect(wrong.isEmpty, "\(wrong)")
    }

    // MARK: - The transport twins, measured

    /// TWO SKILLS, TWO SURFACES, NEARLY ONE SENTENCE — and the reported bug.
    ///
    /// `multimedia.control-playback` and `browsing.control-media` both described
    /// themselves as "play, pause, mute, set the volume", differing only in a
    /// trailing clause nobody says out loud. `uniqueWinner` needs a 0.04 margin,
    /// so the pair reliably crowded each other out, every "pause the music" cost
    /// a model round, and the model was reading a standing prompt fragment that
    /// argued against the media keys. The summaries now name their surfaces and
    /// each skill states its own sentences as fixtures.
    ///
    /// MEASURED, NOT ASSUMED: the report prints both affinities and the margin
    /// whichever way it goes, so a regression says how far it moved.
    @Test func theTransportTwinsSeparate() throws {
        guard let environment = try Self.environment() else { return }
        let store = RoutingHabitStore()
        let vectorizer = try #require(NLUtteranceVectorizer.shared)
        let diagnostic = try #require(SemanticSkillRequestIndex.build(
            records: environment.snapshot.records, vectorizer: vectorizer, threshold: 0))

        let music = SkillID("multimedia.control-playback")
        let video = SkillID("browsing.control-media")
        var report: [String] = []
        var wrong: [String] = []

        func measure(_ utterance: String, expecting wanted: SkillID) {
            let scores = diagnostic.affinities(in: utterance, habits: store)
            let musicScore = scores[music] ?? 0
            let videoScore = scores[video] ?? 0
            let winner = EmbeddingRouting.uniqueWinner(
                affinities: environment.skills.affinities(in: utterance, habits: store),
                snapshot: environment.snapshot)
            report.append(String(
                format: "twin   [%@] -> %@   playback=%.2f media=%.2f margin=%.2f",
                utterance,
                winner?.skill.id.rawValue ?? "none",
                musicScore, videoScore, abs(musicScore - videoScore)))
            guard let winner else {
                wrong.append("[\(utterance)] had no unique winner")
                return
            }
            if winner.skill.id != wanted {
                wrong.append(
                    "[\(utterance)] picked \(winner.skill.id.rawValue), expected \(wanted.rawValue)")
            }
        }

        // THE REPORTED SENTENCE, and the ones beside it.
        measure("can you pause the music", expecting: music)
        measure("pause the music", expecting: music)
        measure("pause the song", expecting: music)
        // The other surface must stay reachable by its own words.
        measure("pause the video", expecting: video)

        print(report.joined(separator: "\n"))
        #expect(wrong.isEmpty, "\(wrong)")
    }

    /// THE REPORTED SENTENCE, THROUGH EVERY GATE THE TURN LOOP APPLIES.
    ///
    /// "Can you pause the music" never worked, and the twin measurement above
    /// only proves the corpus half. This walks the rest of the shortcut exactly
    /// as `MaryBrain.runTurnBody` does — the roster with a browser in front, the
    /// unique winner among the OFFERED names, the argument shape, and the
    /// arguments themselves — so a regression in any one of them fails here
    /// rather than on someone's machine.
    ///
    /// A BROWSER IS IN FRONT ON PURPOSE. That is the reported situation and the
    /// one that used to strike the whole multimedia discipline out before the
    /// roster was read.
    @Test func pausingTheMusicDispatchesWithNoModelRound() throws {
        guard let environment = try Self.environment() else { return }
        let snapshot = environment.snapshot
        let store = RoutingHabitStore()
        let utterance = "can you pause the music"

        // THE ROSTER, with a browser's target class in view.
        let arbitration = AbilityRosterRehearsal.arbitration(
            snapshot: snapshot,
            utterance: utterance,
            targetClasses: ["web-page", "document-window"],
            habits: store)
        let offered = Set(arbitration.trace.selected.map(\.reference.invocationName))
        #expect(
            offered.contains("control_playback"),
            "the transport skill must be offered with a browser in front — offered: \(offered.sorted())")

        // THE ELECTION SAID SO IN ITS OWN WORDS.
        let multimedia = arbitration.trace.election.first {
            $0.abilityID.rawValue == "multimedia"
        }
        #expect(multimedia?.isActive == true, "multimedia must stand: \(multimedia?.reason ?? "no row")")

        // THE PICK, among the names actually offered.
        let verdict = TurnTriage.verdict(
            query: utterance, registry: snapshot, offeredNames: offered, habits: store)
        let winner = try #require(verdict.uniqueSkill, "no unique winner")
        #expect(winner.skill.id == SkillID("multimedia.control-playback"))

        // THE SHAPE, and then the arguments the shortcut would send.
        #expect(
            EmbeddingRouting.confidenceShape(of: winner, utterance: utterance) == .singleEnum,
            "an enum value the sentence names must qualify for the shortcut")
        let filled = EmbeddingRouting.filledArguments(
            for: winner, utterance: utterance, applicationID: nil)
        #expect(
            filled.json == #"{"action":"pause"}"#,
            "the shortcut must send the value they said, got \(filled.json)")
        print("lane   [\(utterance)] -> confidence \(winner.reference.invocationName) \(filled.json)")
        print("       peeled: \(filled.stages.joined(separator: " | "))")
    }

    /// THE VIDEO'S OWN TRANSPORT, ACROSS EVERY VERB IT DECLARES.
    ///
    /// THE REPORTED BUG: "mute the video" ran a WEB SEARCH. `theTransportTwins`
    /// above only ever measured PAUSE, and pause is the one verb
    /// `browsing.control-media` had fixtures for — the corpus said "Go full
    /// screen", "Pause the video", "Pause the video in this tab" and nothing
    /// about mute, sound, volume or skipping. Meanwhile `search_web` carries
    /// seven fixtures that all say "video", and `multimedia.control-playback`
    /// carries eight that include "Turn it down a bit". So a sentence naming
    /// any OTHER page-player verb had a corpus full of rivals and none of its
    /// own, no unique winner, and a model round that read "video" and searched.
    ///
    /// EVERY DECLARED ENUM VALUE IS A SENTENCE SOMEBODY SAYS. The assertion is
    /// per-verb rather than per-skill for that reason: a transport that answers
    /// to "pause" and not to "mute" is not a transport.
    ///
    /// Probes are PARAPHRASES, never the fixtures themselves.
    @Test func everyPageTransportVerbReachesTheVideo() throws {
        guard let environment = try Self.environment() else { return }
        let snapshot = environment.snapshot
        let store = RoutingHabitStore()
        let vectorizer = try #require(NLUtteranceVectorizer.shared)
        let diagnostic = try #require(SemanticSkillRequestIndex.build(
            records: snapshot.records, vectorizer: vectorizer, threshold: 0))
        let offered = Set(
            snapshot.skills
                .filter { $0.skill.modelExposure.enabled }
                .map(\.reference.invocationName))

        let video = SkillID("browsing.control-media")
        let music = SkillID("multimedia.control-playback")

        // (sentence, the skill it must reach, the enum value it must carry)
        let cases: [(String, SkillID, String?)] = [
            ("mute the video", video, "mute"),
            ("unmute the video", video, "unmute"),
            ("turn the sound off on the video", video, "mute"),
            ("mute this video", video, "mute"),
            ("skip to the middle of the video", video, "seek"),
            ("play the video", video, "play"),
            // THE OTHER SURFACE MUST NOT MOVE. Every repair below is corpus
            // work on the video side, and corpus work is exactly what can
            // steal a sentence that was already answered correctly.
            ("mute the music", music, "mute"),
            ("pause the music", music, "pause"),
            ("can you pause the music", music, "pause"),
        ]

        var report: [String] = []
        var wrong: [String] = []
        for (utterance, wanted, wantedValue) in cases {
            let scores = diagnostic.affinities(in: utterance, habits: store)
            let top = scores.sorted { $0.value > $1.value }.prefix(4)
                .map { "\($0.key.rawValue)=\(String(format: "%.2f", $0.value))" }
                .joined(separator: " ")
            let verdict = TurnTriage.verdict(
                query: utterance, registry: snapshot, offeredNames: offered, habits: store)
            let winner = verdict.uniqueSkill
            let shape = winner.flatMap {
                EmbeddingRouting.confidenceShape(of: $0, utterance: utterance)
            }
            let filled = winner.map {
                EmbeddingRouting.filledArguments(
                    for: $0, utterance: utterance, applicationID: nil).json
            } ?? "—"
            report.append(String(
                format: "verb   [%@] -> %@  shape=%@ args=%@  top: %@",
                utterance,
                winner?.skill.id.rawValue ?? "none",
                shape.map { "\($0)" } ?? "nil",
                filled,
                top))

            guard let winner else {
                wrong.append("[\(utterance)] had no unique winner")
                continue
            }
            if winner.skill.id != wanted {
                wrong.append(
                    "[\(utterance)] picked \(winner.skill.id.rawValue), expected \(wanted.rawValue)")
                continue
            }
            // AND THE SHORTCUT MUST BE ABLE TO SEND IT. Reaching the skill and
            // then paying for a model round to fill one spoken enum value is
            // the same latency the whole confidence lane exists to remove.
            if let wantedValue {
                if shape != .singleEnum {
                    wrong.append("[\(utterance)] shape \(shape.map { "\($0)" } ?? "nil"), expected singleEnum")
                } else if !filled.contains("\"\(wantedValue)\"") {
                    wrong.append("[\(utterance)] filled \(filled), expected action \(wantedValue)")
                }
            }
        }
        print(report.joined(separator: "\n"))
        #expect(wrong.isEmpty, "\(wrong)")
    }

    /// "MUTE THE VIDEO" THROUGH EVERY GATE THE TURN LOOP APPLIES, with a browser
    /// in front — the twin of `pausingTheMusicDispatchesWithNoModelRound`.
    ///
    /// The corpus measurement above says the skill tier is not the fault: the
    /// sentence reaches `browsing.control-media` at 0.77 outright. So this walks
    /// the rest — the ROSTER (is the skill even offered with a browser on the
    /// stage), the INTENT (the confidence lane fires only on `.operate`), the
    /// unique winner among the OFFERED names, and the arguments — because the
    /// reported failure was a WEB SEARCH, which is what a model round does with
    /// a sentence containing "video" when the deterministic lane declined.
    @Test func mutingTheVideoDispatchesWithNoModelRound() throws {
        guard let environment = try Self.environment() else { return }
        let snapshot = environment.snapshot
        let store = RoutingHabitStore()

        var report: [String] = []
        var wrong: [String] = []
        for utterance in ["mute the video", "unmute the video", "pause the video"] {
            let arbitration = AbilityRosterRehearsal.arbitration(
                snapshot: snapshot,
                utterance: utterance,
                targetClasses: ["web-page", "document-window"],
                habits: store)
            let offered = Set(arbitration.trace.selected.map(\.reference.invocationName))
            let browsing = arbitration.trace.election.first {
                $0.abilityID.rawValue == "browsing"
            }
            let verdict = TurnTriage.verdict(
                query: utterance, registry: snapshot, offeredNames: offered, habits: store)
            let winner = verdict.uniqueSkill
            let shape = winner.flatMap {
                EmbeddingRouting.confidenceShape(of: $0, utterance: utterance)
            }
            report.append(String(
                format: "gates  [%@] intent=%@ offered=%d control_media=%@ browsing=%@ -> %@ shape=%@",
                utterance,
                verdict.intent?.rawValue ?? "nil",
                offered.count,
                offered.contains("control_media") ? "yes" : "NO",
                browsing?.isActive == true ? "stands" : "struck: \(browsing?.reason ?? "no row")",
                winner?.skill.id.rawValue ?? "none",
                shape.map { "\($0)" } ?? "nil"))

            // THE FOUR GATES, each named so a failure says which one.
            if !offered.contains("control_media") {
                wrong.append("[\(utterance)] control_media was not offered")
            }
            // The confidence lane runs only on an ACTION turn. An `.ask` here
            // is a model round, and a model round with "video" in the sentence
            // is where the reported web search came from.
            if verdict.intent != .operate {
                wrong.append("[\(utterance)] read as \(verdict.intent?.rawValue ?? "nil"), not operate")
            }
            if winner?.skill.id != SkillID("browsing.control-media") {
                wrong.append("[\(utterance)] picked \(winner?.skill.id.rawValue ?? "none")")
            }
            if shape != .singleEnum {
                wrong.append("[\(utterance)] shape \(shape.map { "\($0)" } ?? "nil")")
            }
        }
        print(report.joined(separator: "\n"))
        #expect(wrong.isEmpty, "\(wrong)")
    }

    /// WHAT THE ROSTER OFFERS WHEN THE BROWSER IS NOT THE LEAD — the situation
    /// the reported bug actually describes. A video plays in a background tab;
    /// the person is in another window, or looking at Mary; they say "mute the
    /// video". `browsing`'s Ability eligibility is `targetClass: web-page`, and
    /// a lead that is not a browser does not supply it.
    ///
    /// REPORTED, NOT ASSERTED, for the classes it cannot decide: what this has
    /// to show is WHICH skills survive, because a roster that keeps `search_web`
    /// while dropping `control_media` is precisely a sentence about a video
    /// arriving at a model with only a search to answer it.
    @Test func theTransportSurvivesALeadThatIsNotTheBrowser() throws {
        guard let environment = try Self.environment() else { return }
        let snapshot = environment.snapshot
        let store = RoutingHabitStore()

        let stages: [(String, [String])] = [
            ("browser in front", ["web-page", "document-window"]),
            ("an editor in front", ["document-window", "source-file"]),
            ("nothing named", []),
        ]
        var report: [String] = []
        for (label, classes) in stages {
            for utterance in ["mute the video", "pause the video", "mute the music"] {
                let arbitration = AbilityRosterRehearsal.arbitration(
                    snapshot: snapshot, utterance: utterance,
                    targetClasses: Set(classes), habits: store)
                let offered = arbitration.trace.selected
                    .map(\.reference.invocationName).sorted()
                let verdict = TurnTriage.verdict(
                    query: utterance, registry: snapshot,
                    offeredNames: Set(offered), habits: store)
                report.append(String(
                    format: "stage  [%@ / %@] offered=%@ -> %@",
                    label, utterance,
                    offered.isEmpty ? "none" : offered.joined(separator: ","),
                    verdict.uniqueSkill?.skill.id.rawValue ?? "none"))
            }
        }
        print(report.joined(separator: "\n"))
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

// MARK: - Which application a system-control Skill was pointed at
//
// THE DISTANCE TIER, MEASURED. `ApplicationReferenceResolutionTests` covers
// the exact-naming tier on a snapshot with no index at all; only here, against
// the real on-device model and every shipped package, is the ranking itself
// exercised. Numbers are printed rather than asserted tightly, for the reason
// this whole suite exists: it measures, it does not guess.
extension EmbeddingCalibrationTests {

    private func openerAndSnapshot() throws -> (AbilityRuntimeSkill, AbilityRuntime.Snapshot)? {
        guard let environment = try Self.environment() else { return nil }
        guard let skill = environment.snapshot.skill(
            id: SkillID("window-management.open-new-window")) else { return nil }
        return (skill, environment.snapshot)
    }

    /// THE REPORTED SENTENCE, with nothing asserted by the caller — the whole
    /// answer has to come from the words and the packages' own names.
    @Test func theWordsAloneReachTheRightApplication() throws {
        guard let (skill, snapshot) = try openerAndSnapshot() else { return }
        let verdict = try #require(ApplicationReferenceResolution.resolve(
            for: skill, snapshot: snapshot,
            utterance: "Open a new textedit window."))
        for row in verdict.candidates.prefix(6) {
            print(String(
                format: "[application] %@ %@ %@",
                row.applicationID,
                row.score.map { String(format: "%.3f", $0) } ?? "—",
                row.standing.rawValue))
        }
        #expect(verdict.chosen?.applicationID == "textedit")
    }

    /// ASR SAYS "TEXT EDIT". The package's own alias carries it, and the
    /// two-word form must not drift to a different editor.
    @Test func theSpokenTwoWordFormReachesTheSameApplication() throws {
        guard let (skill, snapshot) = try openerAndSnapshot() else { return }
        let verdict = try #require(ApplicationReferenceResolution.resolve(
            for: skill, snapshot: snapshot,
            utterance: "Open a new text edit window."))
        #expect(verdict.chosen?.applicationID == "textedit")
    }

    @Test func aBrowserSentenceReachesTheBrowser() throws {
        guard let (skill, snapshot) = try openerAndSnapshot() else { return }
        let verdict = try #require(ApplicationReferenceResolution.resolve(
            for: skill, snapshot: snapshot,
            utterance: "Open a new safari window."))
        #expect(verdict.chosen?.applicationID == "safari")
    }

    /// NAMING NOTHING MUST RESOLVE NOTHING. This is the measurement that
    /// matters most: a bare "open a new window" that confidently picked an
    /// application would open the wrong one silently, forever.
    @Test func aBareRequestNamesNoApplication() throws {
        guard let (skill, snapshot) = try openerAndSnapshot() else { return }
        let verdict = try #require(ApplicationReferenceResolution.resolve(
            for: skill, snapshot: snapshot, utterance: "Open a new window."))
        let best = verdict.candidates.compactMap(\.score).max() ?? 0
        print(String(format: "[application] bare request — best %.3f", best))
        #expect(verdict.chosen == nil)
    }

    /// An application no package claims cannot be reached, and the honest
    /// answer is nothing rather than the nearest editor that does have one.
    @Test func anUnclaimedApplicationResolvesToNothing() throws {
        guard let (skill, snapshot) = try openerAndSnapshot() else { return }
        let verdict = try #require(ApplicationReferenceResolution.resolve(
            for: skill, snapshot: snapshot,
            utterance: "Open a new calculator window."))
        for row in verdict.candidates.prefix(4) {
            print(String(
                format: "[application] calculator -> %@ %@",
                row.applicationID,
                row.score.map { String(format: "%.3f", $0) } ?? "—"))
        }
        #expect(verdict.chosen == nil)
    }

    /// "NOTES" IS TEXTEDIT'S OWN WORD, and this pins that on purpose.
    ///
    /// `textedit.mary` declares the trigger tokens `note` and `notes` — its
    /// `documentNoun` is "note" — so in this roster "open a new Notes window"
    /// resolves to TextEdit and NOT to Apple's Notes, which ships no package
    /// and therefore does not exist as far as the reverse lookup is concerned.
    ///
    /// That is the closed world working as declared, not a bug in the ranking:
    /// the fix, if this is ever the wrong answer for somebody, is to stop
    /// claiming the word in `textedit.mary` or to ship a package for Notes —
    /// a data change either way, which is the whole point of the design.
    @Test func aWordAPackageClaimsResolvesToThatPackage() throws {
        guard let (skill, snapshot) = try openerAndSnapshot() else { return }
        let verdict = try #require(ApplicationReferenceResolution.resolve(
            for: skill, snapshot: snapshot,
            utterance: "Open a new Notes window."))
        #expect(verdict.chosen?.applicationID == "textedit")
    }
}
