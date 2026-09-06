//
//  SpokenAddressTests.swift
//  MaryFoundationTests
//
//  WHAT: What an address may be opened on the strength of who said it.
//

import Testing
@testable import MaryFoundation

@Suite struct SpokenHostTests {

    /// A BARE HOST IS A HOST. "Go to youtube.com" reaches the gate scheme-less
    /// and was refused as guessing — about a value the person said.
    @Test func aBareHostThePersonSaidIsAdmittedWithItsScheme() {
        #expect(SpokenAddress.admit("youtube.com") == "https://youtube.com")
        #expect(SpokenAddress.admit("Example.co.uk ") == "https://Example.co.uk")
    }

    /// AND A PATH IS STILL A CLAIM: the scheme is not what was missing there.
    @Test func aPathNobodySaidIsStillRefused() {
        #expect(SpokenAddress.admit("example.com/watch?v=abc123xyz") == nil)
        #expect(SpokenAddress.admit("https://example.com/watch?v=abc123xyz") == nil)
    }

    /// A WORD IS NOT AN ADDRESS: nothing is completed that does not look like one.
    @Test func aWordIsNotCompletedIntoAnAddress() {
        #expect(SpokenAddress.admit("youtube") == nil)
        #expect(SpokenAddress.admit("3.5") == nil)
    }
}
