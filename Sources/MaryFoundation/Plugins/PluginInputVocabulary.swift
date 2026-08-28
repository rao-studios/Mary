//
//  PluginInputVocabulary.swift
//  MaryFoundation
//
//  The closed vocabulary a recipe step may name: keys, modifiers, pointer
//  buttons, Accessibility roles, and the anchor locator that finds an element
//  without letting a package invent its own selector language.
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

/// Closed public-Accessibility roles that may identify a read-only geometry
/// anchor. Declaring one never grants permission to press, set, focus, or
/// otherwise mutate an Accessibility element.
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

/// Conjunctive locator for one exact public-Accessibility container under the
/// already pinned owning window. When `descendantRole` is present, the frame
/// belongs to the one unique matching descendant within that exact container;
/// its identifier may be omitted only because uniqueness is still proved by a
/// complete bounded traversal. Titles and values are never locator fallbacks.
public struct PluginAccessibilityAnchorLocatorSchema: Codable, Hashable, Sendable {
    public var role: PluginAccessibilityRole
    public var identifier: String
    public var descendantRole: PluginAccessibilityRole?
    public var descendantIdentifier: String?
    /// Exact AXTitle of the descendant — the closed spelling for titled but
    /// unidentified controls (menu items, type pickers).
    public var descendantTitle: String?
    /// Exact static-text value on the descendant's row: resolves the
    /// TRAILING-MOST descendant of the closed role whose vertical center
    /// shares a row with the one label bearing this text — the platform's
    /// row-action convention. A second label or a trailing tie refuses.
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

/// One key chord, named by what it accomplishes rather than by which keys it
/// presses.
///
/// LIVES HERE, WITH THE VOCABULARY IT IS BUILT FROM, because it belongs to no
/// one lane. It arrived on the prose surface and was named for it, which read
/// as a fact about prose — a key and a set of modifiers is nothing of the
/// kind. The browser surface presses ⌘T out of the same struct.
public struct PluginChord: Codable, Hashable, Sendable {
    public var key: PluginKey
    public var modifiers: [PluginKeyModifier]

    public init(key: PluginKey, modifiers: [PluginKeyModifier] = []) {
        self.key = key
        self.modifiers = modifiers
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case key
        case modifiers
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(PluginKey.self, forKey: .key)
        modifiers = try values.decodeIfPresent([PluginKeyModifier].self, forKey: .modifiers) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        if !modifiers.isEmpty { try container.encode(modifiers, forKey: .modifiers) }
    }
}

/// Which Accessibility attribute carries an element's name.
///
/// A DECLARED CHOICE AND NOT A LADDER, in the one place where a ladder is
/// wrong. A reader climbing title-then-description-then-value is right about
/// page content, where any of the three may hold the words. It is wrong about
/// a browser's tab strip: Chrome names a tab in its DESCRIPTION and Safari in
/// its TITLE, and Chrome's tabs also carry a title that is empty. A ladder
/// finds an unnamed strip in one browser and never says why.
public enum PluginElementTextAttribute: String, Codable, Hashable, Sendable, CaseIterable {
    case title
    case description
    case value

    /// The Accessibility attribute name this selects.
    public var attributeName: String {
        switch self {
        case .title: return "AXTitle"
        case .description: return "AXDescription"
        case .value: return "AXValue"
        }
    }
}
