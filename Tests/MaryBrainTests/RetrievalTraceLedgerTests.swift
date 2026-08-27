//
//  RetrievalTraceLedgerTests.swift
//  MaryBrainTests
//
//  The retrieval ring buffer's contract: capacity and eviction, late-attach
//  by exchange, silent drops for unknown rows, first-contribution-wins, the
//  two-request fallback shape, the stage/claim handshake — and the redaction
//  pins, which are the reason the projection inits are the only way in.
//
//  Frozen clock throughout: every date is injected, never read from `Date()`.
//

import Foundation
import Testing
@testable import MaryBrain
@testable import MaryAmbient

@Suite struct RetrievalTraceLedgerTests {

    private let frozen = Date(timeIntervalSince1970: 1_755_000_000)

    private func scope(
        requestID: String,
        aggregate: Bool = true,
        groups: [(id: String, label: String)] = [],
        hints: [String] = [],
        personalTotemID: String? = "totem-1"
    ) -> SeerWire.SeerScope {
        SeerWire.SeerScope(
            ownerID: "owner-test",
            aggregate: aggregate,
            groups: groups.isEmpty ? nil : groups.map {
                SeerWire.SeerGroupRef(id: $0.id, label: $0.label, ownerID: "owner-test")
            },
            entities: hints.isEmpty ? nil : hints,
            personalTotemID: personalTotemID,
            requestID: requestID)
    }

    private func request(
        _ requestID: String,
        transport: SeerTransportKind = .sse,
        groups: [(id: String, label: String)] = [],
        aggregate: Bool = true
    ) -> SeerRequestTrace {
        SeerRequestTrace(
            scope: scope(requestID: requestID, aggregate: aggregate, groups: groups),
            transport: transport,
            sentAt: frozen)
    }

    // MARK: - Ring contract

