//
//  SeerUnitAnnotatorTests.swift
//  MaryBrainTests
//
//  THE CONTRACT MUST RIDE THE REQUEST, and the reason this suite exists is
//  that for a while it did not.
//
//  `SeerUnitAnnotator` streamed with `instructions: nil`, so
//  `InferenceUnitAnnotator.systemPrompt` — the JSON shape `parse` enforces on
//  the way out — never reached the server. Seer's chat is a persona lane with
//  retrieval, not a completion endpoint: handed a bare list of declarations
//  and no instruction, it answered in prose about the file, `parse` returned
//  nil, and every unit in hosted mode landed in the ledger as `.failed`. The
//  Corpus pane read "structure only — the summariser returned nothing" for the
//  whole project, in the mode most installs actually run.
//
//  Nothing caught it. The parser was tested against strings, the annotator
//  against nothing, and the two halves of the round — what is SENT and what is
//  ACCEPTED — had no test that held them to each other. That is the gap these
//  cases close: the first asserts the bytes, the rest assert the outcomes the
//  ledger distinguishes.
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
    final class RecordingSeer: SeerChatProviding, @unchecked Sendable {
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
        func ownerID() async -> String? { "owner-test" }

        func stream(
            messages: [SeerChatMessage], instructions: String?
        ) -> AsyncThrowingStream<SeerChatEvent, Error> {
            lock.lock()
            instructionsSeen.append(instructions)
            messagesSeen.append(messages)
            lock.unlock()
            return AsyncThrowingStream { continuation in
                if let failure {
                    continuation.finish(throwing: failure)
                    return
                }
                continuation.yield(.token(reply))
                continuation.finish()
            }
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
        let seer = RecordingSeer(reply: Self.wellFormed)
        _ = await SeerUnitAnnotator(chat: seer).annotate(Self.request())

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
        // Belt and braces on the pin above: a future edit that renames the
        // keys in one half and not the other would leave the `#expect` on
        // equality green and the round broken again.
        let prompt = InferenceUnitAnnotator.systemPrompt
        #expect(prompt.contains("precis"))
        #expect(prompt.contains("labels"))
        #expect(prompt.contains("JSON"))
    }

    // MARK: - The outcomes the ledger distinguishes

    @Test("a well-formed reply becomes an annotation")
    func parsesWellFormedReply() async {
        let annotation = await SeerUnitAnnotator(chat: RecordingSeer(reply: Self.wellFormed))
            .annotate(Self.request())
        #expect(annotation?.precis == "coordinates delayed, deduplicated indexing of units")
        #expect(annotation?.labels == ["debounce-throttling", "manifest-tracking"])
    }

    @Test("a prose reply — what the server sent before the fix — yields nothing")
    func proseReplyYieldsNil() async {
        // Verbatim shape of what the live server returned to the instruction-
        // less request. Kept as a case rather than a comment: this is the
        // answer the annotator must still refuse, contract or no contract.
        let prose = """
            In your `UnitIndex.swift`, the `AmbientUnitIndexingCoordinator` handles \
            delayed indexing until user movement stops, annotates per file revision, \
            and publishes the results.
            """
        let annotation = await SeerUnitAnnotator(chat: RecordingSeer(reply: prose))
            .annotate(Self.request())
        #expect(annotation == nil)
    }

    @Test("a signed-out session never opens a stream")
    func notReadyDeclinesWithoutAsking() async {
        let seer = RecordingSeer(reply: Self.wellFormed, ready: false)
        let annotation = await SeerUnitAnnotator(chat: seer).annotate(Self.request())
        #expect(annotation == nil)
        // NOT MERELY NIL: the point of `isReady` is that no request is made.
        #expect(seer.snapshot().instructions.isEmpty)
    }

    @Test("a stream failure yields nothing rather than throwing")
    func streamFailureYieldsNil() async {
        let seer = RecordingSeer(failure: SeerChatError.notAuthenticated)
        let annotation = await SeerUnitAnnotator(chat: seer).annotate(Self.request())
        #expect(annotation == nil)
    }

    @Test("it never refuses by policy — an unreachable server is a failure, not a refusal")
    func neverRefusesByPolicy() {
        // The distinction the ledger renders: `.refusedExclusiveEngine` is a
        // deliberate decline the pane explains, `.failed` is a summariser that
        // returned nothing. This annotator can only ever produce the latter.
        #expect(SeerUnitAnnotator(chat: RecordingSeer()).refusesToAnnotate == false)
    }

    // MARK: - Through the coordinator

    @Test("a summarised unit reaches the ledger as .ran")
    func coordinatorRecordsRan() async {
        let ledger = UnitIndexLedger()
        let indexer = AmbientUnitIndexingCoordinator(
            idleFor: 0.1,
            annotator: SeerUnitAnnotator(chat: RecordingSeer(reply: Self.wellFormed)),
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
            annotator: SeerUnitAnnotator(chat: RecordingSeer(reply: "a paragraph, not JSON")),
            ledger: ledger) { _, _ in }
        await indexer.ingest(Self.unit())
        await indexer.flush()

        // THE EXACT SYMPTOM THAT WAS REPORTED, pinned so its cause stays
        // legible: `.failed` is what the pane turns into "the summariser
        // returned nothing".
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
