//
//  PageElementKindDerivation.swift
//  MaryAdapter
//
//  WHAT A SITE OFFERS, DERIVED FROM THE PAGE ITSELF.
//
//  A user says "play that video" on one site and "open that issue" on
//  another, and both are the same act: pressing the thing the site is FOR.
//  Knowing which words a page answers to is what tells an in-page action
//  ("go to the third video") apart from a destination ("go to youtube") —
//  and the first must act in the tab already open while the second may take
//  a fresh one.
//
//  THE RULE THIS OBEYS, and the reason there is no site table anywhere in
//  this file: `BrowserScripting.siteWords` turns `docs.google.com` into
//  "google docs" by decomposing the host, never by a synonym row, because
//  "a phrase that misses is a perception or threshold question — never a new
//  alias". The same discipline holds one layer down. A page offers videos
//  because its links are SHAPED like videos — a watch-shaped destination, a
//  play affordance, a card-sized frame — not because anything here knows
//  what YouTube is. Point this at a site nobody anticipated and it still
//  answers.
//
//  Kind is a HINT, not an authority. It narrows an ordinal ("the third
//  video") and lends a lexical floor to the semantic gate; the element's own
//  label is always the stronger evidence, and a miss falls through to
//  matching label text rather than refusing on category.
//

import CoreGraphics
import Foundation

public enum PageElementKindDerivation {

    /// Path components that mean "this destination plays something".
    /// Deliberately generic: `/watch`, `/video/`, `/embed/`, `/v/` are the
    /// conventions the web settled on, shared by sites that have never heard
    /// of each other.
    static let videoPathMarkers = [
        "/watch", "/video", "/videos/", "/embed/", "/v/", "/shorts/",
        "/episode", "/player",
    ]

    /// A DURATION SIGNATURE is the web's own way of saying "this is timed
    /// media", and it is the strongest generic signal there is — MEASURED on
    /// a live results page, every real video card ended in one:
    /// "…in one hour 58 minutes", "…2 minutes, 25 seconds", "… · 2:21".
    /// No site name is involved; a podcast page or a news video reads the
    /// same way.
    static let durationPatterns = [
        #"\d+\s*(hour|minute|second)s?"#,
        #"·\s*\d{1,2}:\d{2}"#,
        #"\b\d{1,2}:\d{2}\b"#,
    ]

    /// A label this long is a description, not a name. MEASURED: the search
    /// page's snippet element ("4 seconds Hello my name is paul and in this
    /// video we're going to walk through…") is a link, carries the same
    /// watch URL as its card, and would otherwise outrank the card itself
    /// for "the third video". A person does not point at a paragraph.
    static let proseLabelThreshold = 120

    /// A CALL TO ACTION NAMES AN ACT, NOT A THING.
    ///
    /// MEASURED: an advertisement's "Watch" button carries a genuine watch
    /// URL, so by destination alone it is a video — and counting it shifted
    /// "the third video" by one for the whole page. The distinction that
    /// actually holds is grammatical rather than commercial: a titled item
    /// has a NAME, a control has an IMPERATIVE. Nothing here knows what an
    /// advertisement is, and it does not need to.
    static let callToActionLabels: Set<String> = [
        "watch", "watch now", "play", "play now", "listen", "listen now",
        "sign up", "sign in", "log in", "subscribe", "learn more",
        "shop now", "buy now", "download", "get started", "try it free",
        "read more", "see more", "view", "open", "next", "continue",
    ]

