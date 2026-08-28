//
//  UnitIndexingTests.swift
//  MaryAmbientTests
//
//  THE CONTENT HASH IS THE WHOLE EFFICIENCY STORY, and it is the one thing
//  here that must not rot.
//
//  Annotation costs a model round. The hash gate is what makes returning to
//  the file you are working in FREE: an unchanged file is never re-read,
//  never re-annotated, never re-deposited. Break it and nothing fails — the
//  corpus keeps working, correctly, while quietly spending a model round every
//  time the idle timer fires on a file nobody touched. That is a bug measured
//  in money and battery rather than in wrong answers, which is exactly the
//  kind that survives for months.
//
//  The other half is the ledger. A SKIPPED ROW IS RECORDED rather than
//  silent, because a gate nobody can see is a gate nobody can debug — and the
//  Corpus pane's Operations tab is where a person finds out whether Mary is
//  learning or idling.
//

import Foundation
import Testing
@testable import MaryAmbient

@Suite struct UnitIndexingTests {

    /// Counts annotation requests so a test can assert an absence.
    private final class CountingAnnotator: UnitAnnotating, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests = 0
        var requests: Int {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }
        var declinesEverything: Bool { false }

        func annotate(_ request: UnitAnnotationRequest) async -> UnitAnnotation? {
            lock.lock(); _requests += 1; lock.unlock()
            return UnitAnnotation(precis: "a summary", labels: ["parsing"])
        }
    }

    /// Collects deposits.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _units: [IndexedUnit] = []
        var units: [IndexedUnit] {
            lock.lock(); defer { lock.unlock() }
            return _units
        }
        func record(_ unit: IndexedUnit) {
            lock.lock(); _units.append(unit); lock.unlock()
        }
    }

    private func unit(
        path: String = "Sources/Parser.swift",
        hash: String,
        project: String = "/tmp/demo"
    ) -> IndexedUnit {
        IndexedUnit(
            subject: DepositSubject(app: "xcode", projectIdentity: project),
            projectName: "demo",
            relativePath: path,
            contentHash: hash,
            declaredTypes: ["Parser"],
            apiHeaders: ["struct Parser"])
    }

    /// No idle delay: these tests are about the gate, not the debounce.
    private func coordinator(
        _ recorder: Recorder, annotator: CountingAnnotator? = nil
    ) -> AmbientUnitIndexingCoordinator {
        AmbientUnitIndexingCoordinator(
            idleFor: 0.1,
            annotator: annotator,
            ledger: nil) { unit, _ in recorder.record(unit) }
    }

    // MARK: - The gate

    @Test func aFirstSightingIsIndexedAndAnnotated() async {
        let recorder = Recorder()
        let annotator = CountingAnnotator()
        let index = coordinator(recorder, annotator: annotator)

        await index.ingest(unit(hash: "aaa"))
        await index.flush()
        await index.drainAnnotations()

        #expect(recorder.units.count == 1)
        #expect(annotator.requests == 1)
        #expect(recorder.units.first?.annotation?.precis == "a summary")
    }

    /// THE REGRESSION THAT MATTERS. Re-focusing an unchanged file must cost
    /// nothing: no second deposit, and above all no second model round.
    @Test func anUnchangedFileIsNeverAnnotatedTwice() async {
        let recorder = Recorder()
        let annotator = CountingAnnotator()
        let index = coordinator(recorder, annotator: annotator)

        await index.ingest(unit(hash: "aaa"))
        await index.flush()
        await index.drainAnnotations()
        await index.ingest(unit(hash: "aaa"))
        await index.flush()
        await index.drainAnnotations()

        #expect(recorder.units.count == 1)
        #expect(annotator.requests == 1)
    }

    /// The gate is on the CONTENT, not the path — edit the file and it is a
    /// new revision, however many times it has been seen before.
    @Test func anEditedFileIsIndexedAgain() async {
        let recorder = Recorder()
        let annotator = CountingAnnotator()
        let index = coordinator(recorder, annotator: annotator)

        await index.ingest(unit(hash: "aaa"))
        await index.flush()
        await index.drainAnnotations()
        await index.ingest(unit(hash: "bbb"))
        await index.flush()
        await index.drainAnnotations()

        #expect(recorder.units.count == 2)
        #expect(annotator.requests == 2)
    }

    @Test func twoDifferentFilesBothIndex() async {
        let recorder = Recorder()
        let index = coordinator(recorder)

        await index.ingest(unit(path: "Sources/A.swift", hash: "aaa"))
        await index.ingest(unit(path: "Sources/B.swift", hash: "bbb"))
        await index.flush()

        #expect(recorder.units.count == 2)
    }

    // MARK: - The manifest

    @Test func theManifestRemembersWhatItHasSeen() async {
        let recorder = Recorder()
        let index = coordinator(recorder)

        await index.ingest(unit(hash: "aaa"))
        await index.flush()

        let known = await index.knownContentHash(
            relativePath: "Sources/Parser.swift", projectID: "/tmp/demo")
        #expect(known == "aaa")
    }

    /// A manifest restored at boot gates immediately — otherwise every file in
    /// a project would be a first sighting again on every launch, which is the
    /// hash gate switched off in all but name.
    @Test func aRestoredManifestGatesWithoutReIndexing() async {
        let recorder = Recorder()
        let annotator = CountingAnnotator()
        let index = coordinator(recorder, annotator: annotator)

        await index.ingest(unit(hash: "aaa"))
        await index.flush()
        await index.drainAnnotations()
        guard let manifest = await index.manifest(forProject: "/tmp/demo") else {
            Issue.record("no manifest was built")
            return
        }

        let secondRecorder = Recorder()
        let secondAnnotator = CountingAnnotator()
        let relaunched = coordinator(secondRecorder, annotator: secondAnnotator)
        await relaunched.restore(manifest, projectID: "/tmp/demo")
        await relaunched.ingest(unit(hash: "aaa"))
        await relaunched.flush()
        await relaunched.drainAnnotations()

        #expect(secondRecorder.units.isEmpty)
        #expect(secondAnnotator.requests == 0)
    }

    /// Forgetting a unit clears its gate: the next sighting is a first one.
    @Test func aForgottenUnitIsIndexedAfresh() async {
        let recorder = Recorder()
        let index = coordinator(recorder)

        await index.ingest(unit(hash: "aaa"))
        await index.flush()
        await index.forget(path: "Sources/Parser.swift", projectID: "/tmp/demo")
        await index.ingest(unit(hash: "aaa"))
        await index.flush()

        #expect(recorder.units.count == 2)
    }

    // MARK: - Annotation is optional

    /// A unit still deposits with its structure when nothing can annotate it.
    /// The local engine declines by policy — a background annotator must never
    /// queue behind the engine answering the user — and the honest result is a
    /// unit without a summary, not a missing unit.
    @Test func aUnitWithoutAnAnnotatorStillDeposits() async {
        let recorder = Recorder()
        let index = coordinator(recorder)

        await index.ingest(unit(hash: "aaa"))
        await index.flush()

        #expect(recorder.units.count == 1)
        #expect(recorder.units.first?.annotation == nil)
        #expect(recorder.units.first?.declaredTypes == ["Parser"])
    }

    // MARK: - Addressing

    /// Unit keys are minted on one machine and resolved on another, so the
    /// canonicalizer cannot be a coin flip.
    @Test func canonicalizationCollapsesWhitespaceAndCaseOnly() {
        #expect(UnitIndexHashing.canonical("  My   App ") == "my app")
        // Punctuation SURVIVES: a path separator and a hyphen are meaning.
        #expect(UnitIndexHashing.canonical("my-app") == "my-app")
        #expect(UnitIndexHashing.canonical("my-app") != UnitIndexHashing.canonical("my app"))
    }

    /// Not `Hasher`, which is per-process seeded and would mint a new document
    /// id every launch.
    @Test func theStableHashIsStableAcrossCalls() {
        #expect(UnitIndexHashing.stableHash("a") == UnitIndexHashing.stableHash("a"))
        #expect(UnitIndexHashing.stableHash("a") != UnitIndexHashing.stableHash("b"))
    }
}
