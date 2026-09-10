//
//  PageElementReader.swift
//  MaryComputerUse
//
//  WHAT: Walk a web area into PageElements in reading order.
//  IN:   AXWebArea  OUT: PageElementResolver / PageElementKindDerivation
//  PIN:  Dedup by label+frame; reading order is vertical band then LTR.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum PageElementReader {

    // MARK: - Bounds

    /// Candidates examined before publishing. The AX walk's own ceiling
    /// (4000 nodes) still applies above this.
    public static let maximumCandidates = 512
    /// What one read publishes. Deliberately close to the browser roster's 40: an index
    /// nobody recites can be generous, but a slate that feeds spoken summaries and an
    /// embedding index must stay bounded.
    public static let maxSearchDepth = 24
    public static let maxSearchNodes = 4000
    /// The bound the page walk runs at by default.
    public static let pageBudget = AXTreeWalker.Budget(
        maxDepth: maxSearchDepth, maxNodes: maxSearchNodes)

    public static let publishedLimit = 60
    /// Elements smaller than this in either dimension are chrome artifacts,
    /// not things a person points at.
    static let minimumInteractiveSide: CGFloat = 8
    /// Vertical tolerance for "same row" when assigning reading order.
    static let readingBandHeight: CGFloat = 24
    /// A label longer than this is a paragraph that happens to be focusable;
    /// it is truncated for display and matching.
    static let maximumLabelCharacters = 160

    /// The roles worth collecting. Everything else on a page is structure.
    public static let collectedRoles: Set<String> = [
        "AXLink", "AXButton", "AXTextField", "AXTextArea", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXImage",
        "AXHeading", "AXDisclosureTriangle", "AXRow", "AXCell",
        "AXComboBox", "AXSlider", "AXTab", "AXMenuItem",
    ]

    // MARK: - The read

    /// Enumerate the page's interactive elements, in reading order.

    /// THE PAGE ITSELF, through Accessibility — every `AXWebArea` under the
    /// front window, walked into `PageElement`s in reading order.
    ///
    /// PIN: THE LANE THE PIXEL READ CANNOT REPLACE, and the reverse is also
    /// true, which is why both exist. Accessibility knows a row's ROLE — this
    /// is a link, that is a field — and its live handle, so "the first link"
    /// is a question with an answer and pressing it is `AXPress` rather than a
    /// click at a guessed midpoint. It does not know what a `<canvas>` player
    /// looks like, which is what the pixels are for. `PagePerceptionPipeline`
    /// merges them.
    ///
    /// REQUIRES THE WAKE. On a Chromium host this returns nothing at all until
    /// `BrowserAXReadiness.ensureWebContentAX` has run — and nothing is
    /// indistinguishable from an empty page, which is exactly the failure the
    /// wake exists to end. Callers ask readiness first.
    ///
    /// CLIPPED TO THE PAGE FRAME, not the window: the toolbar's own controls
    /// are the shell's business and are read through `WebSurfaceAX`. A page
    /// element whose frame sits outside the rendered content is off-screen or
    /// furniture, and `actionableFrame` already refuses it.
    public static func readWebContent(
        in application: AXUIElement,
        pageFrame: CGRect? = nil,
        limit: Int = publishedLimit,
        budget: AXTreeWalker.Budget = pageBudget,
        candidateCeiling: Int = maximumCandidates
    ) -> [PageElement] {
        guard let window = AX.element(application, kAXFocusedWindowAttribute)
                ?? AX.element(application, kAXMainWindowAttribute)
        else { return [] }
        let viewport = pageFrame ?? AX.frame(of: window)
        let areas = WebAreaLocator.webAreas(
            inWindow: window,
            budget: .init(maxDepth: maxSearchDepth, maxNodes: maxSearchNodes))
        guard !areas.isEmpty else { return [] }

        var candidates: [Candidate] = []
        for area in areas {
            AXTreeWalker.walk(from: area, budget: budget) { element, _ in
                guard candidates.count < candidateCeiling else { return }
                guard let candidate = candidate(from: element, viewport: viewport)
                else { return }
                candidates.append(candidate)
            }
        }
        return publish(deduplicated(candidates), limit: limit)
    }

    /// The same enumeration, rooted at an application's own WINDOW instead of a web area.
    public static func readWindowControls(
        in application: AXUIElement,
        limit: Int = publishedLimit
    ) -> [PageElement] {
        guard let window = AX.element(
                application, kAXFocusedWindowAttribute)
                ?? AX.element(
                    application, kAXMainWindowAttribute)
        else { return [] }
        let viewport = AX.frame(of: window)

        var candidates: [Candidate] = []
        AXTreeWalker.walk(
            from: window,
            budget: .init(maxDepth: maxSearchDepth, maxNodes: maxSearchNodes)
        ) { element, _ in
            guard candidates.count < maximumCandidates else { return }
            guard let candidate = candidate(from: element, viewport: viewport)
            else { return }
            candidates.append(candidate)
        }
        return publish(deduplicated(candidates), limit: limit)
    }

    /// Cheap proof that an act did something, for applications that have no page title to
    /// diff.
    public static func windowSignature(in application: AXUIElement) -> String? {
        guard let window = AX.element(
                application, kAXFocusedWindowAttribute)
                ?? AX.element(
                    application, kAXMainWindowAttribute)
        else { return nil }
        return AX.string(window, kAXTitleAttribute)
    }

    // MARK: - Candidates

    struct Candidate {
        var element: AXUIElement
        var role: String
        var subrole: String?
        var label: String
        var frame: CGRect
        var url: String?
        var isEnabled: Bool
        var isFocused: Bool
        var numericValue: Double? = nil
        var minimumValue: Double? = nil
        var maximumValue: Double? = nil
        var orientation: PageElementOrientation? = nil
        var isValueSettable: Bool = false
        var actions: [String]
        var help: String?

        /// The identity two presentations of one target share. Query and
        /// fragment are dropped for the same reason `BrowserScripting
        /// .identity` drops them: they churn while the destination does not.
        var destination: String? {
            guard let url, !url.isEmpty else { return nil }
            var value = url.lowercased()
            if let cut = value.firstIndex(where: { $0 == "#" }) {
                value = String(value[value.startIndex..<cut])
            }
            return value.isEmpty ? nil : value
        }
    }

    static func candidate(
        from element: AXUIElement, viewport: CGRect?
    ) -> Candidate? {
        guard let role = AX.string(element, kAXRoleAttribute),
              collectedRoles.contains(role) else { return nil }
        guard let measuredFrame = AX.frame(of: element),
              hasActionableSize(measuredFrame, role: role) else { return nil }
        // Off-viewport elements are real but unpointable — an infinite-scroll
        // feed holds hundreds of them below the fold. A person cannot mean
        // "the third video" about something they cannot see.
        guard let frame = actionableFrame(
            measuredFrame, viewport: viewport, role: role) else { return nil }
        guard let label = label(of: element, role: role) else { return nil }
        return Candidate(
            element: element,
            role: role,
            subrole: AX.string(element, kAXSubroleAttribute),
            label: label,
            frame: frame,
            url: url(of: element),
            isEnabled: boolean(element, kAXEnabledAttribute) ?? true,
            isFocused: boolean(element, kAXFocusedAttribute) ?? false,
            numericValue: numeric(element, kAXValueAttribute),
            minimumValue: numeric(element, kAXMinValueAttribute),
            maximumValue: numeric(element, kAXMaxValueAttribute),
            orientation: orientation(of: element),
            isValueSettable: isSettable(element, kAXValueAttribute),
            actions: actionNames(of: element),
            help: AX.string(element, kAXHelpAttribute)
                .flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The geometry an ordinary page gesture may use. Buttons and text fields are clipped
    /// to the portion actually inside rendered web content, so a midpoint can never escape
    /// into browser chrome.
    static func actionableFrame(
        _ measured: CGRect,
        viewport: CGRect?,
        role: String
    ) -> CGRect? {
        guard measured.origin.x.isFinite,
              measured.origin.y.isFinite,
              measured.width.isFinite,
              measured.height.isFinite,
              hasActionableSize(measured, role: role) else { return nil }
        guard let viewport else { return measured }
        guard viewport.origin.x.isFinite,
              viewport.origin.y.isFinite,
              viewport.width.isFinite,
              viewport.height.isFinite,
              viewport.intersects(measured) else { return nil }
        if role == "AXSlider", !viewport.contains(measured) { return nil }
        let visible = measured.intersection(viewport)
        guard !visible.isNull,
              hasActionableSize(visible, role: role) else { return nil }
        return visible
    }

    /// Ordinary page controls need a human-sized two-dimensional hit target.
    static func hasActionableSize(
        _ frame: CGRect,
        role: String
    ) -> Bool {
        guard frame.width.isFinite,
              frame.height.isFinite,
              frame.width >= 0,
              frame.height >= 0 else { return false }
        if role == "AXSlider" {
            return max(frame.width, frame.height) >= minimumInteractiveSide
                && min(frame.width, frame.height) > 2
        }
        return frame.width >= minimumInteractiveSide
            && frame.height >= minimumInteractiveSide
    }

    /// THE LABEL LADDER. A page names its controls in four different places
    /// depending on how it was built; taking only `AXTitle` is why a naive
    /// walk finds a page full of nameless buttons.
    static func label(of element: AXUIElement, role: String) -> String? {
        let direct = [
            AX.string(element, kAXTitleAttribute),
            AX.string(element, kAXDescriptionAttribute),
            // A text field's VALUE is its content, not its name — for a field
            // the placeholder is the better name, and the value is what the
            // user already typed.
            role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox"
                ? AX.string(element, kAXPlaceholderValueAttribute)
                : AX.string(element, kAXValueAttribute),
        ].compactMap { $0 }.map(cleaned).first { !$0.isEmpty }
        if let direct { return capped(direct) }
        // A card whose own node is nameless usually wraps its title in static
        // text — the shape a link-with-a-heading takes on most feeds.
        if let inherited = nearestStaticText(in: element) { return capped(inherited) }
        if let roleDescription = AX.string(element, kAXRoleDescriptionAttribute)
            .map(cleaned), !roleDescription.isEmpty {
            // A role description alone ("button") names a category, not a
            // thing. It is a label only for elements that are inherently
            // singular on a page.
            return role == "AXTextField" || role == "AXTextArea"
                ? capped(roleDescription) : nil
        }
        return nil
    }

    /// Bounded descent for a descendant's text. Deliberately shallow: a deep
    /// search would pull a whole article's prose into a link's name.
    static func nearestStaticText(
        in element: AXUIElement, depth: Int = 3
    ) -> String? {
        guard depth > 0 else { return nil }
        for child in AX.children(element).prefix(12) {
            let role = AX.string(child, kAXRoleAttribute)
            if role == "AXStaticText" || role == "AXHeading" {
                let text = [
                    AX.string(child, kAXValueAttribute),
                    AX.string(child, kAXTitleAttribute),
                ].compactMap { $0 }.map(cleaned).first { !$0.isEmpty }
                if let text { return text }
            }
            if let nested = nearestStaticText(in: child, depth: depth - 1) {
                return nested
            }
        }
        return nil
    }

    static func url(of element: AXUIElement) -> String? {
        guard let ref = AX.attribute(element, kAXURLAttribute) else { return nil }
        if let url = ref as? URL { return url.absoluteString }
        if let text = ref as? String { return text }
        return nil
    }

    static func actionNames(of element: AXUIElement) -> [String] {
        var namesRef: CFArray?
        guard AXUIElementCopyActionNames(element, &namesRef) == .success,
              let names = namesRef as? [String] else { return [] }
        return names
    }

    static func boolean(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (AX.attribute(element, attribute) as? NSNumber)?.boolValue
    }

    /// AX numeric attributes bridge as `NSNumber`. A Boolean bridges through
    /// the same Foundation type, so reject it explicitly: checked/unchecked is
    /// not a position in an adjustable range.
    static func numeric(_ element: AXUIElement, _ attribute: String) -> Double? {
        guard let ref = AX.attribute(element, attribute),
              CFGetTypeID(ref) != CFBooleanGetTypeID(),
              let number = ref as? NSNumber
        else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    static func isSettable(
        _ element: AXUIElement, _ attribute: String
    ) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(
            element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    static func orientation(
        of element: AXUIElement
    ) -> PageElementOrientation? {
        switch AX.string(element, kAXOrientationAttribute) {
        case kAXHorizontalOrientationValue:
            return .horizontal
        case kAXVerticalOrientationValue:
            return .vertical
        default:
            return nil
        }
    }

    /// MEASURED on a live YouTube results page: labels arrive carrying raw markup and
    /// entities — `we&#39;re`, `<b>swift programming</b>`, `&nbsp;`.
    static func cleaned(_ value: String) -> String {
        var text = value
            .replacingOccurrences(
                of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, replacement) in htmlEntities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric entities, decimal and hex.
        text = text.replacingOccurrences(
            of: "&#x?[0-9A-Fa-f]+;",
            with: "",
            options: .regularExpression)
        return text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(
                of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The entities a page actually puts in an accessible name. Decoded
    /// before the numeric sweep so an apostrophe survives as an apostrophe.
    static let htmlEntities: [(String, String)] = [
        ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"),
        ("&quot;", "\""), ("&#34;", "\""),
        ("&nbsp;", " "), ("&#160;", " "),
        ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
        ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
    ]

    static func capped(_ value: String) -> String {
        value.count <= maximumLabelCharacters
            ? value
            : String(value.prefix(maximumLabelCharacters)) + "…"
    }

    // MARK: - Dedup and ordering

    /// ONE THING, ONE ENTRY. MEASURED on a live results page: a single video card surfaced
    /// as THREE elements.
    static func deduplicated(_ candidates: [Candidate]) -> [Candidate] {
        var kept: [Candidate] = []
        for candidate in candidates {
            let duplicate = kept.firstIndex { existing in
                guard existing.frame.intersects(candidate.frame),
                      overlapRatio(existing.frame, candidate.frame) > 0.6
                else { return false }
                // ONE RECTANGLE HOLDS ONE VISIBLE THING. MEASURED on a search
                // page: "Accessibility help" and "Skip to main content" are
                // published at the identical frame at the page's left edge —
                // both real, both keyboard-reachable, and at most one of them
                // drawn. They went on to be the first two rows any ordinal
                // counted, so "the second result" reached a skip link. Different
                // destinations, so the test below keeps both; an exact frame
                // match is the geometry that says they cannot both be there.
                if existing.frame == candidate.frame { return true }
                if let lhs = existing.destination, let rhs = candidate.destination {
                    return lhs == rhs
                }
                return existing.label.caseInsensitiveCompare(candidate.label) == .orderedSame
            }
            guard let duplicate else {
                kept.append(candidate)
                continue
            }
            let existing = kept[duplicate]
            if rank(candidate) > rank(existing) { kept[duplicate] = candidate }
        }
        return kept
    }

    /// Which of several presentations of one destination a person would point at.
    static func rank(_ candidate: Candidate) -> Int {
        var score = 0
        if candidate.actions.contains("AXPress") { score += 4 }
        // MEASURED: a real card carries AXHelp equal to its own full title,
        // while its snippet and badges carry none.
        if candidate.help != nil { score += 3 }
        if candidate.label.count <= PageElementKindDerivation.proseLabelThreshold {
            score += 3
        }
        if candidate.role == "AXLink" || candidate.role == "AXButton" { score += 1 }
        return score
    }

    static func overlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let smaller = min(lhs.width * lhs.height, rhs.width * rhs.height)
        guard smaller > 0 else { return 0 }
        return (intersection.width * intersection.height) / smaller
    }

    /// READING ORDER: band by vertical position, then left-to-right inside the
    /// band. This is what "the third video" counts.
    static func publish(_ candidates: [Candidate], limit: Int) -> [PageElement] {
        let ordered = candidates.sorted { lhs, rhs in
            let lhsBand = (lhs.frame.midY / readingBandHeight).rounded(.down)
            let rhsBand = (rhs.frame.midY / readingBandHeight).rounded(.down)
            if lhsBand != rhsBand { return lhsBand < rhsBand }
            if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
            return lhs.label < rhs.label
        }
        return ordered.prefix(limit).enumerated().map { index, candidate in
            PageElement(
                ordinal: index + 1,
                role: candidate.role,
                subrole: candidate.subrole,
                kind: PageElementKindDerivation.kind(
                    role: candidate.role,
                    subrole: candidate.subrole,
                    url: candidate.url,
                    label: candidate.label,
                    frame: candidate.frame),
                label: candidate.label,
                frame: candidate.frame,
                url: candidate.url,
                isEnabled: candidate.isEnabled,
                isFocused: candidate.isFocused,
                numericValue: candidate.numericValue,
                minimumValue: candidate.minimumValue,
                maximumValue: candidate.maximumValue,
                orientation: candidate.orientation,
                isValueSettable: candidate.isValueSettable,
                availableActions: candidate.actions,
                help: candidate.help,
                axElement: candidate.element)
        }
    }
}
