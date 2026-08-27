//
//  PluginRecipeStep.swift
//  MaryFoundation
//
//  ONE STEP OF REMOTE HANDS. The step kinds are finite and each one carries
//  only typed expressions, so a recipe is a bounded sequence of local acts
//  rather than an interpreter for package-authored instructions.
//

import Foundation

public enum PluginRecipeStepKind: String, Codable, Hashable, Sendable, CaseIterable {
    case keyChord
    case typeText
    case pointerMove
    case pointerClick
    case pointerDrag
    /// Drag a square in screen points. The recipe must use the same scalar
    /// expression for width and height; Mary resolves that one normalized
    /// side against the shorter content-bounds axis so a non-square window
    /// cannot stretch the result into a rectangle.
    case pointerSquareDrag
    case scroll
    /// Accept the target application's newly focused window after a declared
    /// action such as New Document. The process identity never changes.
    case rebindFocusedWindow
    /// Capture one exact public-Accessibility element's live screen frame as
    /// a later coordinate space. This read-only instruction emits no input.
    case captureAccessibilityAnchor
    case wait
}

/// One instruction in Mary's closed macUI recipe grammar. Fields not owned
/// by `kind` must be nil and are rejected by validation.
public struct PluginRecipeStepSchema: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: PluginRecipeStepKind
    public var key: PluginKey?
    public var modifiers: [PluginKeyModifier]
    public var text: PluginTextExpression?
    public var point: PluginPointExpression?
    public var rect: PluginRectExpression?
    public var deltaX: PluginScalarExpression?
    public var deltaY: PluginScalarExpression?
    /// Exact public-Accessibility container and optional unique descendant for
    /// a read-only frame capture. Only `captureAccessibilityAnchor` may carry
    /// this field.
    public var accessibilityLocator: PluginAccessibilityAnchorLocatorSchema?
    /// Coordinates resolve against `content` by default or a rectangle
    /// captured by an earlier drag in the same foreground transaction.
    public var coordinateSpace: String?
    /// Save this drag's resolved screen rectangle as a later coordinate space.
    public var captureAnchor: String?
    /// When present, fit the drag rectangle to this width/height ratio.
    public var aspectRatio: Double?
    public var button: PluginPointerButton?
    public var clickCount: Int?
    public var durationSeconds: Double?
    /// For a declared focused-window rebind, require a genuinely different
    /// public-AX window identity rather than accepting the previous document.
    public var requiresWindowChange: Bool?

    public init(
        id: String,
        kind: PluginRecipeStepKind,
        key: PluginKey? = nil,
        modifiers: [PluginKeyModifier] = [],
        text: PluginTextExpression? = nil,
        point: PluginPointExpression? = nil,
        rect: PluginRectExpression? = nil,
        deltaX: PluginScalarExpression? = nil,
        deltaY: PluginScalarExpression? = nil,
        accessibilityLocator: PluginAccessibilityAnchorLocatorSchema? = nil,
        coordinateSpace: String? = nil,
        captureAnchor: String? = nil,
        aspectRatio: Double? = nil,
        button: PluginPointerButton? = nil,
        clickCount: Int? = nil,
        durationSeconds: Double? = nil,
        requiresWindowChange: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.key = key
        self.modifiers = modifiers
        self.text = text
        self.point = point
        self.rect = rect
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.accessibilityLocator = accessibilityLocator
        self.coordinateSpace = coordinateSpace
        self.captureAnchor = captureAnchor
        self.aspectRatio = aspectRatio
        self.button = button
        self.clickCount = clickCount
        self.durationSeconds = durationSeconds
        self.requiresWindowChange = requiresWindowChange
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case kind
        case key
        case modifiers
        case text
        case point
        case rect
        case deltaX
        case deltaY
        case accessibilityLocator
        case coordinateSpace
        case captureAnchor
        case aspectRatio
        case button
        case clickCount
        case durationSeconds
        case requiresWindowChange
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        kind = try values.decode(PluginRecipeStepKind.self, forKey: .kind)
        key = try values.decodeIfPresent(PluginKey.self, forKey: .key)
        modifiers = try values.decode([PluginKeyModifier].self, forKey: .modifiers)
        text = try values.decodeIfPresent(PluginTextExpression.self, forKey: .text)
        point = try values.decodeIfPresent(PluginPointExpression.self, forKey: .point)
        rect = try values.decodeIfPresent(PluginRectExpression.self, forKey: .rect)
        deltaX = try values.decodeIfPresent(PluginScalarExpression.self, forKey: .deltaX)
        deltaY = try values.decodeIfPresent(PluginScalarExpression.self, forKey: .deltaY)
        accessibilityLocator = try values.decodeIfPresent(
            PluginAccessibilityAnchorLocatorSchema.self,
            forKey: .accessibilityLocator)
        coordinateSpace = try values.decodeIfPresent(String.self, forKey: .coordinateSpace)
        captureAnchor = try values.decodeIfPresent(String.self, forKey: .captureAnchor)
        aspectRatio = try values.decodeIfPresent(Double.self, forKey: .aspectRatio)
        button = try values.decodeIfPresent(PluginPointerButton.self, forKey: .button)
        clickCount = try values.decodeIfPresent(Int.self, forKey: .clickCount)
        durationSeconds = try values.decodeIfPresent(
            Double.self, forKey: .durationSeconds)
        requiresWindowChange = try values.decodeIfPresent(
            Bool.self, forKey: .requiresWindowChange)
    }
}

public enum PluginRecipePostcondition: String, Codable, Hashable, Sendable, CaseIterable {
    case applicationFrontmost
    case applicationWindowAvailable
}
