//
//  PassageRefreshTests.swift
//  MaryPluginTests
//
//  WHAT: After a write, stored passage anchors re-find the same span.
//  OUT:  PassageRefresh
//  PIN:  Headless arithmetic; live typing is mary-prose-probe
//

import Foundation
import Testing
@testable import MaryPlugin
@testable import MaryAmbient

// MARK: - Fixtures

private let brief = """
Purpose and scope

This document sets out what we are for, before the next review.

Budget

Everything the team touches this quarter, and nothing else.
"""

private let key = "/Users/x/Brief.pages"

private func snapshot(_ text: String, key: String = key) -> BodySnapshot {
    BodySnapshot(text: text, documentKey: key, documentTitle: "Brief")
}

private func offsets(_ needle: String, in body: String = brief) -> Range<Int> {
    guard let found = body.range(of: needle) else {
        Issue.record("fixture does not contain \"\(needle)\"")
        return 0..<0
    }
    return body.distance(from: body.startIndex, to: found.lowerBound)
        ..< body.distance(from: body.startIndex, to: found.upperBound)
}

/// Mint a handle over `needle` exactly the way a read does — through
/// `PassageRecipes.mintRead`, so this file invents no second minting rule and a
/// change to the real one is felt here.
@discardableResult
private func hold(
    _ needle: String, in registry: PassageRegistry,
    body: String = brief, kind: PassageUnitKind = .paragraph
) -> Passage {
    let passage = PassageRecipes.mintRead(
        place: .application("quill"), documentKey: key, documentTitle: "Brief",
        body: body, range: offsets(needle, in: body), kind: kind,
        registry: registry)
    return passage!
}

private func words(of handle: String, in registry: PassageRegistry) -> String? {
    guard case .live(let passage) = registry.resolve(handle) else { return nil }
    return passage.text
}

/// Follow a handle the way `PassageEditRunner.resolveHandle` does — one hop is
/// all a single refresh can ever produce.
private func following(_ handle: String, in registry: PassageRegistry) -> Passage? {
    switch registry.resolve(handle) {
    case .live(let passage):
        return passage
    case .superseded(let replacedBy):
        guard case .live(let passage) = registry.resolve(replacedBy) else { return nil }
        return passage
    case .unknown:
        return nil
    }
}

// MARK: - The traced failure

@Suite struct PassageRefreshTests {

    /// A passage needs a place with EYES, and eyes come from a
    /// registration — see `PassageRosterFixture`.
    init() { PassageRosterFixture.install() }

