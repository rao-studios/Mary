//
//  KeyChordAimTests.swift
//  MaryComputerUseTests
//
//  WHAT: A chord aimed at an application does not go anywhere else.
//  PIN:  THE ASYMMETRY THIS CLOSES. `KeyboardTyper` has always checked the
//        frontmost bundle before every chunk it types; `KeyChordPress` checked
//        nothing, and the same code uses them one after the other — focus the
//        address bar with a chord, then type. MEASURED during a back-to-back
//        corpus run: the browser lost the stage between trips, ⌘L went to
//        whatever had it, and the navigation reported "I couldn't find the
//        address bar" about a browser it had never reached. A chord is the
//        STRONGER gesture of the two — ⌘W in the wrong window closes somebody's
//        document — so it was the wrong one to leave unguarded.
//        AND NIL STILL MEANS ANYWHERE, which is not an oversight: a system chord
//        or a media key has no application in mind and must not be made to
//        invent one.
//

import Foundation
import Testing
@testable import MaryComputerUse
@testable import MaryFoundation

@Suite struct KeyChordAimTests {

    @Test func aChordAimedAtAnApplicationIsRefusedWhenAnotherIsInFront() {
        let sent = KeyChordPress.press(
            key: .l, modifiers: [.command],
            targetPrefix: "com.google.Chrome",
            frontmost: { "com.apple.dt.Xcode" })
        #expect(sent == false)
    }

    @Test func aChordAimedAtTheApplicationInFrontGoesThrough() {
        let sent = KeyChordPress.press(
            key: .l, modifiers: [.command],
            targetPrefix: "com.google.Chrome",
            frontmost: { "com.google.Chrome" })
        #expect(sent)
    }

    /// A PREFIX, LIKE THE TYPER'S — a helper process or a variant build answers
    /// to the same aim.
    @Test func aPrefixMatchIsTheApplication() {
        #expect(KeyChordPress.press(
            key: .l, modifiers: [.command],
            targetPrefix: "com.google.Chrome",
            frontmost: { "com.google.Chrome.beta" }))
    }

    /// NOTHING IN FRONT IS NOT THE APPLICATION.
    @Test func aChordIsRefusedWhenNothingIsInFront() {
        #expect(!KeyChordPress.press(
            key: .l, modifiers: [.command],
            targetPrefix: "com.google.Chrome",
            frontmost: { nil }))
    }

    /// AN UNAIMED CHORD IS UNCHANGED. See the file header.
    @Test func anUnaimedChordNeverConsultsTheFrontmostApplication() {
        var asked = false
        _ = KeyChordPress.press(
            key: .escape, modifiers: [],
            targetPrefix: nil,
            frontmost: { asked = true; return "com.apple.dt.Xcode" })
        #expect(!asked)
    }
}
