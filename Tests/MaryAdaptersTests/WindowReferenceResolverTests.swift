import Foundation
import Testing
@testable import MaryAdapters

/// THE THREE RUNGS A SPOKEN WINDOW REFERENCE CLIMBS, and the two ties it
/// refuses rather than guessing at.
///
/// Window management had no test of any kind before this file. The resolver is
/// the piece that decides whether "Untitled 47" reaches the right window, and
/// its most important property is negative: a tie NEVER silently chooses the
/// front window, because a raise that lands on the wrong document is worse
/// than a raise that honestly declines.
@Suite struct WindowReferenceResolverTests {

    private let windows = [
        ManagedWindow(id: "501:AXW1", title: "Untitled 47", index: 1),
        ManagedWindow(id: "501:AXW2", title: "Untitled 9", index: 2),
        ManagedWindow(id: "501:AXW3", title: "Shopping List", index: 3),
    ]

    // MARK: - Rung one: the stable id

    @Test func aStableIdResolvesExactly() throws {
        let window = try WindowReferenceResolver.resolve("501:AXW2", in: windows)
        #expect(window.title == "Untitled 9")
    }

    /// `list_app_windows` prints ids inside brackets, so a model that echoes a
    /// row back verbatim must still land.
    @Test func aBracketedStableIdResolves() throws {
        let window = try WindowReferenceResolver.resolve("[501:AXW3]", in: windows)
        #expect(window.title == "Shopping List")
    }

    // MARK: - Rung two: a unique exact title

    @Test func aUniqueExactTitleResolves() throws {
        let window = try WindowReferenceResolver.resolve("Untitled 47", in: windows)
        #expect(window.id == "501:AXW1")
    }

    /// INTERIOR SPACES ARE KEPT ON PURPOSE — the application resolver strips
    /// them so ASR's "text edit" matches "TextEdit", and doing the same here
    /// would collapse "Untitled 9" and "Untitled9" into one window.
    @Test func interiorSpacingIsSignificant() {
        #expect(throws: WindowManagementError.windowNotFound("Untitled47")) {
            try WindowReferenceResolver.resolve("Untitled47", in: windows)
        }
    }

    @Test func twoWindowsWithTheSameTitleRefuseRatherThanGuess() {
        let duplicates = [
            ManagedWindow(id: "501:A", title: "Notes", index: 1),
            ManagedWindow(id: "501:B", title: "Notes", index: 2),
        ]
        #expect(throws: WindowManagementError.ambiguousWindow("Notes")) {
            try WindowReferenceResolver.resolve("Notes", in: duplicates)
        }
    }

    // MARK: - Rung three: a unique containment, both directions

    @Test func aUniqueSubstringOfATitleResolves() throws {
        let window = try WindowReferenceResolver.resolve("Shopping", in: windows)
        #expect(window.id == "501:AXW3")
    }

    @Test func aTitleContainedInTheSpokenPhraseResolves() throws {
        let window = try WindowReferenceResolver.resolve(
            "the Shopping List window", in: windows)
        #expect(window.id == "501:AXW3")
    }

    @Test func anAmbiguousSubstringRefuses() {
        #expect(throws: WindowManagementError.ambiguousWindow("Untitled")) {
            try WindowReferenceResolver.resolve("Untitled", in: windows)
        }
    }

    // MARK: - The empty reference

    /// THE LIVE FAILURE THIS FILE WAS WRITTEN FOR. The model sent `title`
    /// rather than the declared `window`, the binding coalesced the miss to
    /// `""`, and the user read `I couldn't find one open window matching ""`.
    ///
    /// Refusing an empty query is CORRECT and stays — an empty reference must
    /// never fall through to "whatever is in front". The fix lives upstream in
    /// `AbilityRuntime.reconcile`'s declared aliases; this pins the resolver's
    /// half of the contract so a later "be helpful about empties" cannot
    /// quietly reintroduce a guess.
    @Test func anEmptyReferenceIsRefusedRatherThanTakingTheFrontWindow() {
        #expect(throws: WindowManagementError.windowNotFound("")) {
            try WindowReferenceResolver.resolve("", in: windows)
        }
        #expect(throws: WindowManagementError.windowNotFound("   ")) {
            try WindowReferenceResolver.resolve("   ", in: windows)
        }
    }

    @Test func aReferenceThatMatchesNothingIsNotFound() {
        #expect(throws: WindowManagementError.windowNotFound("Budget")) {
            try WindowReferenceResolver.resolve("Budget", in: windows)
        }
    }
}
