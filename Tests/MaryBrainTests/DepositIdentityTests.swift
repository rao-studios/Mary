//
//  DepositIdentityTests.swift
//  MaryBrainTests
//
//  The naming scheme deposits and retrieval SHARE. Every failure this suite
//  guards is silent at runtime — a drifting id doesn't error, it just stops
//  matching, and memory quietly returns nothing (or, worse, everything).
//

import Foundation
import Testing
@testable import MaryBrain
@testable import MaryPlugin
@testable import MaryAmbient

@Suite struct DepositIdentityTests {

    // MARK: - Stability

    /// The whole supersession story rests on this: the same document must
    /// hash to the same id in a LATER PROCESS. Swift's `Hasher` is seeded per
    /// process and would silently reintroduce the append-only behavior.
    @Test func stableHashIsDeterministicAndNotProcessSeeded() {
        #expect(DepositSubject.stableHash("pages|essay") == DepositSubject.stableHash("pages|essay"))
        #expect(DepositSubject.stableHash("a") != DepositSubject.stableHash("b"))
        // Pinned literal: a change here silently orphans every existing
        // scoped deposit, so it must be a deliberate edit.
        #expect(DepositSubject.stableHash("") == "cbf29ce484222325")
        #expect(DepositSubject.stableHash("pages|essay.pages").count == 16)
    }

    @Test func redepositingTheSameDocumentYieldsTheSameID() {
        let first = DepositSubject(
            app: "pages", documentIdentity: "Essay.pages",
            capturedAt: Date(timeIntervalSince1970: 0))
        let later = DepositSubject(
            app: "pages", documentIdentity: "Essay.pages",
            capturedAt: Date(timeIntervalSince1970: 99_999))
        #expect(first.stateDocumentID(ownerID: "o") == later.stateDocumentID(ownerID: "o"))
        #expect(first.groupID(ownerID: "o") == later.groupID(ownerID: "o"))
        // capturedAt is metadata, never identity — a snapshot taken a day
        // later is the SAME document, which is the point.
        #expect(first.stateDocumentID(ownerID: "o")?.hasPrefix("mary-doc-") == true)
        #expect(first.groupID(ownerID: "o")?.hasPrefix("mary-scope-") == true)
    }

    /// Naming is identity, exactly as in the graph composer: spelling wobble
    /// must not mint a second document.
    @Test func identityIsCanonicalizedNotLiteral() {
        let plain = DepositSubject(app: "pages", documentIdentity: "Essay.pages")
        let noisy = DepositSubject(app: " PAGES ", documentIdentity: "  Essay.pages  ")
        #expect(plain.stateDocumentID(ownerID: "o") == noisy.stateDocumentID(ownerID: "o"))
    }

    // MARK: - Separation

    @Test func differentDocumentsAndOwnersNeverCollide() {
        let essay = DepositSubject(app: "pages", documentIdentity: "Essay.pages")
        let notes = DepositSubject(app: "pages", documentIdentity: "Notes.pages")
        #expect(essay.stateDocumentID(ownerID: "o") != notes.stateDocumentID(ownerID: "o"))
        // One Totem DB holds many owners; an un-owned group id would let a
        // second user's deposits be swallowed by the first user's group.
        #expect(essay.groupID(ownerID: "owner-a") != essay.groupID(ownerID: "owner-b"))
    }

    /// The same project-relative path in two checkouts is two files. Without
    /// scope qualification, editing `Sources/main.swift` in project A would
    /// supersede the memory of `Sources/main.swift` in project B.
    @Test func documentIDIsScopeQualified() {
        let a = DepositSubject(
            app: "xcode", documentIdentity: "Sources/main.swift", projectIdentity: "/p/Alpha")
        let b = DepositSubject(
            app: "xcode", documentIdentity: "Sources/main.swift", projectIdentity: "/p/Beta")
        #expect(a.stateDocumentID(ownerID: "o") != b.stateDocumentID(ownerID: "o"))
    }

    // MARK: - Scope granularity

    /// A coding turn scopes to the PROJECT: sibling files in one repo are one
    /// memory, and narrowing to a single file would make retrieval useless
    /// the moment the user switches tabs.
    @Test func codingScopesToProjectAndProseToDocument() {
        let code = DepositSubject(
            app: "xcode", documentIdentity: "Sources/main.swift", projectIdentity: "/p/Alpha")
        let sibling = DepositSubject(
            app: "xcode", documentIdentity: "Sources/other.swift", projectIdentity: "/p/Alpha")
        #expect(code.groupID(ownerID: "o") == sibling.groupID(ownerID: "o"))
        #expect(code.groupLabel == "Xcode — Alpha")

        // A Pages document has no enclosing project — it IS the world.
        let prose = DepositSubject(app: "pages", documentIdentity: "Essay.pages")
        #expect(prose.groupLabel == "Pages — Essay.pages")
        #expect(prose.groupID(ownerID: "o") != code.groupID(ownerID: "o"))
    }

    // MARK: - Retrieval scope

