//
//  PageElementKindDerivation.swift
//  MaryComputerUse
//
//  WHAT: AX role + hints → spoken kind word. Table-free.
//  IN:   PageElementReader  OUT: SpokenReference

import CoreGraphics
import Foundation

public enum PageElementKindDerivation {

    /// Path components that mean "this destination plays something".
    static let videoPathMarkers = [
        "/watch", "/video", "/videos/", "/embed/", "/v/", "/shorts/",
        "/episode", "/player",
    ]

    /// A DURATION SIGNATURE is the web's own way of saying "this is timed media", and it is
    /// the strongest generic signal there is.
    static let durationPatterns = [
        #"\d+\s*(hour|minute|second)s?"#,
        #"·\s*\d{1,2}:\d{2}"#,
        #"\b\d{1,2}:\d{2}\b"#,
    ]

    /// A label this long is a description, not a name. MEASURED: the search page's snippet
    /// element ("4 seconds Hello my name is paul and in this video we're going to walk
    /// through…") is a link, carries the same watch URL as its card, and would otherwise
    static let proseLabelThreshold = 120

    /// A CALL TO ACTION NAMES AN ACT, NOT A THING. MEASURED: an advertisement's "Watch"
    /// button carries a genuine watch URL, so by destination alone it is a video.
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

    /// Playable = it goes somewhere that plays, or it says how long it runs — and it is a
    /// NAME rather than a paragraph.
    static func looksPlayable(url: String?, label: String) -> Bool {
        guard label.count <= proseLabelThreshold else { return false }
        guard !isCallToAction(label) else { return false }
        if let url = url?.lowercased(),
           videoPathMarkers.contains(where: url.contains) {
            return true
        }
        return hasDurationSignature(label)
    }

    static func hasDurationSignature(_ label: String) -> Bool {
        let lowered = label.lowercased()
        return durationPatterns.contains {
            lowered.range(of: $0, options: .regularExpression) != nil
        }
    }

    // MARK: - The page's offering vocabulary

    /// What this page is FOR, in the page's own terms: the kinds actually present,
    /// commonest first, with counts.
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

    /// The counting half of `offerings(in:)`, generalized to any pool of kinds — what a
    /// snapshot-lane roster needs, since it has no `[PageElement]` to map over.
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

    /// The matching half of `offeredKind(namedIn:among:)`, generalized to any set of kinds
    /// actually present in a pool — what `SpokenReference` calls for a snapshot-lane
    /// resolve, since it has no.
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