    @Test func capacityEvictsTheOldestRowNewestFirst() {
        let ledger = RetrievalTraceLedger(capacity: 50)
        let exchanges = (0..<51).map { _ in UUID() }
        for (offset, exchange) in exchanges.enumerated() {
            ledger.open(
                exchangeID: exchange,
                date: frozen.addingTimeInterval(Double(offset)))
        }
        let entries = ledger.entries()
        #expect(entries.count == 50)
        #expect(entries.first?.exchangeID == exchanges.last)
        #expect(!entries.contains { $0.exchangeID == exchanges.first },
                "row 51 evicts the first-opened row")
        // A note for the evicted row drops silently — the ring's contract.
        ledger.noteSeerRequest(request("evicted-req"), forExchange: exchanges[0])
        #expect(ledger.entries().allSatisfy { $0.requests.isEmpty })
    }

    @Test func lateAttachBooksOntoExactlyTheNamedRow() throws {
        let ledger = RetrievalTraceLedger()
        let first = UUID()
        let second = UUID()
        ledger.open(exchangeID: first, routeTraceID: nil, date: frozen)
        ledger.open(exchangeID: second, date: frozen.addingTimeInterval(1))

        ledger.noteSeerRequest(request("req-1"), forExchange: first)
        ledger.notePromptSpend(
            PromptSpendTrace(lane: .seerInstructions, spend: [], appendedChars: 3, totalChars: 9),
            forExchange: first)
        ledger.noteAmbientInjection(
            AmbientInjectionTrace(
                lane: .seerInstructions,
                rendering: AmbientRendering(mode: .relevance),
                budget: 1400),
            forExchange: first)

        let rows = ledger.entries()
        let firstRow = try #require(rows.first { $0.exchangeID == first })
        let secondRow = try #require(rows.first { $0.exchangeID == second })
        #expect(firstRow.requests.map(\.id) == ["req-1"])
        #expect(firstRow.requests.first?.sentAt == frozen)
        #expect(firstRow.promptSpend.count == 1)
        #expect(firstRow.ambient.count == 1)
        #expect(secondRow.requests.isEmpty)
        #expect(secondRow.promptSpend.isEmpty)
        #expect(secondRow.ambient.isEmpty)
    }

    @Test func notesToAnUnknownExchangeDropSilently() {
        let ledger = RetrievalTraceLedger()
        let known = UUID()
        ledger.open(exchangeID: known, date: frozen)
        let before = ledger.entries()

        let unknown = UUID()
        ledger.noteSeerRequest(request("req-x"), forExchange: unknown)
        ledger.noteContribution(
            SeerContributionTrace(SeerContribution(), receivedAt: frozen),
            forExchange: unknown)
        ledger.noteAmbientInjection(
            AmbientInjectionTrace(
                lane: .system,
                rendering: AmbientRendering(mode: .relevance),
                budget: 700),
            forExchange: unknown)
        ledger.notePromptSpend(
            PromptSpendTrace(lane: .system, spend: [], appendedChars: 0, totalChars: 0),
            forExchange: unknown)

        #expect(ledger.entries() == before)
    }

    @Test func firstContributionWins() throws {
        let ledger = RetrievalTraceLedger()
        let exchange = UUID()
        ledger.open(exchangeID: exchange, date: frozen)
        ledger.noteSeerRequest(request("req-a"), forExchange: exchange)

        let first = SeerContributionTrace(
            SeerContribution(
                owners: [.init(totemID: "t-first")],
                totalPayout: 1, totalCost: 2),
            receivedAt: frozen)
        let second = SeerContributionTrace(
            SeerContribution(
                owners: [.init(totemID: "t-second")],
                totalPayout: 9, totalCost: 9),
            receivedAt: frozen.addingTimeInterval(1))
        ledger.noteContribution(first, forExchange: exchange)
        // A later request plus a duplicate contribution rewrite nothing —
        // the pairing froze with the winner.
        ledger.noteSeerRequest(request("req-b"), forExchange: exchange)
        ledger.noteContribution(second, forExchange: exchange)

        let row = try #require(ledger.entries().first { $0.exchangeID == exchange })
        #expect(row.contribution == first)
        #expect(row.contribution?.owners.map(\.totemID) == ["t-first"])
        #expect(row.contributionRequestID == "req-a",
                "pairing derives at booking time — the last-booked request id, frozen with the winning contribution")
    }

    /// The realtime pre-stream fallback made visible: the failed realtime
    /// request keeps its entry, the classic rerun appends its own, and the
    /// contribution books under the SECOND request's id — the last-booked
    /// rule lands on the rerun that actually earned it.
    @Test func fallbackShapeBooksTwoRequestsAndTheSecondsContribution() throws {
        let ledger = RetrievalTraceLedger()
        let exchange = UUID()
        ledger.open(exchangeID: exchange, date: frozen)

        ledger.noteSeerRequest(request("rt-req", transport: .realtime), forExchange: exchange)
        ledger.noteSeerRequest(request("sse-req", transport: .sse), forExchange: exchange)
        ledger.noteContribution(
            SeerContributionTrace(
                SeerContribution(owners: [.init(totemID: "t1")]),
                receivedAt: frozen.addingTimeInterval(2)),
            forExchange: exchange)

        let row = try #require(ledger.entries().first { $0.exchangeID == exchange })
        #expect(row.requests.map(\.id) == ["rt-req", "sse-req"])
        #expect(row.requests.map(\.transport) == [.realtime, .sse])
        #expect(row.contributionRequestID == "sse-req")
    }

    // MARK: - Stage/claim handshake

    @Test func stagedSystemPromptClaimsOntoTheRowOnce() throws {
        let ledger = RetrievalTraceLedger()
        let exchange = UUID()
        let spend = PromptSpendTrace(
            lane: .system,
            spend: [PromptSpend(
                id: .identity, outcome: .rendered, chars: 42, rationale: "who she is")],
            appendedChars: 7,
            totalChars: 49)
        let ambient = AmbientInjectionTrace(
            lane: .system,
            rendering: AmbientRendering(mode: .focusedWorld, blocks: ["live block"]),
            budget: 700)

        // Stage BEFORE the row exists — the provider runs first, the open
        // and claim follow a few statements later.
        ledger.stageSystemPrompt(spend: spend, ambient: ambient)
        ledger.open(exchangeID: exchange, date: frozen)
        ledger.claimStagedSystemPrompt(forExchange: exchange)

        let row = try #require(ledger.entries().first { $0.exchangeID == exchange })
        #expect(row.promptSpend == [spend])
        #expect(row.ambient == [ambient])

        // The stage is spent: a second claim books nothing.
        ledger.claimStagedSystemPrompt(forExchange: exchange)
        let again = try #require(ledger.entries().first { $0.exchangeID == exchange })
        #expect(again.promptSpend.count == 1)
        #expect(again.ambient.count == 1)
    }

    /// A claim for a missing row still CLEARS the stage — a stale stage must
    /// never attach to some later exchange's row.
    @Test func claimForUnknownExchangeDropsAndClearsTheStage() throws {
        let ledger = RetrievalTraceLedger()
        ledger.stageSystemPrompt(
            spend: PromptSpendTrace(lane: .system, spend: [], appendedChars: 0, totalChars: 0),
            ambient: AmbientInjectionTrace(
                lane: .system,
                rendering: AmbientRendering(mode: .relevance),
                budget: 700))
        ledger.claimStagedSystemPrompt(forExchange: UUID())

        let exchange = UUID()
        ledger.open(exchangeID: exchange, date: frozen)
        ledger.claimStagedSystemPrompt(forExchange: exchange)
        let row = try #require(ledger.entries().first { $0.exchangeID == exchange })
        #expect(row.promptSpend.isEmpty, "the dropped stage never resurfaces")
        #expect(row.ambient.isEmpty)
    }

    // MARK: - Redaction pins

    /// The projection is the redaction: spans go in, ONLY counts and summed
    /// characters come out, and the trace type has no field that could carry
    /// the span array forward.
    @Test func contributionProjectionKeepsOnlyCountsAndScores() {
        let contribution = SeerContribution(
            owners: [
                .init(
                    totemID: "t-low", ownerID: "o-low",
                    documentIDs: ["doc-b", "doc-a"],
                    influence: ["doc-a": 0.2],
                    royalty: 0.1,
                    spans: [.init(lower: 0, upper: 4)],
                    earning: 0.01),
                .init(
                    totemID: "t-high", ownerID: nil,
                    documentIDs: ["doc-z"],
                    influence: ["doc-z": 0.9],
                    royalty: 0.8,
                    spans: [.init(lower: 2, upper: 9), .init(lower: 10, upper: 15)],
                    earning: 0.4),
            ],
            totalPayout: 1.5,
            serviceCharge: 0.1,
            totalCost: 2.25)

        let trace = SeerContributionTrace(contribution, receivedAt: frozen)
        #expect(trace.receivedAt == frozen)
        #expect(trace.totalPayout == 1.5)
        #expect(trace.totalCost == 2.25)
        // Royalty-descending, deterministic.
        #expect(trace.owners.map(\.totemID) == ["t-high", "t-low"])
        let high = trace.owners[0]
        #expect(high.id == "t-high", "Owner.id semantics verbatim: ownerID ?? totemID")
        #expect(high.spanCount == 2)
        #expect(high.creditedChars == 12)
        #expect(high.influence == ["doc-z": 0.9])
        let low = trace.owners[1]
        #expect(low.id == "o-low")
        #expect(low.documentIDs == ["doc-a", "doc-b"], "Set projected sorted")
        #expect(low.spanCount == 1)
        #expect(low.creditedChars == 4)
    }

    /// The sole init takes the rendering itself, so block text cannot be
    /// stored — only its counts, keys and mode survive.
    @Test func ambientProjectionKeepsOnlyCountsKeysAndMode() {
        let keys = [
            AmbientKey(place: .application("quill"), slot: .viewport),
            AmbientKey(place: .application("quill"), slot: .read("batteries")),
        ]
        let rendering = AmbientRendering(
            mode: .focusedWorld,
            blocks: ["a full rendered passage", "another one"],
            mentions: ["— a mention line"],
            keys: keys)
        let trace = AmbientInjectionTrace(
            lane: .seerInstructions, rendering: rendering, budget: 1400)
        #expect(trace.mode == .focusedWorld)
        #expect(trace.keys == keys)
        #expect(trace.blockCount == 2)
        #expect(trace.mentionCount == 1)
        #expect(trace.blockChars ==
            "a full rendered passage".count + "another one".count)
        #expect(trace.budget == 1400)
    }

    /// The request trace is a projection of the wire value — ids, labels,
    /// flags — with the per-group owner id (always the request's own owner)
    /// projected away rather than restated.
    @Test func requestProjectionMirrorsTheWireScope() {
        let trace = SeerRequestTrace(
            scope: scope(
                requestID: "req-w",
                aggregate: false,
                groups: [("mary-scope-1", "Pages — Essay"), ("memory-owner-test", "Memory")],
                hints: ["deadline"]),
            transport: .realtime,
            sentAt: frozen)
        #expect(trace.id == "req-w")
        #expect(trace.sentAt == frozen)
        #expect(trace.transport == .realtime)
        #expect(trace.ownerID == "owner-test")
        #expect(trace.aggregate == false)
        #expect(trace.groups.map(\.id) == ["mary-scope-1", "memory-owner-test"])
        #expect(trace.groups.map(\.label) == ["Pages — Essay", "Memory"])
        #expect(trace.relationshipHints == ["deadline"])
        #expect(trace.personalTotemID == "totem-1")
    }
}