    /// THE INCIDENT. She typed INSIDE the words `[S1]` stands for, and the
    /// handle has to survive it — pointing at the same part of the document,
    /// now including what she wrote.
    ///
    /// A PLAIN RE-ANCHOR CANNOT DO THIS, and the second half of the test is what
    /// proves it rather than asserting it: the stored words occur ZERO times in
    /// the new body, so anything derived from the after-body alone answers
    /// `.gone` and says the sentence the user heard.
    @Test func typingInsideAHeldPassageGrowsItInsteadOfOrphaningIt() {
        let registry = PassageRegistry()
        let ambient = AmbientContextStore()
        let held = hold("This document sets out what we are for, before the next review.", in: registry)

        let after = brief.replacingOccurrences(
            of: "sets out what we are for",
            with: "sets out, plainly, what we are for")

        // The proof that a re-anchor is not enough.
        #expect(PassageResolver.anchor(held, in: after) == .gone)

        let moved = PassageRefresh.after(
            before: snapshot(brief), after: snapshot(after), place: .application("quill"),
            registry: registry, ambient: ambient, undo: ContentUndoStore())
        #expect(moved == 1)

        let now = try! #require(following(held.handle, in: registry))
        #expect(now.text
            == "This document sets out, plainly, what we are for, before the next review.")
        #expect(now.documentKey == key)
        // It is a NEW passage, because its words changed — so the old handle
        // forwards rather than silently meaning something else.
        #expect(now.handle != held.handle)
        #expect(registry.resolve(held.handle) == .superseded(replacedBy: now.handle))
        // And the thing every later step depends on: it resolves cleanly in the
        // body that now exists.
        #expect(PassageResolver.anchor(now, in: after) == .exact)
    }

    /// TYPING ABOVE IT MOVES IT AND KEEPS THE HANDLE. The words did not change,
    /// so `Passage.identity` — `world|documentKey|hash(text)` — is the same
    /// string and minting hands back the SAME handle with a fresh range. That is
    /// the "for free" in the design, and it is why no new registry API exists.
    @Test func typingAboveAHeldPassageShiftsItAndKeepsTheSameHandle() {
        let registry = PassageRegistry()
        let held = hold("Everything the team touches this quarter, and nothing else.", in: registry)
        let after = "A line the user just typed.\n\n" + brief

        let moved = PassageRefresh.after(
            before: snapshot(brief), after: snapshot(after), place: .application("quill"),
            registry: registry, ambient: AmbientContextStore(), undo: ContentUndoStore())
        #expect(moved == 1)

        let now = try! #require(following(held.handle, in: registry))
        #expect(now.handle == held.handle)
        #expect(now.text == held.text)
        #expect(now.range.lowerBound == held.range.lowerBound + "A line the user just typed.\n\n".count)
        // The stored body hash moved with it, so the NEXT resolve is `.exact`
        // rather than a search — the whole reason the range is refreshed at all.
        #expect(now.bodyHash == ContentUndoStore.hash(after))
        #expect(PassageResolver.anchor(now, in: after) == .exact)
    }

    /// TYPING BELOW IT LEAVES IT EXACTLY WHERE IT WAS. Same handle, same
    /// offsets — only the document's length and hash moved.
    @Test func typingBelowAHeldPassageLeavesItsOffsetsAlone() {
        let registry = PassageRegistry()
        let held = hold("This document sets out what we are for, before the next review.", in: registry)
        let after = brief + "\n\nA closing line the user just typed."

        _ = PassageRefresh.after(
            before: snapshot(brief), after: snapshot(after), place: .application("quill"),
            registry: registry, ambient: AmbientContextStore(), undo: ContentUndoStore())

        let now = try! #require(following(held.handle, in: registry))
        #expect(now.handle == held.handle)
        #expect(now.range == held.range)
        #expect(now.bodyLength == after.count)
        #expect(PassageResolver.anchor(now, in: after) == .exact)
    }

    /// A CHANGE THAT COVERS ONE EDGE AND NOT THE OTHER IS REFUSED. The passage
    /// has been made into something nobody named, and no shift is honest about
    /// it — so nothing is minted and the handle falls through to
    /// `PassageResolver.driftedSentence` on its next use, which is the correct
    /// and now-honest answer.
    @Test func aChangeStraddlingOneEdgeRefreshesNothing() {
        let registry = PassageRegistry()
        let held = hold("This document sets out what we are for, before the next review.", in: registry)
        let after = brief.replacingOccurrences(
            of: "before the next review.\n\nBudget",
            with: "before the next review, and for whom.\n\nRemit")

        let moved = PassageRefresh.after(
            before: snapshot(brief), after: snapshot(after), place: .application("quill"),
            registry: registry, ambient: AmbientContextStore(), undo: ContentUndoStore())
        #expect(moved == 0)
        #expect(registry.resolve(held.handle) == .live(held))
        // And the sentence it falls through to says what is true whoever changed
        // it, and never that the section is absent.
        let spoken = try! #require(PassageResolver.refusal(
            PassageResolver.anchor(held, in: after), for: held))
        #expect(spoken.contains("has changed in Brief since I picked it up"))
        #expect(!spoken.contains("isn't in"))
    }

    // MARK: - The boundary, reused rather than re-decided

    /// THE CARET AT A PASSAGE'S EDGES, and both answers come from
    /// `PassageUnit.contains` — the rule this tree already settled for
    /// `AbilityRuntime`'s unit lookup and `PassageEdit`'s inserts. An empty span
    /// at the upper bound belongs to the SEAM; at the lower bound it belongs to
    /// the unit.
    ///
    /// Re-deciding either answer here would put a third opinion about the same
    /// question in the tree, which is exactly how "insert after this" once
    /// landed inside the thing it was meant to follow.
    @Test func theCaretAtTheEdgesFollowsTheTreesOwnContainmentRule() {
        let held = PassageUnit(range: 10..<20, kind: .paragraph)
        #expect(PassageRefresh.shift(held, by: 10..<10, delta: 4) == .grown(10..<24))
        #expect(PassageRefresh.shift(held, by: 20..<20, delta: 4) == .unchanged)
        // A non-empty change ending exactly where the passage starts is above it.
        #expect(PassageRefresh.shift(held, by: 6..<10, delta: 4) == .moved(14..<24))
        // And one starting exactly where it ends is below it.
        #expect(PassageRefresh.shift(held, by: 20..<24, delta: 4) == .unchanged)
        // Covering one edge only.
        #expect(PassageRefresh.shift(held, by: 8..<12, delta: 4) == .straddled)
        #expect(PassageRefresh.shift(held, by: 18..<22, delta: 4) == .straddled)
        // Covering the whole thing is not containment either — the passage does
        // not contain the change, so it is not grown.
        #expect(PassageRefresh.shift(held, by: 5..<25, delta: 4) == .straddled)
        // And it agrees with the rule it borrows, in both directions.
        #expect(held.contains(10..<10))
        #expect(!held.contains(20..<20))
    }

    /// A DELETION SHIFTS BACKWARDS AND NEVER OFF THE FRONT OF THE STRING. The
    /// same three tests with a negative delta, because every landing has to be
    /// in bounds of the AFTER string by arithmetic rather than by clamping.
    @Test func aDeletionShiftsBackwardsAndStaysInBounds() {
        let registry = PassageRegistry()
        let held = hold("Everything the team touches this quarter, and nothing else.", in: registry)
        let after = brief.replacingOccurrences(of: "Purpose and scope\n\n", with: "")

        _ = PassageRefresh.after(
            before: snapshot(brief), after: snapshot(after), place: .application("quill"),
            registry: registry, ambient: AmbientContextStore(), undo: ContentUndoStore())

        let now = try! #require(following(held.handle, in: registry))
        #expect(now.handle == held.handle)
        #expect(now.range.lowerBound == held.range.lowerBound - "Purpose and scope\n\n".count)
        #expect(now.range.upperBound <= after.count)
        #expect(PassageWidening.substring(of: after, now.range) == held.text)
    }

    /// A DELETION THAT SWALLOWS THE PASSAGE WHOLE LEAVES NOTHING TO POINT AT.
    /// No handle is minted over an empty span — one would resolve to `.gone` on
    /// its next use anyway, and a handle that silently means nothing is worse
    /// than a handle that says so.
    @Test func aPassageDeletedOutrightIsNotReMintedOverNothing() {
        let registry = PassageRegistry()
        let held = hold("Everything the team touches this quarter, and nothing else.", in: registry)
        let after = brief.replacingOccurrences(
            of: "Everything the team touches this quarter, and nothing else.", with: "")

        let moved = PassageRefresh.after(
            before: snapshot(brief), after: snapshot(after), place: .application("quill"),
            registry: registry, ambient: AmbientContextStore(), undo: ContentUndoStore())
        #expect(moved == 0)
        #expect(registry.resolve(held.handle) == .live(held))
    }

    // MARK: - The guards that make a mis-routed call harmless

    /// A SWAPPED DOCUMENT REFRESHES NOTHING. Two snapshots of different
    /// documents describe no single change, and `changedSpan` handed an
    /// unrelated pair returns a span covering most of both — which would shift
    /// every handle by the difference in length between two unrelated files.
    @Test func aSwappedDocumentKeyRefreshesNothing() {
        let registry = PassageRegistry()
        let held = hold("This document sets out what we are for, before the next review.", in: registry)
        let undo = ContentUndoStore()

        let moved = PassageRefresh.after(
            before: snapshot(brief),
            after: snapshot("An entirely different document.", key: "/Users/x/Other.pages"),
            place: .application("quill"), registry: registry, ambient: AmbientContextStore(), undo: undo)
        #expect(moved == 0)
        #expect(registry.resolve(held.handle) == .live(held))
        // Nothing was recorded either — an undo entry from a swap would offer to
        // put one document back over another.
        #expect(undo.entry(for: key) == nil)
        #expect(undo.entry(for: "/Users/x/Other.pages") == nil)
    }

    /// AN UNCHANGED BODY REFRESHES NOTHING. `resume_typing` with nothing left to
    /// type, or a write the app quietly refused, is not an edit — and this is
    /// what makes bracketing a recipe that turned out not to write cost nothing
    /// but the two reads.
    @Test func anUnchangedBodyRefreshesNothingAndRecordsNoUndo() {
        let registry = PassageRegistry()
        let held = hold("This document sets out what we are for, before the next review.", in: registry)
        let undo = ContentUndoStore()

        let moved = PassageRefresh.after(
            before: snapshot(brief), after: snapshot(brief), place: .application("quill"),
            registry: registry, ambient: AmbientContextStore(), undo: undo)
        #expect(moved == 0)
        #expect(registry.resolve(held.handle) == .live(held))
        #expect(undo.entry(for: key) == nil)
    }

    /// HANDLES IN OTHER WORLDS AND OTHER DOCUMENTS ARE NOT TOUCHED. The world
    /// comes from the caller's own focus lead and the key from the snapshot; a
    /// refresh that swept everything would re-aim an Xcode handle at offsets
    /// measured in a Pages document.
    @Test func onlyThisWorldsHandlesInThisDocumentMove() {
        let registry = PassageRegistry()
        let here = hold("This document sets out what we are for, before the next review.", in: registry)
        let elsewhere = PassageRecipes.mintRead(
            place: .application("forge"), documentKey: "/Users/x/App.swift", documentTitle: "App.swift",
            body: brief, range: offsets("Budget"), kind: .declaration, registry: registry)!
        let otherDocument = PassageRecipes.mintRead(
            place: .application("quill"), documentKey: "/Users/x/Other.pages", documentTitle: "Other",
            body: brief, range: offsets("Purpose and scope"), kind: .section, registry: registry)!

        let after = "A line the user just typed.\n\n" + brief
        let moved = PassageRefresh.after(
            before: snapshot(brief), after: snapshot(after), place: .application("quill"),
            registry: registry, ambient: AmbientContextStore(), undo: ContentUndoStore())
        #expect(moved == 1)
        #expect(following(here.handle, in: registry)?.range.lowerBound
            == here.range.lowerBound + "A line the user just typed.\n\n".count)
        #expect(registry.resolve(elsewhere.handle) == .live(elsewhere))
        #expect(registry.resolve(otherDocument.handle) == .live(otherDocument))
    }

    // MARK: - Undo

    /// THE UNDO ENTRY FOR A CARET WRITE. Without it, the paragraph she typed
    /// thirty seconds ago is the one thing in the document "undo that"
    /// disclaims — `revert_last_edit` would answer "I don't have a change of my
    /// own to take back" about a change she had just made.
    ///
    /// Recorded against what the document ACTUALLY holds, which is
    /// `PassageEditRunner.edit`'s step 9a: the hash guard on the way back out is
    /// armed with the APPLIED text, so recording anything else would make every
    /// revert refuse.
    @Test func aCaretWriteBecomesSomethingRevertCanTakeBack() {
        let registry = PassageRegistry()
        hold("This document sets out what we are for, before the next review.", in: registry)
        let undo = ContentUndoStore()
        let after = brief.replacingOccurrences(
            of: "sets out what we are for", with: "sets out, plainly, what we are for")

        _ = PassageRefresh.after(
            before: snapshot(brief), after: snapshot(after), place: .application("quill"),
            registry: registry, ambient: AmbientContextStore(), undo: undo)

        let prior = try! #require(undo.take(
            for: key, currentHash: ContentUndoStore.hash(after)))
        #expect(prior == brief)
    }

    // MARK: - The held fact

    /// A PASSAGE THAT MERELY MOVED KEEPS WHAT SHE ALREADY SAID ABOUT IT.
    ///
    /// `refreshHeldFact` clears `spokenAt`/`spokenNote` on the EDIT path, and it
    /// is right to: what she said about the old wording cannot describe the new
    /// wording. It is wrong here. The words are identical, she has already told
    /// the user about them, and un-suppressing that mention would have her say
    /// the same thing twice about a paragraph nobody touched.
    @Test func aMovedPassageKeepsItsSpokenNoteAndAGrownOneLosesIt() {
        let now = Date()
        for typedInside in [false, true] {
            let registry = PassageRegistry()
            let ambient = AmbientContextStore()
            let held = hold(
                "This document sets out what we are for, before the next review.", in: registry)
            ambient.register(AmbientFact(
                world: .applications, application: "quill", slot: .read("Purpose"),
                content: "[\(held.handle)] Brief — characters 0–0 of 0:\n" + held.text,
                subject: "Brief", provenance: .recipeRead, registration: .askedFor,
                capturedAt: now, spokenAt: now, spokenNote: "told them about it",
                passageHandle: held.handle), at: now)

            let after = typedInside
                ? brief.replacingOccurrences(
                    of: "sets out what we are for", with: "sets out, plainly, what we are for")
                : "A line the user just typed.\n\n" + brief

            _ = PassageRefresh.after(
                before: snapshot(brief), after: snapshot(after), place: .application("quill"),
                registry: registry, ambient: ambient, undo: ContentUndoStore(), now: now)

            let landed = try! #require(following(held.handle, in: registry))
            let fact = try! #require(ambient.reads(at: now).first {
                $0.passageHandle == landed.handle
            })
            #expect(fact.spokenAt == (typedInside ? nil : now),
                    "typedInside: \(typedInside)")
            #expect(fact.content.contains(landed.text))
            // The bounds and the total travel with it, so the prompt's
            // "characters N–M of T" is not describing a document that has moved.
            #expect(fact.bounds == landed.range)
            #expect(fact.documentTotal == after.count)
        }
    }
}
