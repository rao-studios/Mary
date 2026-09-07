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

    /// Public because the browsing lane admits results with it: a page's "Watch" button
    /// carries a real destination and is not a result, and that judgement must be made
    /// the same way in both places.
    public static func isCallToAction(_ label: String) -> Bool {
        callToActionLabels.contains(
            label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// THE KIND OF A ROW A PAGE READ PRODUCED — from what the map actually
    /// knows, which is its affordance, its words and what the page said around it.
    ///
    /// PIN: NO ROLE IS AN ANSWER, NOT A GAP TO FILL. The seal used to invent one
    /// (`AXLink` when a row looked pressable, `AXStaticText` otherwise) purely so
    /// an AX-shaped type could be filled, and then this function derived the kind
    /// back OUT of the invention — so every unclassified pressable row became a
    /// `link` by way of a role nobody had ever named. When a classifier really
    /// did name a role, that answer is still the best one there is, and the role
    /// arm below is used unchanged.
    /// A DURATION BADGE IS A HINT, NOT A LABEL. "12:04" beside a title is what
    /// the page says about the row; it is the strongest evidence of a video there
    /// is, and it never appears in the label at all.
    public static func kind(
        role: String?,
        affordance: SeenAffordance,
        label: String,
        hints: [String] = []
    ) -> PageElementKind? {
        if let role, role != "VXRegion" {
            // A STATIC TEXT IS PROSE, WHATEVER THE PIXELS PRESSED. The tree
            // emits a link and the text inside it as two rows; the pixel lane
            // finds the text pressable, and "the third link" reached a
            // "Searches related to…" heading that went nowhere (round 15).
            // The link that carries the text is its own row, with its own role.
            if role == "AXStaticText" { return nil }
            return kind(role: role, subrole: nil, url: nil, label: label, frame: .zero)
        }
        if hints.contains(where: hasDurationSignature) { return .video }
        switch affordance {
        case .fill: return .field
        case .adjust: return .slider
        case .press: return looksPlayable(url: nil, label: label) ? .video : .link
        // NIL IS A REAL ANSWER: a row of prose is reachable and has no kind, and
        // saying `.link` about it is how a listing came to offer paragraphs.
        case .scroll, .none: return nil
        }
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

    /// DOES THIS PHRASE SAY NOTHING BUT WHICH ONE?
    ///
    /// "The second one", "the first video", "the last result" name a position
    /// within a category and nothing else. Strip the position words, the
    /// category words and the determiners around them and there is nothing left
    /// — which is exactly the case where a follow-up can only mean "of the
    /// things we were just looking at". A phrase with anything left over is a
    /// NAME ("the Boiler Room link"), and a name is looked for across the whole
    /// page rather than inside one list.
    ///
    /// PIN: SHAPE, NOT VOCABULARY, like every other rule of this kind here: it
    /// asks whether words remain, never what the sentence is about.
    public static func namesOnlyAPosition(_ phrase: String) -> Bool {
        guard SpokenOrdinal.value(in: phrase) != nil else { return false }
        var value = " " + phrase.lowercased() + " "
        let noise = PageElementKind.allCases.flatMap { kind in
            kind.admittingWords.flatMap { [$0, $0 + "s"] }
        } + SpokenOrdinal.allWords + [
            "the", "that", "this", "a", "an", "one", "ones", "please", "just",
            "open", "click", "press", "tap", "play", "watch", "go", "to", "on",
            "show", "me", "pick", "select", "of", "them", "it",
        ]
        for word in noise.sorted(by: { $0.count > $1.count }) {
            value = value.replacingOccurrences(
                of: " \(word) ", with: "  ", options: [])
            value = value.replacingOccurrences(
                of: " \(word) ", with: "  ", options: [])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
