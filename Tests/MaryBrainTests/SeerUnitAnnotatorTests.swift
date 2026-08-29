//
//  SeerUnitAnnotatorTests.swift
//  MaryBrainTests
//
//  THE CONTRACT MUST RIDE THE REQUEST, and the reason this suite exists is
//  that for a while it did not — and then it rode the WRONG route.
//
//  `SeerUnitAnnotator` streamed through `/v1/chat/completions` with
//  `instructions: nil`, so `InferenceUnitAnnotator.systemPrompt` never
//  reached the server. Seer's chat is a persona lane with retrieval: it
//  answered in prose about the file, `parse` returned nil, and every unit
//  in hosted mode landed in the ledger as `.failed`.
//
//  The complete route is the fix: `/v1/complete`, the JSON contract in
//  `instructions`, no `seer` RAG object. These cases still hold the two
//  halves of the round — what is SENT and what is ACCEPTED — to each other.
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain

@Suite struct SeerUnitAnnotatorTests {

    // MARK: - The double

    /// Records what it was ASKED, then answers a scripted body. The recording
    /// is the point: the defect was invisible in the reply and plain in the
    /// request.
    final class RecordingComplete: SeerCompleteProviding, @unchecked Sendable {
        private let lock = NSLock()
        private let reply: String
        private let failure: Error?
        var ready: Bool
        private(set) var instructionsSeen: [String?] = []
        private(set) var messagesSeen: [[SeerChatMessage]] = []

        init(reply: String = "", failure: Error? = nil, ready: Bool = true) {
            self.reply = reply
            self.failure = failure
            self.ready = ready
        }

        func snapshot() -> (instructions: [String?], messages: [[SeerChatMessage]]) {
            lock.lock(); defer { lock.unlock() }
            return (instructionsSeen, messagesSeen)
        }

        func isReady() async -> Bool { ready }

        func complete(
            instructions: String?,
            messages: [SeerChatMessage]
        ) async throws -> String {
            lock.lock()
            instructionsSeen.append(instructions)
            messagesSeen.append(messages)
            lock.unlock()
            if let failure { throw failure }
            return reply
        }
    }

    static func request(
        path: String = "Sources/MaryAmbient/Ambient/Indexing/UnitIndex.swift"
    ) -> UnitAnnotationRequest {
        UnitAnnotationRequest(
            projectName: "Mary",
            relativePath: path,
            declaredTypes: ["AmbientUnitIndexingCoordinator"],
            relations: [],
            apiHeaders: ["public func ingest(_ unit: IndexedUnit) async"],
            doc: "Delays unit indexing until the user has stopped moving.")
    }

    static let wellFormed = """
        {"precis": "coordinates delayed, deduplicated indexing of units", \
        "labels": ["debounce-throttling", "manifest-tracking"]}
        """

    // MARK: - The regression

