//
//  SelectionPlaceConflictTests.swift
//  MaryBrainTests
//
//  THE THIRD BREAK IN THE SELECTION CHAIN, and the subtlest: an Interaction
//  that minted perfectly and was then thrown away one layer later.
//
//  `AmbientAttention.place` is spelled with the BUNDLE id the watcher
//  observed — deliberately and permanently, per
//  `AmbientEngine.applicationProfile(_:represents:)`'s own note. Every NAMED
//  place is spelled with the registration's logical id. `AmbientEngine`'s
//  conflict test compared the two AS PLACES, decided
//  `.application("xcode")` and `.application("com.apple.dt.Xcode")` were
//  different applications, and concluded that the application the utterance
//  named FROM the user's own highlight conflicted WITH that highlight.
//  `selectionDefinesTurn` went false, `AbilityRuntime.routedSignalSnapshot`
//  dropped the selection Interaction before the roster could see it, and
//  every Skill gated on one was ineligible on exactly the turns it exists
//  for.
//
//  Live proof of the shape, before the fix: "make this comment more concise"
//  on a real Xcode selection routed with `defines=false`,
//  `attPlace=.application("com.apple.dt.Xcode")`,
//  `named=[.application("xcode")]`, and an empty routing interaction set.
//

import Foundation
import Testing
import MaryAmbient
import MaryFoundation

@Suite struct SelectionPlaceConflictTests {

    private static var profiles: [ApplicationProfile] {
        taughtRoster.all.map(\.profile)
    }

    private static func selection(
        bundleID: String, at now: Date
    ) -> AmbientAttention {
        AmbientAttention(
            tier: .selection,
            world: .applications,
            applicationID: bundleID,
            selectedText: "// tally the results before we hand them back",
            selectionEditability: .editable,
            selectionSourceEvidence: .exactElement,
            capturedAt: now)
    }

    /// THE BUG, EXACTLY. The utterance names the selection's OWN application
    /// — which is what an address probe does with a highlight in front of it
    /// — and the highlight must therefore define the turn, not be rejected as
    /// conflicting with itself.
    @Test func namingTheSelectionsOwnApplicationIsNotAConflict() {
        let now = Date()
        let attention = Self.selection(bundleID: taughtCodingBundleID, at: now)
        let route = withTaughtRoster {
            AmbientEngine.resolve(AmbientEngine.Inputs(
                utterance: "make this Forge comment more concise",
                attention: attention,
                leadApplicationID: taughtCodingID,
                profiles: Self.profiles,
                now: now))
        }

        // The premise: the utterance really does name a place, spelled with
        // the logical id, and the attention really is spelled with the bundle
        // id. Without both, this test would pass for the wrong reason.
        #expect(route.namedPlaces == [taughtCodingPlace])
        #expect(attention.place == .application(taughtCodingBundleID))
        #expect(attention.place != taughtCodingPlace)

        #expect(route.selectionDefinesTurn)
    }

    /// THE NEGATIVE THE BRIDGE MUST NOT SOFTEN. Naming a genuinely different
    /// application still rejects the highlight as this turn's referent — the
    /// containment `selectionDefinesTurn` exists to provide.
    @Test func namingADifferentApplicationIsStillAConflict() {
        let now = Date()
        let attention = Self.selection(bundleID: taughtCodingBundleID, at: now)
        let route = withTaughtRoster {
            AmbientEngine.resolve(AmbientEngine.Inputs(
                utterance: "make this Quill note more concise",
                attention: attention,
                leadApplicationID: taughtCodingID,
                profiles: Self.profiles,
                now: now))
        }

        #expect(route.namedPlaces == [taughtWritingPlace])
        #expect(!route.selectionDefinesTurn)
    }

    /// And the prose lane's own spelling of the same fact, so the fix is
    /// pinned for both disciplines rather than only the one that found it.
    @Test func namingTheSelectionsOwnProseApplicationIsNotAConflict() {
        let now = Date()
        let attention = Self.selection(bundleID: taughtWritingBundleID, at: now)
        let route = withTaughtRoster {
            AmbientEngine.resolve(AmbientEngine.Inputs(
                utterance: "make this Quill note more concise",
                attention: attention,
                leadApplicationID: taughtWritingID,
                profiles: Self.profiles,
                now: now))
        }

        #expect(route.namedPlaces == [taughtWritingPlace])
        #expect(route.selectionDefinesTurn)
    }
}
