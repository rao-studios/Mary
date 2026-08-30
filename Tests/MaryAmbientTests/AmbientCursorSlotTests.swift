//
//  AmbientCursorSlotTests.swift
//  MaryAmbientTests
//
//  THE NEW CASE IN A CLOSED VOCABULARY, and the two decisions behind it that
//  are invisible at the call site and fatal if they drift.
//
//  1. `.cursor` IS NOT PERCEIVED. `MaryRuntime.heldContext` dedups every
//     perceived fact belonging to the LEAD place, on the ground that the live
//     prompt section already renders them in full. No live section renders a
//     cursor — the observer that publishes it contributes no prompt text at
//     all — so a perceived `.cursor` would be dropped from the prompt on
//     exactly the turns it exists for: the ones where the user is in the
//     editor. That dedup rule is mirrored here rather than reached through
//     `MaryRuntime` (a different module), and the mirror is stated in the
//     test's own name so a change to the rule fails somewhere that explains
//     itself.
//  2. ITS WINDOWS ARE ITS OWN. `!isPerceived` would otherwise hand it the
//     READ retention — twenty minutes, for a caret nobody asked about.
//

import Foundation
import Testing
@testable import MaryAmbient

@Suite struct AmbientCursorSlotTests {

    /// SCOPED, NEVER INSTALLED — `AmbientPlaceTests`' own rule, for the same
    /// reason: these suites run concurrently, and the process-wide provider
    /// would answer for whatever else is mid-turn.
    ///
    /// A roster is needed at all because `AmbientPlace.focus` is a REGISTRY
    /// question: without one, `.application("xcode")` has no discipline, and
    /// the renderer's `focusable` test — which decides block versus mention —
    /// reads it as an eyeless aside. That is exactly what production is not,
    /// so the tests that care about rendering say so out loud.
    private func withXcodeRoster<T>(_ body: () -> T) -> T {
        let xcode = ApplicationRegistration(
            id: "xcode",
            profile: ApplicationProfile(
                id: "xcode", title: "Xcode", summary: "One code editor.",
                abilities: ["coding"]),
            bundleIdentifiers: ["com.apple.dt.Xcode"],
            worldClass: .workspace)
        return AmbientApplicationIndexProvider.$scoped.withValue(
            AmbientApplicationRoster([xcode]), operation: body)
    }

    private func cursorFact(
        at capturedAt: Date = Date(), content: String = "Cursor scope: Ledger → record (line 12)"
    ) -> AmbientFact {
        AmbientFact(
            world: .applications,
            application: "xcode",
            slot: .cursor,
            content: content,
            subject: "Ledger.swift",
            applicationID: "com.apple.dt.Xcode",
            bounds: 100..<600,
            documentTotal: 18_234,
            anchor: .caret,
            provenance: .liveAX,
            capturedAt: capturedAt)
    }

    // MARK: - The vocabulary

    @Test func theSlotTokenIsStableAndItsKeyReadsAsThePlaceAndTheSlot() {
        #expect(AmbientSlot.cursor.token == "cursor")
        let key = AmbientKey(world: .applications, application: "xcode", slot: .cursor)
        #expect(key.id == "\(AmbientPlace.application("xcode").token)/cursor")
    }

    /// BELOW THE VIEWPORT, ABOVE THE FILE — `PerceptionAnchor`'s own rule
    /// that what a reader is looking at beats where they last typed, read as
    /// sort order.
    @Test func aCursorSortsBelowTheViewportAndAboveTheFile() {
        #expect(AmbientSlot.viewport.order < AmbientSlot.cursor.order)
        #expect(AmbientSlot.cursor.order < AmbientSlot.file.order)
        #expect(AmbientSlot.selection.order < AmbientSlot.cursor.order)
    }

    @Test func aCursorIsNeitherPerceivedNorARead() {
        #expect(!AmbientSlot.cursor.isPerceived)
        #expect(!AmbientSlot.cursor.isRead)
    }

    @Test func aCursorSpeaksInTheAnchorsOwnWords() {
        #expect(cursorFact().slotPhrase == PerceptionAnchor.caret.displayName)
    }

    // MARK: - The windows

