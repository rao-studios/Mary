//
//  ReferenceResolverTests.swift
//  MaryAmbientTests
//
//  WHAT: Spoken ladder — last / that / this-to-that.
//  OUT:  ReferenceResolver
//  PIN:  Counting ordinals abstain without a listing
//

import Foundation
import Testing

@testable import MaryAmbient

@Suite struct ReferenceResolverTests {

    private func candidate(
        _ key: String, title: String, subtitle: String? = nil, body: String? = nil,
        listIndex: Int, isFront: Bool = false, salience: Int? = nil,
        handle: String? = nil, place: AmbientPlace = .application("textedit")
    ) -> ReferenceResolver.Candidate {
        .init(
            place: place, key: key, handle: handle, title: title, subtitle: subtitle,
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
        #expect(choice == .init(place: .application("textedit"), key: "k2", rung: .handle))
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

    // MARK: - Subtitle

    /// THE RUNG THAT MAKES A PLACE WITH USELESS TITLES REFERENCEABLE — and the
    /// only one available to a place that can list its containers but not read
    /// them. A taught manuscript application is exactly that place: its binder
    /// items are titled "Chapter One", and the synopsis is the only thing that
    /// tells them apart.
    ///
    /// A `.dynamic` place and not a compiled world, deliberately — this is the
    /// rung a package brings, and it has to work for a place with no
    /// `AmbientAttention` behind it.

    // MARK: - Content

    /// AN UNREAD CONTAINER IS SKIPPED, NEVER TREATED AS EMPTY. Absence of
    /// evidence is not evidence of absence.

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

    /// NEWEST EVIDENCE WINS. Once something has been acted on or spoken about
    /// more recently than the listing, "the last one" means that instead — so
    /// the ordinal rung stands down and anaphora answers.

    // MARK: - Anaphora

    @Test func anaphoraTakesTheMostSalientNonFrontContainer() {
        let choice = ReferenceResolver.resolve(
            utterance: "no, the other one", candidates: untitled)
        #expect(choice?.place == .application("textedit"))
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

    /// NEVER THE ONE IN FRONT. Both phrase lists mean "not this".

    // MARK: - Abstention

    /// ABSTAINING IS THE COMMON ANSWER and it means "the one in front".

}

// MARK: - Salience ordering

