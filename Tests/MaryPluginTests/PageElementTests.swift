//
//  PageElementTests.swift
//  BonniePluginTests
//
//  THE PAGE LANE'S SPEC. The page-resolution cases below are MEASUREMENTS
//  taken from a live YouTube results page on 2026-08-12 via
//  `--probe-page-elements`, not invented examples. Each one is a defect the
//  probe caught before the verbs shipped:
//
//    • labels arrived carrying `&#39;` and `<b>…</b>`
//    • a description snippet was classified a video and won "the third video"
//    • an advertisement's "Watch" button counted as a video, shifting every
//      ordinal on the page by one
//    • collapsing by destination alone ate half a playlist
//
//  The adjustable-control cases are the pure contract around public AX range
//  metadata: finite interpolation and a point that never leaves its element.
//

import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MaryPlugin

@Suite struct PageElementTests {

    // A stand-in AX handle. Nothing under test dereferences it; the resolver
    // and the derivation are pure functions of the value fields.
    private static let handle = AXUIElementCreateSystemWide()

    private func element(
        _ ordinal: Int,
        _ kind: PageElementKind,
        _ label: String,
        role: String = "AXLink",
        url: String? = nil,
        y: CGFloat = 0,
        help: String? = nil
    ) -> PageElement {
        PageElement(
            ordinal: ordinal,
            role: role,
            kind: kind,
            label: label,
            frame: CGRect(x: 0, y: y, width: 270, height: 53),
            url: url,
            help: help,
            axElement: Self.handle)
    }

    /// The live page, in the shape the probe printed it.
    private var youtube: [PageElement] {
        [
            element(1, .field, "Search", role: "AXComboBox"),
            element(2, .button, "Search", role: "AXButton", y: 10),
            element(3, .video, "Learn the Essentials of Swift in one hour 58 minutes",
                    url: "https://youtube.com/watch?v=a", y: 100),
            element(4, .link, "Go to channel Paul Hudson",
                    url: "https://youtube.com/@paul", y: 150),
            element(5, .video, "Swift Programming Tutorial – Full Course for Beginners 7 hours, 5 minutes",
                    url: "https://youtube.com/watch?v=b", y: 200),
            element(6, .video, "Swift in 100 Seconds 2 minutes, 25 seconds",
                    url: "https://youtube.com/watch?v=c", y: 300),
        ]
    }

    // MARK: - Labels

    @Test func markupAndEntitiesNeverReachALabel() {
        let raw = "in this video we&#39;re walking through <b>swift programming</b>&nbsp;."
        let cleaned = PageElementReader.cleaned(raw)
        #expect(!cleaned.contains("&#39;"))
        #expect(!cleaned.contains("<b>"))
        #expect(!cleaned.contains("&nbsp;"))
        #expect(cleaned.contains("we're"))
        #expect(cleaned.contains("swift programming"))
    }

    // MARK: - Kind derivation