    @Test("the JSON contract is sent as the request's instructions")
    func sendsSystemPromptAsInstructions() async {
        let seer = RecordingComplete(reply: Self.wellFormed)
        _ = await SeerUnitAnnotator(complete: seer).annotate(Self.request())

        let (instructions, messages) = seer.snapshot()
        #expect(instructions.count == 1)
        // THE PIN. Not "is non-nil" — the LOCAL path's exact prompt, because
        // two annotators that parse identically must ask identically, or a
        // unit's card depends on which one happened to summarise it.
        #expect(instructions.first ?? nil == InferenceUnitAnnotator.systemPrompt)
        // And the user message still carries only the structural digest —
        // never a file body. `InferenceUnitAnnotator`'s second stated rule.
        #expect(messages.first?.count == 1)
        #expect(messages.first?.first?.role == "user")
        #expect(messages.first?.first?.content
            == InferenceUnitAnnotator.prompt(for: Self.request()))
    }

    @Test("the instructions actually name the shape the parser demands")
    func systemPromptDescribesTheParsedShape() {
        let prompt = InferenceUnitAnnotator.systemPrompt
        #expect(prompt.contains("precis"))
        #expect(prompt.contains("labels"))
        #expect(prompt.contains("JSON"))
    }

    // MARK: - The outcomes the ledger distinguishes

    @Test("a well-formed reply becomes an annotation")
    func parsesWellFormedReply() async {
        let annotation = await SeerUnitAnnotator(
            complete: RecordingComplete(reply: Self.wellFormed)
        ).annotate(Self.request())
        #expect(annotation?.precis == "coordinates delayed, deduplicated indexing of units")
        #expect(annotation?.labels == ["debounce-throttling", "manifest-tracking"])
    }

    @Test("a prose reply — what the chat lane sent before the fix — yields nothing")
    func proseReplyYieldsNil() async {
        let prose = """
            In your `UnitIndex.swift`, the `AmbientUnitIndexingCoordinator` handles \
            delayed indexing until user movement stops, annotates per file revision, \
            and publishes the results.
            """
        let annotation = await SeerUnitAnnotator(
            complete: RecordingComplete(reply: prose)
        ).annotate(Self.request())
        #expect(annotation == nil)
    }

    @Test("a signed-out session never opens a request")
    func notReadyDeclinesWithoutAsking() async {
        let seer = RecordingComplete(reply: Self.wellFormed, ready: false)
        let annotation = await SeerUnitAnnotator(complete: seer).annotate(Self.request())
        #expect(annotation == nil)
        #expect(seer.snapshot().instructions.isEmpty)
    }

    @Test("a complete failure yields nothing rather than throwing")
    func completeFailureYieldsNil() async {
        let seer = RecordingComplete(failure: SeerCompleteError.notAuthenticated)
        let annotation = await SeerUnitAnnotator(complete: seer).annotate(Self.request())
        #expect(annotation == nil)
    }

    @Test("it never refuses by policy — an unreachable server is a failure, not a refusal")
    func neverRefusesByPolicy() {
        #expect(SeerUnitAnnotator(complete: RecordingComplete()).refusesToAnnotate == false)
    }

    // MARK: - Through the coordinator

    @Test("a summarised unit reaches the ledger as .ran")
    func coordinatorRecordsRan() async {
        let ledger = UnitIndexLedger()
        let indexer = AmbientUnitIndexingCoordinator(
            idleFor: 0.1,
            annotator: SeerUnitAnnotator(complete: RecordingComplete(reply: Self.wellFormed)),
            ledger: ledger) { _, _ in }
        await indexer.ingest(Self.unit())
        await indexer.flush()

        let record = ledger.allUnits().first
        #expect(record?.annotation == .ran)
        #expect(record?.labels == ["debounce-throttling", "manifest-tracking"])
    }

    @Test("and an unparsable one reaches it as .failed, not as a refusal")
    func coordinatorRecordsFailed() async {
        let ledger = UnitIndexLedger()
        let indexer = AmbientUnitIndexingCoordinator(
            idleFor: 0.1,
            annotator: SeerUnitAnnotator(
                complete: RecordingComplete(reply: "a paragraph, not JSON")),
            ledger: ledger) { _, _ in }
        await indexer.ingest(Self.unit())
        await indexer.flush()

        #expect(ledger.allUnits().first?.annotation == .failed)
    }

    static func unit() -> IndexedUnit {
        IndexedUnit(
            subject: DepositSubject(
                app: "xcode", projectIdentity: "/tmp/mary-annotator-tests"),
            projectName: "Mary",
            relativePath: "Sources/MaryAmbient/Ambient/Indexing/UnitIndex.swift",
            contentHash: "hash-1",
            declaredTypes: ["AmbientUnitIndexingCoordinator"],
            apiHeaders: ["public func ingest(_ unit: IndexedUnit) async"],
            doc: "Delays unit indexing until the user has stopped moving.")
    }
}
