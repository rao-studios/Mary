//
//  PluginInputVocabulary.swift
//  MaryFoundation
//
//  WHAT: Closed keys, modifiers, buttons, AX roles, conjunctive anchor locator.
//  IN:   PluginRecipeStep.
//  OUT:  PluginValidator+Steps, macUI interpreter.
//  PIN:  Packages cannot invent a selector language.
//

import Foundation

public enum PluginKeyModifier: String, Codable, Hashable, Sendable, CaseIterable {
    case command
    case option
    case control
    case shift
    case function
}

/// Closed virtual keys supported by Mary's macUI interpreter.
public enum PluginKey: String, Codable, Hashable, Sendable, CaseIterable {
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z
    case zero, one, two, three, four, five, six, seven, eight, nine
    case equal, minus
    case rightBracket, leftBracket, quote, semicolon, backslash
    case comma, slash, period, grave
    case escape, `return`, tab, space, delete, forwardDelete
    case home, pageUp, end, pageDown
    case leftArrow, rightArrow, upArrow, downArrow
}

public enum PluginPointerButton: String, Codable, Hashable, Sendable, CaseIterable {
    case left
    case right
}

/// Read-only geometry-anchor roles. Declaring never grants mutation.
public enum PluginAccessibilityRole: String, Codable, Hashable, Sendable, CaseIterable {
    /// Public AX exposes custom application canvases with this exact role.
    /// It is still paired with an exact identifier and unique traversal.
    case unknown
    case button
    case cell
    case checkBox
    case colorWell
    case comboBox
    case disclosureTriangle
    case group
    case image
    case link
    case list
    case menuButton
    case menuItem
    case outline
    case popUpButton
    case progressIndicator
    case radioButton
    case radioGroup
    case row
    case scrollArea
    case scrollBar
    case slider
    case splitGroup
    case splitter
    case staticText
    case tabGroup
    case table
    case textArea
    case textField
    case toolbar
}

/// Exact AX container under the pinned window. Unique descendant if descendantRole set.
public struct PluginAccessibilityAnchorLocatorSchema: Codable, Hashable, Sendable {
    public var role: PluginAccessibilityRole
    public var identifier: String
    public var descendantRole: PluginAccessibilityRole?
    public var descendantIdentifier: String?
    /// Exact AXTitle of an untitled control (menu item, type picker).
    public var descendantTitle: String?
    /// Row label text. Trailing-most matching descendant; tie refuses.
    public var descendantLabelText: String?

    public init(
        role: PluginAccessibilityRole,
        identifier: String,
        descendantRole: PluginAccessibilityRole? = nil,
        descendantIdentifier: String? = nil,
        descendantTitle: String? = nil,
        descendantLabelText: String? = nil
    ) {
        self.role = role
        self.identifier = identifier
        self.descendantRole = descendantRole
        self.descendantIdentifier = descendantIdentifier
        self.descendantTitle = descendantTitle
        self.descendantLabelText = descendantLabelText
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case role
        case identifier
        case descendantRole
        case descendantIdentifier
        case descendantTitle
        case descendantLabelText
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        role = try values.decode(PluginAccessibilityRole.self, forKey: .role)
        identifier = try values.decode(String.self, forKey: .identifier)
        descendantRole = try values.decodeIfPresent(
            PluginAccessibilityRole.self,
            forKey: .descendantRole)
        descendantIdentifier = try values.decodeIfPresent(
            String.self,
            forKey: .descendantIdentifier)
        descendantTitle = try values.decodeIfPresent(
            String.self, forKey: .descendantTitle)
        descendantLabelText = try values.decodeIfPresent(
            String.self, forKey: .descendantLabelText)
    }
}