    @Test func aCursorCarriesTheShortestWindowsInTheStore() {
        let fact = cursorFact()
        #expect(fact.freshFor == AmbientFact.cursorFreshWindow)
        #expect(fact.retainFor == AmbientFact.cursorRetention)
        // The two claims this pair exists to make, against the defaults it
        // had to be separated from.
        #expect(fact.retainFor < AmbientFact.defaultRetention(slot: .viewport))
        #expect(fact.retainFor < AmbientFact.defaultRetention(slot: .namedRead(
            document: nil, phrase: "x")))
        #expect(fact.freshFor >= CodeSurfaceObserverCadenceMirror.pollSeconds * 2)
    }

    @Test func aCursorOlderThanItsWindowSaysSoRatherThanVanishing() {
        let stale = cursorFact(at: Date().addingTimeInterval(-AmbientFact.cursorFreshWindow - 5))
        #expect(!stale.isFresh())
        #expect(!stale.isExpired())
        #expect(stale.agePhrase().contains("may have moved on since"))
    }

    @Test func aCursorPastRetentionIsDroppedOutright() {
        let ancient = cursorFact(at: Date().addingTimeInterval(-AmbientFact.cursorRetention - 5))
        #expect(ancient.isExpired())
    }

    // MARK: - Reaching the prompt

    /// THE WHOLE POINT, as a rendering. Real bounds and a real total mean the
    /// header can say where the excerpt sits without inventing anything.
    @Test func aCursorRendersAsABlockCarryingItsScopeLineAndItsBounds() throws {
        let rendering = withXcodeRoster {
            AmbientRanker.render(
                facts: [cursorFact()],
                utterance: "what does this do",
                focusedPlace: .application("xcode"),
                budget: 1400)
        }
        #expect(rendering.blocks.count == 1)
        let block = try #require(rendering.blocks.first)
        #expect(block.contains("Cursor scope: Ledger → record (line 12)"))
        #expect(block.contains("characters 100–600 of 18234"))
        #expect(rendering.mentions.isEmpty)
    }

    /// THE DEDUP RULE `MaryRuntime.heldContext` APPLIES, mirrored. A
    /// perceived lead-place fact is skipped because the live section already
    /// said it; a cursor is not perceived, so it survives.
    @Test func aCursorSurvivesTheLeadPlacePerceivedDedup() {
        let lead = AmbientPlace.application("xcode")
        let facts = [cursorFact()]
        let deduped = Set(
            facts.filter { $0.place == lead && $0.slot.isPerceived }.map(\.key))
        #expect(deduped.isEmpty)

        let rendering = withXcodeRoster {
            AmbientRanker.render(
                facts: facts,
                utterance: "what does this do",
                focusedPlace: lead,
                alreadyRendered: deduped,
                budget: 1400)
        }
        #expect(rendering.blocks.count == 1)
    }

    /// AND IT SURVIVES THE STORE, which refuses `.selection` outright and
    /// admits everything else. A registered cursor comes back out.
    @Test func theStoreHoldsAndForgetsACursorByItsKey() {
        let store = AmbientContextStore()
        store.register(cursorFact())
        #expect(store.facts().contains { $0.slot == .cursor })

        store.forget(key: AmbientKey(world: .applications, application: "xcode", slot: .cursor))
        #expect(!store.facts().contains { $0.slot == .cursor })
    }

    /// A LANE-WIDE PERCEPTION WIPE MUST NOT TAKE IT. `forgetPerceived` is
    /// what a watcher going dark calls; the cursor lane retracts explicitly by
    /// key instead, and this is the difference made checkable.
    @Test func aPerceptionRetractionLeavesTheCursorStanding() {
        let store = AmbientContextStore()
        store.register(cursorFact())
        store.forgetPerceived(place: .application("xcode"))
        #expect(store.facts().contains { $0.slot == .cursor })
    }
}

/// The observer's cadence, restated where MaryAmbient can see it. The
/// observer lives in MaryPlugin, which this module cannot import; the point
/// of the assertion above is that the fresh window is at least two polls
/// wide, so the number it compares against has to be here.
enum CodeSurfaceObserverCadenceMirror {
    static let pollSeconds = AmbientFact.cursorRefreshFloor
}