    @Test func aDurationSignatureMakesAVideo() {
        for label in [
            "Swift in 100 Seconds 2 minutes, 25 seconds",
            "Learn the Essentials of Swift in one hour 58 minutes",
            "How to code in Swift | Swift Basics #1 · 18:25",
        ] {
            #expect(
                PageElementKindDerivation.kind(
                    role: "AXLink", subrole: nil, url: nil,
                    label: label, frame: .init(x: 0, y: 0, width: 270, height: 53))
                    == .video,
                "\(label) should read as a video")
        }
    }

    @Test func aDescriptionSnippetIsNotAVideo() {
        // MEASURED: this exact element carried the same watch URL as the card
        // it described, and outranked it for "the third video".
        let snippet = "4 seconds Hello my name is paul and in this video we're going to walk through the fundamentals of swift programming in under one hour it's ..."
        #expect(
            PageElementKindDerivation.kind(
                role: "AXLink", subrole: nil,
                url: "https://youtube.com/watch?v=a",
                label: snippet,
                frame: .init(x: 0, y: 0, width: 736, height: 19))
                == .link)
    }

    @Test func aCallToActionIsNotAVideo() {
        // MEASURED: an advertisement's "Watch" button carries a real watch
        // URL. A titled item has a name; a control has an imperative.
        #expect(
            PageElementKindDerivation.kind(
                role: "AXLink", subrole: nil,
                url: "https://youtube.com/watch?v=ad",
                label: "Watch",
                frame: .init(x: 0, y: 0, width: 94, height: 40))
                == .link)
        #expect(PageElementKindDerivation.isCallToAction("Sign up"))
        #expect(!PageElementKindDerivation.isCallToAction("Swift in 100 Seconds"))
    }

    @Test func fieldsAndButtonsKeepTheirRoles() {
        #expect(PageElementKindDerivation.kind(
            role: "AXTextField", subrole: nil, url: nil, label: "Search",
            frame: .zero) == .field)
        #expect(PageElementKindDerivation.kind(
            role: "AXButton", subrole: nil, url: nil, label: "Settings",
            frame: .zero) == .button)
    }

    @Test func slidersAreAFirstClassGenericOffering() {
        #expect(PageElementKindDerivation.kind(
            role: "AXSlider", subrole: nil, url: nil, label: "Playback position",
            frame: CGRect(x: 0, y: 0, width: 300, height: 20)) == .slider)

        let slider = element(
            1, .slider, "Playback position", role: "AXSlider")
        for phrase in ["the slider", "the range", "the timeline", "the scrubber"] {
            #expect(PageElementKindDerivation.offeredKind(
                namedIn: phrase, among: [slider]) == .slider)
        }
    }

    @Test func theOfferingVocabularyComesFromThePage() {
        let offerings = PageElementKindDerivation.offerings(in: youtube)
        #expect(offerings.first?.kind == .video)
        #expect(offerings.first?.count == 3)
        #expect(PageElementKindDerivation.offeredKind(
            namedIn: "the third video", among: youtube) == .video)
        // A search box is a field, said either way.
        #expect(PageElementKindDerivation.offeredKind(
            namedIn: "the search box", among: youtube) == .field)
        // A word the page does not offer names no kind.
        #expect(PageElementKindDerivation.offeredKind(
            namedIn: "the third invoice", among: youtube) == nil)
    }

    // MARK: - Adjustable controls

    @Test func adjustableMetadataDefaultsPreserveExistingInitializers() {
        let legacy = element(1, .button, "Play", role: "AXButton")
        #expect(legacy.numericValue == nil)
        #expect(legacy.minimumValue == nil)
        #expect(legacy.maximumValue == nil)
        #expect(legacy.orientation == nil)
        #expect(!legacy.isValueSettable)
        #expect(!legacy.offersIncrement)
        #expect(!legacy.offersDecrement)
    }

    @Test func candidateMetadataPublishesWithoutLosingRangeCapabilities() {
        let candidate = PageElementReader.Candidate(
            element: Self.handle,
            role: "AXSlider",
            subrole: nil,
            label: "Playback position",
            frame: CGRect(x: 10, y: 20, width: 300, height: 20),
            url: nil,
            isEnabled: true,
            isFocused: false,
            numericValue: 42,
            minimumValue: 0,
            maximumValue: 100,
            orientation: .horizontal,
            isValueSettable: true,
            actions: [
                kAXIncrementAction as String,
                kAXDecrementAction as String,
            ],
            help: nil)

        let published = PageElementReader.publish([candidate], limit: 1)
        #expect(published.count == 1)
        #expect(published.first?.kind == .slider)
        #expect(published.first?.numericValue == 42)
        #expect(published.first?.minimumValue == 0)
        #expect(published.first?.maximumValue == 100)
        #expect(published.first?.orientation == .horizontal)
        #expect(published.first?.isValueSettable == true)
        #expect(published.first?.offersIncrement == true)
        #expect(published.first?.offersDecrement == true)
    }

    @Test func actionGeometryCannotEscapeTheVisibleWebArea() {
        let webArea = CGRect(x: 100, y: 200, width: 600, height: 400)
        let crossingToolbar = CGRect(x: 120, y: 180, width: 200, height: 60)
        #expect(PageElementReader.actionableFrame(
            crossingToolbar, viewport: webArea, role: "AXButton")
            == CGRect(x: 120, y: 200, width: 200, height: 40))

        // A partly clipped slider cannot safely derive minimum/maximum from
        // its remaining visible segment; it must be fully revealed first.
        #expect(PageElementReader.actionableFrame(
            crossingToolbar, viewport: webArea, role: "AXSlider") == nil)
        #expect(PageElementReader.actionableFrame(
            CGRect(x: 120, y: 220, width: 200, height: 20),
            viewport: webArea,
            role: "AXSlider") == CGRect(x: 120, y: 220, width: 200, height: 20))

        #expect(PageElementReader.actionableFrame(
            CGRect(x: 120, y: 190, width: 200, height: 12),
            viewport: webArea,
            role: "AXButton") == nil)
    }

    @Test func thinSemanticSlidersRemainActionable() {
        let webArea = CGRect(x: 100, y: 200, width: 1_300, height: 700)
        let youtubeSeekTrack = CGRect(
            x: 120, y: 840, width: 1_261, height: 6)

        #expect(PageElementReader.actionableFrame(
            youtubeSeekTrack,
            viewport: webArea,
            role: "AXSlider") == youtubeSeekTrack)

        // A visually identical strip without slider semantics is not promoted
        // into a page target, and an auto-hidden zero-width range stays out.
        #expect(PageElementReader.actionableFrame(
            youtubeSeekTrack,
            viewport: webArea,
            role: "AXButton") == nil)
        #expect(PageElementReader.actionableFrame(
            CGRect(x: 120, y: 840, width: 0, height: 1),
            viewport: webArea,
            role: "AXSlider") == nil)
    }

    @Test func aBareTimelineRefusesWhenTwoLiveSlidersExist() {
        let sliders = [
            element(1, .slider, "Seek slider", role: "AXSlider"),
            element(2, .slider, "Volume", role: "AXSlider", y: 100),
        ]

        guard case .ambiguous(let rivals) = PageElementResolver.resolve(
            phrase: "the timeline", in: sliders) else {
            Issue.record("a generic timeline must not guess between two sliders")
            return
        }
        #expect(rivals.count == 2)

        guard case .one(let picked) = PageElementResolver.resolve(
            phrase: "Seek slider", in: sliders) else {
            Issue.record("the exact fresh slider label should resolve")
            return
        }
        #expect(picked.label == "Seek slider")
    }

    @Test func ordinalsCountWithinTheKindNamed() {
        // The scenario, exactly: three videos on the page, and "the third"
        // must be the third VIDEO — not the third element.
        guard case .one(let picked) = PageElementResolver.resolve(
            phrase: "go to the third video", in: youtube) else {
            Issue.record("expected one")
            return
        }
        #expect(picked.label.hasPrefix("Swift in 100 Seconds"))
    }

    @Test func theLastOneCountsFromTheEnd() {
        guard case .one(let picked) = PageElementResolver.resolve(
            phrase: "play the last video", in: youtube) else {
            Issue.record("expected one")
            return
        }
        #expect(picked.label.hasPrefix("Swift in 100 Seconds"))
    }

    @Test func anOrdinalPastTheEndRefusesRatherThanClamping() {
        #expect(PageElementResolver.resolve(
            phrase: "the ninth video", in: youtube) == .none)
    }

    @Test func spokenOrdinalsParse() {
        #expect(SpokenOrdinal.value(in: "the third video") == 3)
        #expect(SpokenOrdinal.value(in: "2nd one") == 2)
        #expect(SpokenOrdinal.value(in: "the last video") == -1)
        #expect(SpokenOrdinal.value(in: "Swift in 100 Seconds") == nil)
    }

    // MARK: - Names

    @Test func aTitleResolvesThroughTheVerbsAroundIt() {
        for phrase in [
            "watch the video Swift in 100 Seconds",
            "let's play Swift in 100 Seconds",
            "play swift in 100 seconds",
        ] {
            guard case .one(let picked) = PageElementResolver.resolve(
                phrase: phrase, in: youtube) else {
                Issue.record("\(phrase) should resolve")
                return
            }
            #expect(picked.label.hasPrefix("Swift in 100 Seconds"))
        }
    }

    @Test func aPartialNameStillFindsTheCard() {
        guard case .one(let picked) = PageElementResolver.resolve(
            phrase: "the full course for beginners", in: youtube) else {
            Issue.record("expected one")
            return
        }
        #expect(picked.label.hasPrefix("Swift Programming Tutorial"))
    }

    // MARK: - A timestamp is not a duration

    /// FOUND LIVE on a discussion page: every "7 hours ago" comment
    /// timestamp classified as a VIDEO, because the duration pattern
    /// `\d+\s*(hour|minute|second)s?` matches a relative time exactly as it
    /// matches a running time. The cost is not cosmetic — "the third video"
    /// starts counting comments, and the page's offering vocabulary tells
    /// the model a discussion is a video page.
    @Test(arguments: [
        "7 hours ago", "1 hour ago", "20 minutes ago", "3 seconds ago",
    ])
    func aRelativeTimestampIsNotADuration(label: String) {
        #expect(!PageElementKindDerivation.hasDurationSignature(label))
    }

    /// AND A REAL DURATION STILL IS ONE. The measurement that produced these
    /// patterns cites each of these from a live results page, so narrowing
    /// the rule must not cost them.
    @Test(arguments: [
        "in one hour 58 minutes", "2 minutes, 25 seconds", "Lecture · 2:21",
    ])
    func arunningTimeStillReadsAsADuration(label: String) {
        #expect(PageElementKindDerivation.hasDurationSignature(label))
    }

    // MARK: - Refusals

    /// IDENTICAL LABELS MUST NOT BE OFFERED AS THE WAY TO CHOOSE.
    ///
    /// Found live on a news page: two rows both read "7 hours ago", and the
    /// refusal came back `…matching 7 hours ago — "7 hours ago" and "7 hours
    /// ago". Which one?` — a question with no answerable form, because the
    /// user is asked to distinguish two things using the one piece of
    /// information that is identical.
    ///
    /// This test previously asserted that exact wording. It was pinning the
    /// dead end: everything it checked was true (it refused, it named the
    /// label, it did not lecture) and the sentence was still useless.
    @Test func twoThingsWithTheSameNameRefuseTowardsAWayThatWorks() {
        let twins = [
            element(1, .video, "Lesson 1", url: "https://x/1"),
            element(2, .video, "Lesson 1", url: "https://x/2", y: 100),
        ]
        guard case .ambiguous(let rivals) = PageElementResolver.resolve(
            phrase: "Lesson 1", in: twins) else {
            Issue.record("expected ambiguity")
            return
        }
        #expect(rivals.count == 2)
        let spoken = PageElementResolver.ambiguityRefusal(rivals, phrase: "Lesson 1")

        #expect(spoken.contains("2"))
        #expect(spoken.contains("Lesson 1"))
        // It says WHY the name cannot settle it, and points at the road that
        // can — the resolver accepts "the second video", and
        // `list_page_elements` numbers within kind for exactly this.
        #expect(spoken.contains("number"))
        // And it never offers the same string twice as a choice.
        #expect(spoken.components(separatedBy: "Lesson 1").count == 2)
        #expect(!spoken.lowercased().contains("be more specific"))
    }

    /// DISTINCT labels still get named, because there the names DO settle it.
    @Test func rivalsWithDifferentNamesAreNamed() {
        let rivals = [
            element(1, .link, "Sign in with email", url: "https://x/1"),
            element(2, .link, "Sign in with Apple", url: "https://x/2", y: 100),
        ]
        let spoken = PageElementResolver.ambiguityRefusal(rivals, phrase: "sign in")
        #expect(spoken.contains("Sign in with email"))
        #expect(spoken.contains("Sign in with Apple"))
        #expect(spoken.contains("Which one?"))
    }

    @Test func aNameThePageDoesNotHoldMissesHonestly() {
        #expect(PageElementResolver.resolve(
            phrase: "the quarterly earnings call", in: youtube) == .none)
        #expect(PageElementResolver.missRefusal(phrase: "x")
            .contains("what's on the page"))
    }

    @Test func aBareKindWithOneCandidateResolves() {
        guard case .one(let picked) = PageElementResolver.resolve(
            phrase: "the search box", in: youtube) else {
            Issue.record("expected the only field")
            return
        }
        #expect(picked.kind == .field)
    }

    @Test func anEmptyPageResolvesToNothing() {
        #expect(PageElementResolver.resolve(phrase: "anything", in: []) == .none)
        #expect(PageElementResolver.resolve(phrase: "", in: youtube) == .none)
    }
}
