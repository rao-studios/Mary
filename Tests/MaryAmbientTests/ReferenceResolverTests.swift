//
//  ReferenceResolverTests.swift
//  BonnieAmbientTests
//
//  THE BOUNDARY with BonnieBrainTests/ReferenceFocusTests.swift, so neither
//  suite grows the other's cases: RESOLVER (this file) is the resolution of
//  a reference to a target; FOCUS (that file) is the arbitration of which
//  reference wins the turn. Do not merge them.
//
//  THE SHARED LADDER, and the sentences it exists to answer:
//  "open the last one" / "bring the last one forward" / "look at that one" /
//  "add this to that one".
//
//  Every case here is world-agnostic on purpose. `TextEditTests`' nine resolver
//  tests still exercise the same matchers through TextEdit's shim, unedited —
//  that pair is the proof the extraction changed nothing while making it
//  general.
//

import Foundation
import Testing

@testable import MaryAmbient

@Suite struct ReferenceResolverTests {

    private func candidate(
        _ key: String, title: String, subtitle: String? = nil, body: String? = nil,
        listIndex: Int, isFront: Bool = false, salience: Int? = nil,
        handle: String? = nil, realm: AmbientRealm = .dynamic("textedit")
    ) -> ReferenceResolver.Candidate {
        .init(
            realm: realm, key: key, handle: handle, title: title, subtitle: subtitle,
            body: body, listIndex: listIndex, isFront: isFront, salience: salience)
    }

    /// THE CORPUS THAT ACTUALLY EXISTS: eleven notes, every one `Untitled N`.
    private var untitled: [ReferenceResolver.Candidate] {
        [
            candidate("k1", title: "Untitled", subtitle: "grocery list",
                      body: "grocery list\noat milk\nsourdough", listIndex: 1, isFront: true),
            candidate("k2", title: "Untitled 21", subtitle: "ambient engine notes",
                      body: "ambient engine notes\nrouting", listIndex: 2, salience: 0),
            candidate("k3", title: "Untitled 23", subtitle: "call the dentist Tuesday",
                      body: "call the dentist Tuesday", listIndex: 3, salience: 1),
        ]
    }

    // MARK: - Handle

    @Test func aMintedHandleWins() {
        let rows = [
            candidate("k1", title: "A", listIndex: 1, isFront: true, handle: "W1"),
            candidate("k2", title: "B", listIndex: 2, handle: "W2"),
        ]
        let choice = ReferenceResolver.resolve(utterance: "change it in [W2]", candidates: rows)
        #expect(choice == .init(realm: .dynamic("textedit"), key: "k2", rung: .handle))
    }

    @Test func anInventedHandleAbstains() {
        let choice = ReferenceResolver.resolve(
            utterance: "read [W9] to me",
            candidates: [candidate("k1", title: "A", listIndex: 1, handle: "W1")])
        #expect(choice == nil)
    }

    // MARK: - Title