    /// The user's decision, mechanized: a focused document narrows retrieval
    /// to its own group and shuts `aggregate` off — the document group LEADS,
    /// and long-term memory plus the legacy pool ride along as background.
    @Test func focusedRetrievalIsExclusiveUnfocusedIsGeneral() {
        let focused = DepositSubject(app: "pages", documentIdentity: "Essay.pages")
        let scope = focused.retrievalScope(ownerID: "o")
        #expect(scope.aggregate == false)
        // MOVED DELIBERATELY: `mary-context-o` is new here. It was excluded
        // as "where the deleted paragraph lived", and that exclusion also made
        // every eyeless deposit — calendar, mail, messages, all of which land
        // in this pool because they have no workspace — unreachable on any
        // turn where a document was focused, which is most turns. Document
        // wording is now protected by the live block outranking retrieval and
        // by `.stateSnapshot` supersession; it was never a reason to lose the
        // user's schedule because a text editor was open.
        #expect(scope.groups.map(\.id) == [
            focused.groupID(ownerID: "o"), "memory-o", "resonance-o", "mary-context-o",
        ])

        // Nothing in view: general memory, including the legacy pool. This is
        // byte-identical to the hardcoded shape it replaces.
        #expect(DepositSubject.unfocused.retrievalScope(ownerID: "o") == .general)
        #expect(RetrievalScope.general.aggregate == true)
        #expect(RetrievalScope.general.groups.isEmpty)
        #expect(DepositSubject.unfocused.isFocused == false)
        #expect(focused.isFocused == true)
    }

    /// C1, pinned: a focused turn must still be able to REACH long-term
    /// memory. `aggregate: false` with the document group alone made Seer's
    /// auto-memory and resonance unreachable on every focused turn — and
    /// focused is the normal state, not the exception. The ids are the
    /// server's own, verbatim (`Seer+AutoMemory.swift`,
    /// `handleChatStreamCompletions.swift` / `Realtime.swift`); a typo here
    /// fails silently, as an empty result set.
    @Test func focusedRetrievalStillReachesLongTermMemory() {
        let owner = "Owner-ABC"
        let focused = DepositSubject(
            app: "xcode", documentIdentity: "Sources/main.swift", projectIdentity: "/p/Alpha")
        let ids = focused.retrievalScope(ownerID: owner).groups.map(\.id)
        #expect(ids.contains("memory-Owner-ABC"))
        #expect(ids.contains("resonance-Owner-ABC"))
        // RAW owner id — the server interpolates `request.ownerId` as it
        // arrives. Canonicalizing it here would name a group nothing writes.
        #expect(!ids.contains("memory-owner-abc"))
        // The scope group still LEADS: it is the turn's subject.
        #expect(ids.first == focused.groupID(ownerID: owner))
        #expect(focused.retrievalScope(ownerID: owner).aggregate == false)
        // MOVED DELIBERATELY (C2). This asserted the legacy pool was
        // EXCLUDED. Eyeless deposits have no workspace and land in that pool,
        // so excluding it meant a focused turn could reach nothing Mary had
        // ever remembered about the user's calendar, mail or messages — and
        // "focused" is the normal state. It rides last, as background, behind
        // the scope group and long-term memory.
        #expect(ids.last == "mary-context-Owner-ABC")
    }

    /// The first turn in a brand-new project: the scope group has not been
    /// written yet, so it resolves to nothing server-side. Retrieval must
    /// still have somewhere to look — the whole-turn blackout was the sharpest
    /// edge of C1.
    @Test func aScopeGroupThatDoesNotExistYetStillLeavesMemoryReachable() {
        let brandNew = DepositSubject(
            app: "pages", documentIdentity: "/Users/r/Desktop/Never Seen.pages",
            projectIdentity: "/Users/r/Desktop")
        let groups = brandNew.retrievalScope(ownerID: "o").groups
        #expect(groups.count > 1, "one unknown group would be a zero-result turn")
        #expect(groups.dropFirst().map(\.id)
            == RetrievalScope.memoryGroups(ownerID: "o").map(\.id)
                + [RetrievalScope.legacyPool(ownerID: "o").id])
    }

    /// An app with no document is not a document. Half a subject must fall
    /// back to general memory rather than mint a scope nothing deposits into.
    @Test func partialSubjectsDegradeToUnfocused() {
        #expect(DepositSubject(app: "pages").groupID(ownerID: "o") == nil)
        #expect(DepositSubject(documentIdentity: "Essay.pages").groupID(ownerID: "o") == nil)
        #expect(DepositSubject(app: "  ", documentIdentity: "  ").isFocused == false)
        // A scope with no document identity has nothing to key a snapshot on.
        #expect(DepositSubject(app: "xcode", projectIdentity: "/p/Alpha")
            .stateDocumentID(ownerID: "o") == nil)
    }

    /// M4, pinned: a Scrivener session with no focused chapter used to fall
    /// back to the PROJECT's display name as the document identity, so every
    /// chapter in the manuscript shared one `mary-doc-…` and a snapshot of
    /// chapter 12 superseded the snapshot of chapter 3. A project name must
    /// never key a document snapshot: the group stays right, the document id
    /// goes nil, and the deposit degrades honestly to episodic.
    @Test func aProjectNameNeverKeysADocumentSnapshot() {
        let noChapter = DepositSubject(
            app: "scrivener", documentIdentity: nil, projectIdentity: "/p/Novel.scriv")
        #expect(noChapter.stateDocumentID(ownerID: "o") == nil)
        // The manuscript is still the retrieval unit — scoping survives.
        #expect(noChapter.groupID(ownerID: "o") != nil)
        #expect(noChapter.isFocused)

        let chapterThree = DepositSubject(
            app: "scrivener", documentIdentity: "Chapter Three",
            projectIdentity: "/p/Novel.scriv")
        let chapterTwelve = DepositSubject(
            app: "scrivener", documentIdentity: "Chapter Twelve",
            projectIdentity: "/p/Novel.scriv")
        #expect(chapterThree.stateDocumentID(ownerID: "o")
            != chapterTwelve.stateDocumentID(ownerID: "o"))
        #expect(chapterThree.groupID(ownerID: "o") == chapterTwelve.groupID(ownerID: "o"))
    }
}
