//
//  PointerDriverTests.swift
//  MaryComputerUseTests
//
//  WHAT: Where a normalized point lands, and which space it lands in.
//  OUT:  PointerDriver.screenPoint / .resolve / .Spaces
//  PIN:  Arithmetic only — posting is the probe's job. Every case here used to
//        live inside MaryBrain where nothing could reach it.
//

import CoreGraphics
import Testing
@testable import MaryComputerUse

@Suite struct PointerDriverTests {

    static let window = CGRect(x: 100, y: 200, width: 400, height: 300)

    /// THE CENTRE OF A WINDOW IS THE CENTRE OF THE WINDOW, not of the screen.
    /// A recipe says "click the middle of the content"; the offset is what
    /// makes that mean the same thing on a moved window.
    @Test func normalizedPointsLandInsideTheGivenBounds() {
        #expect(PointerDriver.screenPoint(x: 0.5, y: 0.5, in: Self.window)
                == CGPoint(x: 300, y: 350))
        #expect(PointerDriver.screenPoint(x: 0, y: 0, in: Self.window)
                == CGPoint(x: 100, y: 200))
        #expect(PointerDriver.screenPoint(x: 1, y: 1, in: Self.window)
                == CGPoint(x: 500, y: 500))
    }

    /// OUT OF RANGE MEANS THE EDGE, NOT AN ERROR. A recipe that aims slightly
    /// past a corner meant the corner; refusing would strand it, and wrapping
    /// would click somewhere else entirely.
    @Test(arguments: [(-0.5, 0.0), (1.5, 1.0), (2.0, 1.0)])
    func pointsAreClampedNotWrapped(_ given: Double, _ effective: Double) {
        #expect(PointerDriver.screenPoint(x: given, y: 0.5, in: Self.window)
                == PointerDriver.screenPoint(x: effective, y: 0.5, in: Self.window))
    }

    /// Sub-pixel aims round to a whole point; a fractional CGPoint is not a
    /// place the window server can click.
    @Test func pointsAreRounded() {
        let point = PointerDriver.screenPoint(x: 0.3333, y: 0.6667, in: Self.window)
        #expect(point.x == point.x.rounded())
        #expect(point.y == point.y.rounded())
    }

    // MARK: - Spaces

    /// A SPACE IS A VALUE THIS TRANSACTION OWNS. The previous recipe's anchor
    /// cannot aim this one, because a fresh `Spaces` knows nothing.
    @Test func afreshSpacesKnowsNothing() {
        let spaces = PointerDriver.Spaces()
        #expect(spaces.bounds(named: "row") == nil)
        #expect(spaces.names.isEmpty)
    }

    @Test func aCapturedSpaceIsRecalledByName() {
        var spaces = PointerDriver.Spaces()
        spaces.capture("row", frame: Self.window)
        #expect(spaces.bounds(named: "row") == Self.window)
        #expect(spaces.bounds(named: "other") == nil)
    }

    // MARK: - Resolving a step's space

    /// "content" and the empty string both mean the focused window — the
    /// default a step gets when it names no space at all.
    @Test(arguments: ["content", ""])
    func contentResolvesAgainstTheFocusedWindow(_ space: String) {
        let result = PointerDriver.resolve(
            x: 0.5, y: 0.5, space: space, spaces: .init(), pid: 1,
            focusedWindowFrame: { _ in Self.window })
        #expect(try! result.get() == CGPoint(x: 300, y: 350))
    }

    /// NO WINDOW IS A REFUSAL, NOT A GUESS AT THE SCREEN. Aiming at the
    /// display when the window is gone clicks whatever took its place.
    @Test func aMissingFocusedWindowRefuses() {
        let result = PointerDriver.resolve(
            x: 0.5, y: 0.5, space: "content", spaces: .init(), pid: 1,
            focusedWindowFrame: { _ in nil })
        #expect(result == .failure(.noFocusedWindow))
    }

    /// A named space that was never captured refuses BY NAME, so the spoken
    /// failure can say which region the recipe meant.
    @Test func anUncapturedSpaceRefusesByName() {
        let result = PointerDriver.resolve(
            x: 0.5, y: 0.5, space: "row", spaces: .init(), pid: 1,
            focusedWindowFrame: { _ in Self.window })
        #expect(result == .failure(.noCapturedSpace("row")))
    }

    @Test func aCapturedSpaceAimsInsideItself() {
        var spaces = PointerDriver.Spaces()
        spaces.capture("row", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        let result = PointerDriver.resolve(
            x: 0.5, y: 0.5, space: "row", spaces: spaces, pid: 1,
            focusedWindowFrame: { _ in Self.window })
        #expect(try! result.get() == CGPoint(x: 5, y: 5))
    }
}
