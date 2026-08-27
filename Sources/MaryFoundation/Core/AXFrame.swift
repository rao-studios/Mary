//
//  AXFrame.swift
//  MaryFoundation
//
//  PRECISE, SELF-DESCRIBING SCREEN GEOMETRY — the vocabulary the ambient
//  layer and the AX engine agree on for WHERE something is, the same reason
//  `AmbientVoiceDelivery.swift` lives here: MaryAmbient depends on
//  MaryFoundation and the system frameworks and nothing else, and
//  MaryAdapter/AXEngine is on the other side of that seam, so a type both
//  must reference belongs to the one package both already import.
//
//  NOT `AXFramePacer`. That type (`MaryAdapter/AXEngine/AXFramePacer.swift`)
//  is about frame RATE — the tracking pump's cadence. This is about frame
//  GEOMETRY. The names sit near each other in conversation; they are
//  unrelated.
//
//  THE COORDINATE SPACE IS NAMED, NOT ASSUMED. `axGlobalTopLeft` is AX's own
//  reporting convention — origin at the primary screen's top-left, y
//  increasing downward — which is ALSO CoreGraphics' own display-space
//  convention (`CGDisplayBounds`), so a producer needs no sign flip to fill
//  one of these. `AXDesktopPlane` in the engine documents the ONE flip this
//  codebase needs at all, and it is Cocoa's bottom-left `NSScreen.frame`
//  going the other way — never AX to CG.
//
//  A FRAME IS EVIDENCE, NEVER AN IDENTITY. Three places in this codebase
//  independently reached the same conclusion and said so: "a frame is a
//  coordinate, and a window that re-laid out has moved its controls"
//  (`AffordanceRecipes.swift`, `PageInteractionRecipes.swift`), and
//  "[frames] can collide between distinct windows"
//  (`RemoteHandsElementRegistry.swift`). `capturedAt` is what keeps this
//  type honest about that: a frame is what was true at a moment, offered
//  for aiming and reasoning, and every actuation path re-reads and
//  re-locates its target by identity before touching anything. Nothing in
//  this type changes that discipline.
//
//  PLAIN SYNTHESIZED CODABLE, DELIBERATELY NOT `rejectUnknownKeys`. That
//  strict decoder (`Core/StrictDecoding.swift`) exists to protect a `.mary`
//  package's integrity digest — ignored bytes would go missing from a
//  verified hash. A frame is never authored; it is observed, this session,
//  by this build. `DesignSceneRect` (`Design/Scene/DesignSceneNode.swift`)
//  is the same call for the same reason and is the shape this type mirrors.
//
//  NO GEOMETRY MATH LIVES HERE. Every `CGRect` this type is built from, and
//  every conversion back, is `MaryAdapter/AXEngine/AXFrameProjection.swift`
//  — MaryFoundation carries no CoreGraphics import anywhere, by the
//  target's own "pure data" doctrine (see README.md), and a geometry type
//  that could compute its own centre or containment would need one.
//

import Foundation

/// The coordinate space a frame's numbers are in. One case today —
/// AX's own global, top-left-origin space — spelled out rather than
/// assumed, so a future producer in a different space cannot be silently
/// misread as this one.
public enum AXFrameSpace: String, Codable, Hashable, Sendable {
    case axGlobalTopLeft
}

/// A plain rectangle, in whatever `AXFrameSpace` the carrying `AXFrame`
/// names. Not `CGRect`: MaryFoundation has no CoreGraphics import, and
/// four `Double`s is the house shape for declared geometry
/// (`DesignSceneRect`, `PluginDesignDocumentBoundsSchema`).
public struct AXFrameRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A plain point, same space as its carrying frame.
public struct AXFramePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Which physical display a frame sits on, and that display's own bounds —
/// so a consumer can answer "which screen" without a live `NSScreen` call.
public struct AXFrameScreen: Codable, Hashable, Sendable {
    /// Position in the producer's display roster. Not a stable hardware id —
    /// displays can be added/removed/reordered between captures.
    public var index: Int
    public var rect: AXFrameRect

    public init(index: Int, rect: AXFrameRect) {
        self.index = index
        self.rect = rect
    }
}

/// Precise, self-describing screen geometry for one thing the AX engine
/// walked. See this file's header for the doctrine: named space, evidence
/// not identity, capture-stamped.
public struct AXFrame: Codable, Hashable, Sendable {
    public var space: AXFrameSpace
    /// The reported rectangle, already clipped to its window when the
    /// producer clips (the snapshot lane's own convention) — `isClipped`
    /// says whether that happened.
    public var rect: AXFrameRect
    /// The click target, computed once by the projector so no consumer
    /// re-derives `rect.midX, rect.midY` differently.
    public var center: AXFramePoint
    /// This frame's rect, re-expressed relative to its own window's
    /// origin. Nil when the producer had no window rect to offset against
    /// (a window-level frame has none to be relative to).
    public var inWindow: AXFrameRect?
    /// Nil when the producer had no display roster to consult — never a
    /// claim that the element is off-screen.
    public var screen: AXFrameScreen?
    /// This rect was clipped to its window (a control partly scrolled out
    /// of view, or one that extends past a window edge). The clip already
    /// happened before this frame was built; this is a record that it did.
    public var isClipped: Bool
    /// What keeps this a moment's evidence rather than a durable target —
    /// see the header.
    public var capturedAt: Date

    public init(
        space: AXFrameSpace,
        rect: AXFrameRect,
        center: AXFramePoint,
        inWindow: AXFrameRect? = nil,
        screen: AXFrameScreen? = nil,
        isClipped: Bool = false,
        capturedAt: Date
    ) {
        self.space = space
        self.rect = rect
        self.center = center
        self.inWindow = inWindow
        self.screen = screen
        self.isClipped = isClipped
        self.capturedAt = capturedAt
    }
}
