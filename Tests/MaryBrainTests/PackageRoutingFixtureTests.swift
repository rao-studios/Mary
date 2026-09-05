//
//  PackageRoutingFixtureTests.swift
//  MaryBrainTests
//
//  WHAT: Package route fixtures actually fire; dead intent predicates are visible.
//  OUT:  AmbientIntent × package eligibility
//  PIN:  Validator cannot see AmbientIntent — this suite lives in Brain
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct PackageRoutingFixtureTests {

    private static func shippedPackages(_ abilities: URL) throws -> [MaryAbilityPackage] {
        try FileManager.default
            .contentsOfDirectory(at: abilities, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "mary" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try AbilityPackageCodec.load(from: $0) }
    }

    /// Every `intent` predicate anywhere in a package's routing — Ability-level
    /// or Skill-level, at any depth of `all`/`any`/`not` — names a real
    /// `AmbientIntent` case. Walked once and reused by both checks below.
    private static func intentValues(in predicate: RoutingPredicate) -> [String] {
        var values: [String] = []
        if predicate.kind == .intent, let value = predicate.value {
            values.append(value)
        }
        for child in predicate.children {
            values.append(contentsOf: intentValues(in: child))
        }
        return values
    }

    private static func allPredicates(in policy: RoutingPolicySchema) -> [RoutingPredicate] {
        (policy.eligibility.map { [$0] } ?? []) + policy.excludes
    }

    @Test func everyIntentPredicateNamesARealAmbientIntent() throws {
        guard let abilities = InstalledPackages.installed() else { return }
        let packages = try Self.shippedPackages(abilities)
        #expect(!packages.isEmpty, "Abilities/ holds no .mary packages")

        let knownIntents = Set(AmbientIntent.allCases.map(\.rawValue))
        for package in packages {
            let policies = [package.ability.routing] + package.skills.map(\.routing)
            for policy in policies {
                for predicate in Self.allPredicates(in: policy) {
                    for value in Self.intentValues(in: predicate) {
                        #expect(
                            knownIntents.contains(value),
                            """
                            \(package.package.id.rawValue) declares intent \
                            "\(value)", which is not an AmbientIntent case \
                            (\(AmbientIntent.allCases.map(\.rawValue).sorted().joined(separator: ", "))) \
                            — this predicate arm can never fire.
                            """)
                    }
                }
            }
        }
    }

    /// Whether a predicate tree names only the two kinds an `AbilityFixture`
    /// cannot possibly supply — `intent` and `workspaceFamily` both come out of
    /// a live turn's classifier and route arbitration, not out of a static
    /// utterance string. `writing.mary`'s eligibility leans on both and is
    /// correctly live in production; a fixture-only context has no way to
    /// prove or disprove that, so this check has to recognize the difference
    /// between "unprovable from here" and "provably dead" rather than
    /// reporting the former as the latter.
    private static func dependsOnRuntimeClassifiedContext(_ predicate: RoutingPredicate) -> Bool {
        if predicate.kind == .intent || predicate.kind == .workspaceFamily { return true }
        return predicate.children.contains(where: dependsOnRuntimeClassifiedContext)
    }

    /// Builds the routing context a `route` fixture claims, and checks the
    /// OWNING ABILITY's routing policy — the gate `expectedSkill` must pass
    /// before its Skill is even in the election — actually admits it.
    ///
    /// SCOPED TO WHAT A FIXTURE CAN PROVE. An Ability whose eligibility names
    /// `intent` or `workspaceFamily` anywhere in its tree is skipped (and said
    /// aloud, not silently) rather than failed: this context has no classifier
    /// behind it, so an eligibility miss there is not evidence of anything.
    /// After the routing fix, `coding` and `multimedia` express eligibility
    /// purely in `targetClass`/`utteranceToken`/`utterancePhrase` — exactly the
    /// kinds a fixture DOES carry — so both become fully checked here.
    @Test func everyRouteFixtureAdmitsTheAbilityOwningItsExpectedSkill() throws {
        guard let abilities = InstalledPackages.installed() else { return }
        let packages = try Self.shippedPackages(abilities)

        var checked = 0
        for package in packages {
            // NO PREDICATE MEANS ALWAYS ADMITTED — fully provable from a
            // fixture, unlike a predicate that names `intent`/`workspaceFamily`.
            // Only the latter is unprovable here; a nil eligibility is the
            // easiest case, not a reason to skip it.
            if let eligibility = package.ability.routing.eligibility,
               Self.dependsOnRuntimeClassifiedContext(eligibility) {
                print(
                    """
                    [routing-fixtures] SKIPPED (eligibility depends on a live \
                    classifier, not fixture data): \(package.package.id.rawValue)
                    """)
                continue
            }
            for fixture in package.fixtures where fixture.expectedDisposition == "route" {
                guard let expectedSkill = fixture.expectedSkill else { continue }
                guard package.skills.contains(where: { $0.id == expectedSkill }) else {
                    Issue.record(
                        """
                        \(package.package.id.rawValue) fixture \(fixture.id) names \
                        \(expectedSkill.rawValue), which is not one of its own Skills
                        """)
                    continue
                }
                let context = AbilityRoutingContext(
                    utterance: fixture.utterance,
                    targetClasses: fixture.targetClass.map { [$0] } ?? [],
                    interactions: Set(fixture.interactions))
                checked += 1
                #expect(
                    AbilityRoutingEvaluator.isEligible(package.ability.routing, in: context),
                    """
                    \(package.package.id.rawValue) fixture "\(fixture.utterance)" asserts \
                    routing to \(expectedSkill.rawValue), but the owning Ability's routing \
                    policy does not admit this context — the fixture's own claim is false.
                    """)
            }
        }
        #expect(checked > 0, "no shipped package/fixture combination was exercised")
    }

    // MARK: - The claim, actually run

    /// EVERY `route` FIXTURE IS A PROMISE, AND THIS IS THE ONE TEST THAT MAKES
    /// THE PACKAGE KEEP IT.
    ///
    /// The check above proves only that the owning Ability's routing POLICY
    /// admits the fixture's context — the weakest half of the claim. A fixture
    /// says something much stronger: say this sentence, with that kind of thing
    /// in front, and THIS Skill answers. Nothing ran that. `pause-the-music`
    /// asserted `multimedia.control-playback` while, with a browser in front,
    /// the Ability election struck the whole discipline out before the roster
    /// was read, and with `browsing.control-media` describing itself in almost
    /// the same words the corpus could not separate them either. The package
    /// stated the truth and the build agreed with it while the app did the
    /// opposite.
    ///
    /// OPT-IN, like the calibration suite and for the same reason: it needs the
    /// on-device embedding asset, which CI does not have. A missing index would
    /// otherwise silently pass every case.
    @Test func everyRouteFixtureReachesItsSkillThroughTheRealRoster() throws {
        guard ProcessInfo.processInfo.environment["MARY_EMBEDDING_CALIBRATION"] == "1"
        else { return }
        guard let abilities = InstalledPackages.installed() else { return }
        guard let vectorizer = NLUtteranceVectorizer.shared else { return }
        let packages = try Self.shippedPackages(abilities)
        let records = packages.map { package in
            AbilityPackageRecord(
                package: package, source: .installed,
                sourceURL: abilities.appendingPathComponent("\(package.package.id.rawValue).mary"),
                validation: .init(), rawData: Data())
        }
        // THE REALIZED BINDINGS ARE A SECOND INPUT, and without them every Skill
        // an application realizes rather than binds itself (`build_project`,
        // `open_player`) reads `.blocked` before routing is consulted — a fact
        // about the fixture, not about the routing this test measures.
        let compilation = PluginCompiler.compile(
            packages: packages,
            nativeAdapterManifests: [],
            grantedPermissions: { _ in [.accessibility, .files, .network, .screenRecording] })
        let snapshot = AbilityRuntime.Snapshot(
            records: records,
            validation: .init(),
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: MaryAdapterCatalog.adapters(),
                observers: MaryAdapterCatalog.observers()),
            plugins: compilation,
            semanticSkillIndex: SemanticSkillRequestIndex.build(
                records: records, vectorizer: vectorizer))
        // A FRESH LEDGER: this measures the shipped corpus, never what this
        // machine has learned.
        let habits = RoutingHabitStore()

        var report: [String] = []
        var wrong: [String] = []
        var checked = 0
        for package in packages {
            for fixture in package.fixtures where fixture.expectedDisposition == "route" {
                guard let expected = fixture.expectedSkill,
                      package.skills.contains(where: { $0.id == expected })
                else { continue }
                checked += 1
                let arbitration = AbilityRosterRehearsal.arbitration(
                    snapshot: snapshot,
                    utterance: fixture.utterance,
                    targetClasses: fixture.targetClass.map { [$0] } ?? [],
                    // WHAT THE FIXTURE ITSELF STATES. A fixture declaring a text
                    // selection is describing a turn where one stands.
                    interactions: Set(fixture.interactions),
                    habits: habits)
                let offered = arbitration.trace.selected.contains {
                    $0.reference.skillID == expected
                }
                guard !offered else { continue }
                // WHY NOT, in the arbitrator's own words, plus where the corpus
                // actually put it — the two facts a person needs to fix it.
                let decision = arbitration.trace.decisions.first {
                    $0.reference.skillID == expected
                }
                let near = arbitration.trace.decisions
                    .filter { $0.affinity != nil }
                    .sorted { ($0.affinity ?? 0) > ($1.affinity ?? 0) }
                    .prefix(3)
                    .map { "\($0.reference.invocationName)=\(String(format: "%.2f", $0.affinity ?? 0))" }
                    .joined(separator: " ")
                let owner: String = package.package.id.rawValue
                let why: String = decision.map { found -> String in
                    found.disposition.rawValue + " — " + found.reason
                } ?? "no decision"
                var line = "[" + owner + "] \"" + fixture.utterance + "\" -> "
                line += expected.rawValue + " NOT offered: " + why
                line += "   top: " + near
                report.append(line)
                // WHAT A REHEARSAL MAY JUDGE, AND WHAT IT MAY ONLY REPORT.
                //
                // A Skill withheld because the WORDS never reached it, or
                // because its Ability lost an election, or because a sibling
                // outranked it, is a routing verdict this pass computed in full
                // — that is the class of defect this test exists for, and it
                // fails the build. A Skill withheld for a missing Perception or
                // an unavailable adapter is an ENVIRONMENT fact: a rehearsal
                // cannot stage a focused workspace or install a permission, so
                // asserting on it would be asserting on this machine. Those are
                // printed, every time, so a person reading the report still sees
                // them — silence would be its own kind of lie.
                switch decision?.disposition {
                case .inactiveAbility, .conflictLost, .none:
                    wrong.append(line)
                case .ineligible where decision?.reason
                    == "does not match this turn's embedding roster":
                    wrong.append(line)
                default:
                    break
                }
            }
        }
        if !report.isEmpty {
            print("[routing-fixtures] \(report.count) of \(checked) did not reach their Skill:")
            print(report.joined(separator: "\n"))
        }
        #expect(checked > 0, "no route fixture was exercised")
        #expect(
            wrong.isEmpty,
            "\(wrong.count) fixture(s) are unreachable for a ROUTING reason: \(wrong)")
    }

    // MARK: - Bindings nobody publishes

    /// EVERY BINDING NAMES AN OPERATION SOME ADAPTER ACTUALLY PUBLISHES.
    ///
    /// A binding to an operation nothing implements is not a routing problem
    /// and never fails loudly: the Skill simply reads `.blocked` forever and
    /// vanishes from every roster, in silence, for the life of the package.
    /// `mary-package-probe check` cannot see this — it validates the package
    /// graph with no adapter inventory in view — so the only place the two
    /// halves meet is here.
    ///
    /// PIN: ALWAYS ON, unlike the routing check above. This needs no embedding
    /// asset and no machine state: it is a question about the build.
    /// KNOWN AND NAMED. `window-management.bring-application-forward` binds
    /// `mac/open_app`, and no adapter is called `mac`. It is recorded here
    /// rather than quietly tolerated, so the next dead binding fails the build
    /// instead of joining it.
    @Test func everyPackageBindingNamesAPublishedOperation() throws {
        guard let abilities = InstalledPackages.installed() else { return }
        let packages = try Self.shippedPackages(abilities)
        // THE ROSTER THE RUNTIME ACTUALLY INSTALLS, which is the catalog plus
        // the three faculties `MaryRuntime+BrainInstall` adds to it. Asking the
        // catalog alone would report a live adapter's operations as dead.
        let installed: [any MaryAdapter] = MaryAdapterCatalog.adapters()
            + [AffordancePlugin(), CodingAgentAdapter()]
        let published = Set(
            MaryAdapterCatalog.adapterManifests(
                adapters: installed,
                observers: MaryAdapterCatalog.observers())
                .flatMap { manifest in
                    manifest.operations.map { "\(manifest.adapterID.rawValue)/\($0.operation)" }
                })
        // An operation a package's OWN plugin declares is published by that
        // package, not by a compiled adapter.
        let declared = Set(
            packages.flatMap { package -> [String] in
                guard let plugin = package.plugin else { return [] }
                // A plugin operation with no adapter named belongs to the
                // package's own single declared adapter.
                let ownAdapter = plugin.adapters.first?.id.rawValue ?? ""
                return plugin.operations.map { operation in
                    let owner = operation.adapterID?.rawValue ?? ownAdapter
                    return owner + "/" + operation.operation
                }
            })

        var dead: [String] = []
        for package in packages {
            for skill in package.skills {
                for binding in skill.execution.bindings {
                    let name = "\(binding.adapterID.rawValue)/\(binding.operation)"
                    guard !published.contains(name), !declared.contains(name) else { continue }
                    dead.append("\(package.package.id.rawValue) \(skill.id.rawValue) -> \(name)")
                }
            }
        }
        let known = ["window-management window-management.bring-application-forward -> mac/open_app"]
        let unknown = dead.filter { !known.contains($0) }
        if !dead.isEmpty { print("[dead-bindings] \(dead.joined(separator: "\n"))") }
        #expect(unknown.isEmpty, "binding(s) nobody publishes: \(unknown)")
    }
}
