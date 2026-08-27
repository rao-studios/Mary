import Foundation
@testable import MaryAmbient

/// The design-domain fixture lexicon: a verbatim reproduction of the tables
/// the engine carried before they became package declarations (the old
/// `AmbientKindLexicon.synonyms`, `DesignCanvasRule` capability map and
/// spoken forms, `DesignEditCue` cue tables, and the spatial verb table).
/// Every behavior pin that ran against the compiled-in tables runs against
/// THIS — which makes the fixture double as the parity proof that a declared
/// domain reproduces the old behavior exactly.
enum TestLexicons {
    static let designLike = ArtifactDomainLexicon(
        synonyms: [
            "oval": ["oval"], "circle": ["oval"], "ellipse": ["oval"],
            "rectangle": ["rectangle"], "rect": ["rectangle"],
            "square": ["rectangle"], "box": ["rectangle"],
            "star": ["star"], "polygon": ["polygon"],
            "line": ["line"], "arrow": ["line"],
            "path": ["shapepath"],
            "shape": ["shapepath", "oval", "rectangle", "star", "polygon"],
            "text": ["text"], "label": ["text"], "heading": ["text"],
            "title": ["text"], "caption": ["text"], "paragraph": ["text"],
            "group": ["group"],
            "frame": ["artboard", "group"], "artboard": ["artboard"],
            "board": ["artboard"], "page": ["page"],
            "image": ["image"], "bitmap": ["image"],
            "symbol": ["symbolinstance", "symbolmaster"],
            "component": ["symbolinstance", "symbolmaster"],
            "instance": ["symbolinstance"],
            "slice": ["slice"], "hotspot": ["hotspot"],
        ],
        kindCapabilities: [
            "oval": [.spatialFrame, .styleable],
            "rectangle": [.spatialFrame, .styleable],
            "star": [.spatialFrame, .styleable],
            "polygon": [.spatialFrame, .styleable],
            "line": [.spatialFrame, .styleable],
            "image": [.spatialFrame, .styleable],
            "text": [.spatialFrame, .styleable, .prose],
            "group": [.spatialFrame, .styleable, .container],
            "artboard": [.spatialFrame, .styleable, .container],
            "page": [.spatialFrame, .styleable, .container],
            "shapepath": [.spatialFrame, .styleable],
            "symbolinstance": [.spatialFrame, .styleable],
            "symbolmaster": [.spatialFrame, .styleable],
            "hotspot": [.spatialFrame, .styleable],
            "slice": [.spatialFrame, .styleable],
        ],
        spokenForms: [
            "shapepath": "shape path",
            "symbolinstance": "symbol instance",
            "symbolmaster": "symbol master",
            "hotspot": "hot spot",
        ],
        reviseVerbs: [
            "make", "turn", "paint", "color", "colour", "fill", "recolor",
            "restyle", "style", "darken", "lighten",
            "move", "nudge", "shift", "drag", "place", "position",
            "resize", "scale", "shrink", "grow", "enlarge", "widen", "stretch",
            "rotate", "spin", "flip",
            "rename", "change", "set", "update", "adjust",
            "bring", "send", "raise", "lower",
            "delete", "remove", "drop", "hide",
            "soften", "sharpen", "blur", "fade", "brighten", "dim",
            "round", "thicken", "increase", "decrease", "reduce", "boost", "tint",
        ],
        createVerbs: [
            "draw", "create", "add", "insert", "make", "put", "duplicate", "copy",
        ],
        createMarkers: [
            "another", "one more", "a second", "a new", "a copy", "copy of",
            "duplicate", "a fresh",
        ],
        effectNouns: [
            "blur", "shadow", "glow", "gradient", "border", "stroke", "outline",
            "fill", "opacity", "radius", "corner", "corners", "rounding",
            "tint", "shade", "effect", "effects", "blend", "blending",
            "font", "typeface", "weight", "spacing", "alignment",
            "transparency", "translucency", "roundness", "thickness",
        ],
        effectVerbs: ["add", "apply", "give", "put"],
        deicticHeads: ["shape", "layer", "object", "item"],
        verbRequirements: [
            .init(
                verbs: [
                    "move", "nudge", "shift", "drag", "place", "position",
                    "resize", "scale", "shrink", "grow", "enlarge", "widen",
                    "stretch", "rotate", "spin", "flip", "align",
                ],
                requires: [.spatialFrame]),
        ])

    /// Installs the fixture for the applications a test speaks for, and
    /// returns a token whose deinit is irrelevant — tests reinstall wholesale
    /// per case, mirroring how the app layer swaps frozen maps.
    static func install(applications: [String] = ["sketch"]) {
        AmbientArtifactLexiconProvider.install(
            Dictionary(uniqueKeysWithValues: applications.map { ($0, designLike) }))
    }

    static func uninstall() {
        AmbientArtifactLexiconProvider.install([:])
    }
}