    /// "untitled" is contained in ALL of them, so it identifies none — and the
    /// resolver must say so rather than taking the front one.
    @Test func aTitleNamingTheWholeFamilyAbstains() {
        #expect(ReferenceResolver.resolve(
            utterance: "put it in the untitled one", candidates: untitled) == nil)
    }

    @Test func theStrictlyMoreSpecificTitleWins() {
        let choice = ReferenceResolver.resolve(
            utterance: "read me untitled 21", candidates: untitled)
        #expect(choice?.key == "k2")
        #expect(choice?.rung == .title)
    }

    // MARK: - Subtitle

    /// THE RUNG THAT MAKES A PLACE WITH USELESS TITLES REFERENCEABLE — and the
    /// only one available to a place that can list its containers but not read
    /// them. A taught manuscript application is exactly that place: its binder
    /// items are titled "Chapter One", and the synopsis is the only thing that
    /// tells them apart.
    ///
    /// A `.dynamic` realm and not a compiled world, deliberately — this is the
    /// rung a package brings, and it has to work for a realm with no
    /// `AmbientWorld` behind it.
    @Test func theSubtitleCarriesAWorldThatCannotBeRead() {
        let rows = [
            candidate("d1", title: "Chapter One", subtitle: "Bea arrives in the rain",
                      listIndex: 1, isFront: true, realm: .dynamic("manuscripts")),
            candidate("d2", title: "Chapter Two", subtitle: "the orchard confrontation",
                      listIndex: 2, realm: .dynamic("manuscripts")),
        ]
        let choice = ReferenceResolver.resolve(
            utterance: "read me the orchard scene", candidates: rows)
        #expect(choice?.key == "d2")
        #expect(choice?.rung == .subtitle)
        // Neither has a body; the content rung could never have answered this.
        #expect(rows.allSatisfy { $0.body == nil })
    }

    // MARK: - Content

    @Test func contentPicksTheNoteWhenTitlesCannot() {
        let choice = ReferenceResolver.resolve(
            utterance: "in my note about sourdough, change oat milk", candidates: untitled)
        #expect(choice?.key == "k1")
    }

    /// AN UNREAD CONTAINER IS SKIPPED, NEVER TREATED AS EMPTY. Absence of
    /// evidence is not evidence of absence.
    @Test func contentIgnoresContainersWithNoCachedBody() {
        let rows = [
            candidate("k1", title: "A", body: "ambient engine notes", listIndex: 1),
            candidate("k2", title: "B", body: nil, listIndex: 2, isFront: true),
        ]
        let choice = ReferenceResolver.resolve(
            utterance: "the ambient one", candidates: rows)
        #expect(choice?.key == "k1")
    }

    // MARK: - Ordinal

    /// "Open the last one" right after a listing means THE LAST ROW.
    @Test func theLastOneTakesTheRosterTailWhenTheListingIsNewest() {
        let choice = ReferenceResolver.resolve(
            utterance: "open the last one", candidates: untitled,
            listing: ["k1", "k2", "k3"], listingIsNewestEvidence: true)
        #expect(choice?.key == "k3")
        #expect(choice?.rung == .ordinal)
    }

    @Test func aCountingOrdinalResolvesAgainstTheListing() {
        let choice = ReferenceResolver.resolve(
            utterance: "bring the second one forward", candidates: untitled,
            listing: ["k1", "k2", "k3"], listingIsNewestEvidence: true)
        #expect(choice?.key == "k2")
    }

    /// THE RULE THAT KEEPS THIS FROM BEING CONFIDENT AND WRONG: indexing into
    /// an enumeration the user never saw is a coin toss, so a counting ordinal
    /// with no listing ABSTAINS.
    @Test func aCountingOrdinalAbstainsWithNoListing() {
        #expect(ReferenceResolver.resolve(
            utterance: "bring the second one forward", candidates: untitled) == nil)
    }

    /// NEWEST EVIDENCE WINS. Once something has been acted on or spoken about
    /// more recently than the listing, "the last one" means that instead — so
    /// the ordinal rung stands down and anaphora answers.
    @Test func theLastOneFallsToSalienceWhenTheListingIsStale() {
        let choice = ReferenceResolver.resolve(
            utterance: "add this to the last one", candidates: untitled,
            listing: ["k1", "k2", "k3"], listingIsNewestEvidence: false)
        // k2 is the most salient non-front container.
        #expect(choice?.key == "k2")
        #expect(choice?.rung == .anaphora)
    }

    // MARK: - Anaphora

    @Test func anaphoraTakesTheMostSalientNonFrontContainer() {
        let choice = ReferenceResolver.resolve(
            utterance: "no, the other one", candidates: untitled)
        #expect(choice?.realm == .dynamic("textedit"))
        #expect(choice?.key == "k2")
        #expect(choice?.rung == .anaphora)
        // Salience PICKED between real rivals, so this is a decision with a
        // reason — and the runner-up is carried, because a correction needs
        // something to re-aim at.
        #expect(choice?.confidence == .chosen)
        #expect(choice?.alternative?.key == "k3")
    }

    /// N = 2 IS EXACT. Two containers, one in front — "the other one" has
    /// precisely one answer and needs no salience at all.
    @Test func withTwoContainersTheOtherOneIsExact() {
        let rows = [
            candidate("k1", title: "A", listIndex: 1, isFront: true),
            candidate("k2", title: "B", listIndex: 2, salience: nil),
        ]
        let choice = ReferenceResolver.resolve(utterance: "the other one", candidates: rows)
        #expect(choice?.key == "k2")
    }

    @Test func anaphoraWithNoEvidenceAbstains() {
        let rows = [
            candidate("k1", title: "A", listIndex: 1, isFront: true),
            candidate("k2", title: "B", listIndex: 2),
            candidate("k3", title: "C", listIndex: 3),
        ]
        #expect(ReferenceResolver.resolve(utterance: "the other one", candidates: rows) == nil)
    }

    /// NEVER THE ONE IN FRONT. Both phrase lists mean "not this".
    @Test func anaphoraNeverPicksTheFrontContainer() {
        let rows = [
            candidate("k1", title: "A", listIndex: 1, isFront: true, salience: 0),
            candidate("k2", title: "B", listIndex: 2, salience: 5),
        ]
        let choice = ReferenceResolver.resolve(utterance: "the other one", candidates: rows)
        #expect(choice?.key == "k2")
    }

    // MARK: - Abstention

    /// ABSTAINING IS THE COMMON ANSWER and it means "the one in front".
    @Test(arguments: [
        "tighten that second paragraph",
        "read this back to me",
        "make it shorter",
        "",
    ])
    func anOrdinaryTurnAbstains(_ utterance: String) {
        #expect(ReferenceResolver.resolve(utterance: utterance, candidates: untitled) == nil)
    }

    @Test func noCandidatesIsAbstention() {
        #expect(ReferenceResolver.resolve(utterance: "the other one", candidates: []) == nil)
    }
}