    static func isCallToAction(_ label: String) -> Bool {
        callToActionLabels.contains(
            label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public static func kind(
        role: String,
        subrole: String?,
        url: String?,
        label: String,
        frame: CGRect
    ) -> PageElementKind {
        switch role {
        case "AXTextField", "AXTextArea", "AXComboBox":
            return .field
        case "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXMenuBarItem":
            return .option
        case "AXSlider":
            return .slider
        case "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle", "AXTab":
            return .button
        case "AXHeading":
            return .heading
        case "AXRow", "AXCell":
            return .row
        case "AXImage":
            return .image
        case "AXButton":
            // A button whose own words are about playing is a play control —
            // the affordance a person means by "play it".
            return looksPlayable(url: url, label: label) ? .video : .button
        case "AXLink":
            return looksPlayable(url: url, label: label) ? .video : .link
        default:
            return .link
        }
    }

    /// Playable = it goes somewhere that plays, or it says how long it runs —
    /// and it is a NAME rather than a paragraph. Both halves were measured:
    /// dropping the length test made a description snippet outrank the card
    /// it belonged to.
    static func looksPlayable(url: String?, label: String) -> Bool {
        guard label.count <= proseLabelThreshold else { return false }
        guard !isCallToAction(label) else { return false }
        if let url = url?.lowercased(),
           videoPathMarkers.contains(where: url.contains) {
            return true
        }
        return hasDurationSignature(label)
    }

    /// A RELATIVE TIME IS NOT A DURATION, and the difference is one word.
    ///
    /// FOUND LIVE on a news page: `\d+\s*(hour|minute|second)s?` matches
    /// "7 hours ago" exactly as it matches "58 minutes", so every comment
    /// timestamp on the page classified as a video. The costs compound —
    /// "the third video" counts things nobody would call a video, and
    /// `offerings` tells the model the page is a video page when it is a
    /// discussion.
    ///
    /// ONLY "ago", deliberately. The forward-looking form is genuinely
    /// ambiguous and the measurement that produced these patterns cites
    /// "…in one hour 58 minutes" as a REAL video duration, so excluding "in"
    /// would break the case the rule was written for. "Ago" is unambiguous:
    /// nothing that happened in the past is a running time.
    static let relativeTimeMarkers = [" ago", " ago,", " ago."]

    static func hasDurationSignature(_ label: String) -> Bool {
        let lowered = label.lowercased()
        guard !relativeTimeMarkers.contains(where: { lowered.contains($0) }),
              !lowered.hasSuffix("ago")
        else { return false }
        return durationPatterns.contains {
            lowered.range(of: $0, options: .regularExpression) != nil
        }
    }

    // MARK: - The page's offering vocabulary

    /// What this page is FOR, in the page's own terms: the kinds actually
    /// present, commonest first, with counts. This is the "categorical
    /// offering" an utterance is matched against — derived every read, valid
    /// only for the page that produced it.
    public static func offerings(
        in elements: [PageElement]
    ) -> [(kind: PageElementKind, count: Int)] {
        offerings(of: elements.map(\.kind))
    }

    /// Does a spoken phrase name one of the kinds this page actually offers?
    /// The words come from the kind's own small admitting set — the page's
    /// individual labels are searched separately, by the semantic gate.
    public static func offeredKind(
        namedIn phrase: String, among elements: [PageElement]
    ) -> PageElementKind? {
        offeredKind(namedIn: phrase, offering: Set(elements.map(\.kind)))
    }

    // MARK: - Pool-generic entry points

    /// The counting half of `offerings(in:)`, generalized to any pool of
    /// kinds — what a snapshot-lane roster needs, since it has no
    /// `[PageElement]` to map over. The page lane's `offerings(in:)` now
    /// forwards here.
    public static func offerings(
        of kinds: [PageElementKind]
    ) -> [(kind: PageElementKind, count: Int)] {
        var counts: [PageElementKind: Int] = [:]
        for kind in kinds { counts[kind, default: 0] += 1 }
        return counts
            .map { (kind: $0.key, count: $0.value) }
            .sorted {
                $0.count == $1.count
                    ? $0.kind.rawValue < $1.kind.rawValue
                    : $0.count > $1.count
            }
    }

    /// The matching half of `offeredKind(namedIn:among:)`, generalized to
    /// any set of kinds actually present in a pool — what `SpokenReference`
    /// calls for a snapshot-lane resolve, since it has no `[PageElement]`
    /// either. The page lane's `offeredKind(namedIn:among:)` now forwards
    /// here.
    public static func offeredKind(
        namedIn phrase: String, offering present: Set<PageElementKind>
    ) -> PageElementKind? {
        let lowered = " \(phrase.lowercased()) "
        // Longest admitting word first, so "search box" beats "box".
        let matches = present
            .flatMap { kind in kind.admittingWords.map { (kind, $0) } }
            .filter { lowered.contains(" \($0.1) ") || lowered.contains(" \($0.1)s ") }
            .sorted { $0.1.count > $1.1.count }
        return matches.first?.0
    }
}
