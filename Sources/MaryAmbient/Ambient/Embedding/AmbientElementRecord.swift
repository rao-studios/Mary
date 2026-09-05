//
//  AmbientElementRecord.swift
//  MaryAmbient
//
//  WHAT: Shape of an embeddable ambient element.
//  IN:   world rulesets at each write funnel
//  OUT:  AmbientElementIndexStore → AmbientReferenceGate
//  PIN:  No registry. A new world opts in with a conformance and noteElements.
//
import Foundation

/// What an invocation needs from its target — the pairing between the functionality being
/// invoked and the elements the gate may offer it. A move needs a frame; a rewrite needs
/// prose.
public struct AmbientElementCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Has x/y/width/height — can be moved, resized, aligned.
    public static let spatialFrame = AmbientElementCapabilities(rawValue: 1 << 0)
    /// Takes fills, borders, effects — can be restyled.
    public static let styleable = AmbientElementCapabilities(rawValue: 1 << 1)
    /// Carries quotable, rewritable text.
    public static let prose = AmbientElementCapabilities(rawValue: 1 << 2)
    /// Contains other elements — a page, artboard, or group.
    public static let container = AmbientElementCapabilities(rawValue: 1 << 3)
    /// Can be pressed right now — a button, link, or control that offers an action. THE ONE
    /// CAPABILITY THAT IS ABOUT TIME as much as about shape: a layer is styleable for as long
    /// as it exists, while a Skip Ads button is pressable for five seconds.
    public static let pressable = AmbientElementCapabilities(rawValue: 1 << 4)
    /// Takes typed text — a search box, a form field. Distinct from `prose`,
    /// which means "carries quotable text": a paragraph is prose and not
    /// fillable; an empty search field is fillable and not prose.
    public static let fillable = AmbientElementCapabilities(rawValue: 1 << 5)
    /// Has a track that can be set to a position — a volume control, a progress bar.
    /// Separate from `pressable` because a slider answers a fraction, not a press, and
    /// a lane asking for one must not be handed the other.
    public static let adjustable = AmbientElementCapabilities(rawValue: 1 << 6)
    /// NAMED BY THE WORLD, NOT OFFERED BY IT. A row something wrote a name on which the
    /// reading could not say was actionable — a result title a classifier declined to
    /// call a link, a heading that is really a control.
    ///
    /// PIN: DELIBERATELY NOT `pressable`. A lane that acts without asking (see
    /// `AffordanceProbe.confidentFloor`) must never reach one of these: candidacy is a
    /// claim about the READER's uncertainty, and answering it needs a caller that can
    /// weigh that uncertainty against everything else it knows.
    public static let candidate = AmbientElementCapabilities(rawValue: 1 << 7)
}

/// Which slice of the ambient world a record belongs to — the index is
/// partitioned by scope so a Sketch query never ranks against Pages prose.
public struct AmbientElementScope: Hashable, Sendable {
    /// WHERE the partition lives: a native world's place, or a registered application's dynamic
    /// place.
    public var place: AmbientPlace
    /// The document partition WITHIN the place: `world|documentKey` for
    /// document-partitioned worlds, the application's logical id for design
    /// canvases, the world's rawValue for fact lanes.
    public var key: String

    public init(place: AmbientPlace, key: String) {
        self.place = place
        self.key = key
    }
}

/// One embeddable element of an ambient world. `embedTexts` carries BOTH the
/// kind-derived text and the element's own name — so an Image layer and a
/// Rectangle NAMED "screenshot" are both reachable from "this screenshot".
public struct AmbientElementRecord: Sendable, Equatable {
    public var scope: AmbientElementScope
    /// Layer id / passage handle / fact id — whatever the world resolves.
    public var elementID: String
    /// The provider kind, lowercased and humanized ("image", "oval",
    /// "shape path", "paragraph", a fact slot's word).
    public var kindWord: String
    /// Layer name / document title / fact subject.
    public var name: String?
    /// The serialized claims this element makes about itself, per the
    /// world's ruleset. Each is embedded separately; the element scores by
    /// its best-matching claim.
    public var embedTexts: [String]
    public var capabilities: AmbientElementCapabilities
    /// Prompt-ready line, verbatim from the world's own summary.
    public var displaySummary: String

    public init(
        scope: AmbientElementScope,
        elementID: String,
        kindWord: String,
        name: String? = nil,
        embedTexts: [String],
        capabilities: AmbientElementCapabilities = [],
        displaySummary: String
    ) {
        self.scope = scope
        self.elementID = elementID
        self.kindWord = kindWord
        self.name = name
        self.embedTexts = embedTexts
        self.capabilities = capabilities
        self.displaySummary = displaySummary
    }
}

/// HOW A WORLD OPTS IN: one pure transform from its elements to records.
public protocol AmbientElementRuleset {
    associatedtype Element
    static func records(
        for elements: [Element], scope: AmbientElementScope
    ) -> [AmbientElementRecord]
}