// MARK: - Salience ordering

@Suite struct ContainerSalienceTests {

    /// THE CLASS ORDER, as a table. Acted on beats a structural read, then a
    /// spoken mention, touched, and shown, whatever the timestamps say
    /// — because mixing "the user
    /// touched it" with "Mary mentioned it" on one scale is how a coin toss
    /// acquires a score.
    @Test func classOutranksRecency() {
        let registry = ContainerRegistry()
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 2_000)

        // The weaker class is far more RECENT, and must still lose.
        registry.noteEvidence(realm: .dynamic("textedit"), key: "acted", .actedOn, at: old)
        registry.noteEvidence(realm: .dynamic("textedit"), key: "touched", .touched, at: recent)

        let ranks = registry.salienceRanks(
            realm: .dynamic("textedit"), keys: ["touched", "acted"], at: recent)
        #expect(ranks["acted"] == 0)
        #expect(ranks["touched"] == 1)
    }

    @Test func aStructuralReadOutranksFrontmostState() {
        let registry = ContainerRegistry()
        let now = Date(timeIntervalSince1970: 2_000)
        registry.noteEvidence(
            realm: .dynamic("textedit"), key: "read", .read,
            at: now.addingTimeInterval(-500))
        registry.noteEvidence(
            realm: .dynamic("textedit"), key: "front", .touched,
            at: now)

        let ranks = registry.salienceRanks(
            realm: .dynamic("textedit"), keys: ["front", "read"], at: now)
        #expect(ranks["read"] == 0)
        #expect(ranks["front"] == 1)
    }

    @Test func aVerifiedReadOutranksAnOlderSpokenMention() {
        let registry = ContainerRegistry()
        let now = Date(timeIntervalSince1970: 2_000)
        registry.noteEvidence(
            realm: .dynamic("textedit"), key: "mentioned", .spokenAbout,
            at: now.addingTimeInterval(-10))
        registry.noteEvidence(
            realm: .dynamic("textedit"), key: "read", .read,
            at: now)

        let ranks = registry.salienceRanks(
            realm: .dynamic("textedit"), keys: ["mentioned", "read"], at: now)
        #expect(ranks["read"] == 0)
        #expect(ranks["mentioned"] == 1)
    }

    @Test func withinAClassTheNewestWins() {
        let registry = ContainerRegistry()
        registry.noteEvidence(
            realm: .dynamic("textedit"), key: "older", .spokenAbout,
            at: Date(timeIntervalSince1970: 1_000))
        registry.noteEvidence(
            realm: .dynamic("textedit"), key: "newer", .spokenAbout,
            at: Date(timeIntervalSince1970: 2_000))

        let ranks = registry.salienceRanks(
            realm: .dynamic("textedit"), keys: ["older", "newer"],
            at: Date(timeIntervalSince1970: 2_000))
        #expect(ranks["newer"] == 0)
        #expect(ranks["older"] == 1)
    }

    /// A container nothing referential has happened to has NO rank — which is
    /// what keeps a never-mentioned note out of every anaphoric pick.
    @Test func noEvidenceIsNoRank() {
        let registry = ContainerRegistry()
        #expect(registry.salienceRanks(realm: .dynamic("textedit"), keys: ["a", "b"]).isEmpty)
        #expect(registry.evidence(realm: .dynamic("textedit"), key: "a") == nil)
    }

    /// CONVERSATION MEMORY EXPIRES; WORLD STATE DOES NOT. `.touched` is a fact
    /// about the live enumeration and dies when the container closes, so it
    /// carries no clock — the other conversation classes ride the ambient
    /// store's own window.
    @Test func conversationMemoryExpiresAndWorldStateDoesNot() {
        let registry = ContainerRegistry()
        let then = Date(timeIntervalSince1970: 1_000)
        let muchLater = then.addingTimeInterval(ContainerRegistry.evidenceRetention + 60)

        registry.noteEvidence(realm: .dynamic("textedit"), key: "spoken", .spokenAbout, at: then)
        registry.noteEvidence(realm: .dynamic("textedit"), key: "read", .read, at: then)
        registry.noteEvidence(realm: .dynamic("textedit"), key: "touched", .touched, at: then)

        #expect(registry.evidence(realm: .dynamic("textedit"), key: "spoken", at: muchLater) == nil)
        #expect(registry.evidence(realm: .dynamic("textedit"), key: "read", at: muchLater) == nil)
        #expect(registry.evidence(realm: .dynamic("textedit"), key: "touched", at: muchLater)?.kind
            == .touched)
    }

    /// The retention is DERIVED from the ambient store's, not duplicated, so a
    /// salience claim can never outlive the prompt that could explain it.
    @Test func retentionIsDerivedFromTheStore() {
        #expect(ContainerRegistry.evidenceRetention
            == AmbientFact.defaultRetention(slot: .read("")))
    }

    /// A LISTING IS WHAT "SHOWN" MEANS. Minting deliberately does NOT stamp it.
    ///
    /// CAUGHT LIVE: `ReferenceFocus.resolve` mints a handle for every candidate
    /// on every turn, so stamping `.shown` at mint time gave all eight of the
    /// user's open notes evidence with near-identical timestamps — and "the
    /// other one" then resolved to whichever was minted last, which is roster
    /// order. A coin toss wearing a rank.
    @Test func onlyAListingCountsAsBeingShown() {
        let registry = ContainerRegistry()
        _ = registry.handle(realm: .dynamic("textedit"), prefix: "W", key: "k")
        #expect(registry.evidence(realm: .dynamic("textedit"), key: "k") == nil)

        registry.noteListing(realm: .dynamic("textedit"), keys: ["k"])
        #expect(registry.evidence(realm: .dynamic("textedit"), key: "k")?.kind == .shown)
    }

    /// THE USER'S ATTENTION BEATS A LISTING. A listing stamps every container
    /// at once, so `.shown` is the least discriminating signal there is; the
    /// user having been IN one of them is a fact about exactly one.
    @Test func touchedOutranksShown() {
        let registry = ContainerRegistry()
        let now = Date(timeIntervalSince1970: 5_000)
        // The listing is NEWER, and must still lose.
        registry.noteEvidence(
            realm: .dynamic("textedit"), key: "visited", .touched, at: now.addingTimeInterval(-500))
        registry.noteListing(realm: .dynamic("textedit"), keys: ["listed"], at: now)

        let ranks = registry.salienceRanks(
            realm: .dynamic("textedit"), keys: ["listed", "visited"], at: now)
        #expect(ranks["visited"] == 0)
        #expect(ranks["listed"] == 1)
    }

    /// AN UNBREAKABLE TIE IS NOT A RANK. A roster of eight notes stamps eight
    /// identical `.shown` entries; handing one of them rank 0 is a coin toss
    /// wearing a number, so all of them are dropped and anaphora abstains.
    @Test func containersTiedAtTheSameInstantGetNoRank() {
        let registry = ContainerRegistry()
        let now = Date(timeIntervalSince1970: 9_000)
        registry.noteListing(realm: .dynamic("textedit"), keys: ["a", "b", "c"], at: now)

        let ranks = registry.salienceRanks(
            realm: .dynamic("textedit"), keys: ["a", "b", "c"], at: now)
        #expect(ranks.isEmpty, "a listing must not rank its own rows against each other")
    }

    /// ONLY SAME-CLASS TIES DROP. Two containers in DIFFERENT classes are
    /// distinguishable however close their timestamps, so both still rank — the
    /// tie rule is about indistinguishability, not about crowding.
    @Test func differentClassesAreNeverATieHoweverCloseTheClock() {
        let registry = ContainerRegistry()
        let now = Date(timeIntervalSince1970: 9_000)
        registry.noteListing(realm: .dynamic("textedit"), keys: ["a", "b"], at: now)
        registry.noteEvidence(realm: .dynamic("textedit"), key: "b", .actedOn, at: now)

        let ranks = registry.salienceRanks(realm: .dynamic("textedit"), keys: ["a", "b"], at: now)
        #expect(ranks["b"] == 0)   // acted on
        #expect(ranks["a"] == 1)   // merely shown, but still the only rival
    }
}
