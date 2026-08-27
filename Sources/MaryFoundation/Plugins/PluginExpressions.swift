//
//  PluginExpressions.swift
//  MaryFoundation
//
//  THE ONLY ARITHMETIC A RECIPE MAY DO. A scalar, text, point, or rect is
//  composed from literals, declared inputs, and observed geometry — never from
//  package-authored code — so every value a step uses stays inspectable.
//

import Foundation

/// A scalar is either a literal or a reference to a declared operation input.
/// Input references may provide a fallback for optional arguments.
public struct PluginScalarExpression: Codable, Hashable, Sendable {
    public var value: Double?
    public var input: String?
    public var defaultValue: Double?
    /// A bounded literal added to an INPUT-sourced value at resolution —
    /// "the created region's origin plus a small inset". Meaningless (and
    /// refused by validation) beside a pure literal, whose author can simply
    /// write the sum.
    public var offset: Double?

    public init(value: Double) {
        self.value = value
        self.input = nil
        self.defaultValue = nil
        self.offset = nil
    }

    public init(input: String, defaultValue: Double? = nil, offset: Double? = nil) {
        self.value = nil
        self.input = input
        self.defaultValue = defaultValue
        self.offset = offset
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case value
        case input
        case defaultValue
        case offset
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = try values.decodeIfPresent(Double.self, forKey: .value)
        input = try values.decodeIfPresent(String.self, forKey: .input)
        defaultValue = try values.decodeIfPresent(Double.self, forKey: .defaultValue)
        offset = try values.decodeIfPresent(Double.self, forKey: .offset)
    }
}

/// Printable text supplied literally by an Ability or through one declared
/// operation input. The interpreter rejects control characters and newlines
/// before acquiring foreground input authority.
public struct PluginTextExpression: Codable, Hashable, Sendable {
    public var value: String?
    public var input: String?
    public var defaultValue: String?

    public init(value: String) {
        self.value = value
        self.input = nil
        self.defaultValue = nil
    }

    public init(input: String, defaultValue: String? = nil) {
        self.value = nil
        self.input = input
        self.defaultValue = defaultValue
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case value
        case input
        case defaultValue
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = try values.decodeIfPresent(String.self, forKey: .value)
        input = try values.decodeIfPresent(String.self, forKey: .input)
        defaultValue = try values.decodeIfPresent(String.self, forKey: .defaultValue)
    }
}

/// Pointer values are normalized into the application's content rectangle.
/// (0,0) is its upper-leading corner and (1,1) its lower-trailing corner.
public struct PluginPointExpression: Codable, Hashable, Sendable {
    public var x: PluginScalarExpression
    public var y: PluginScalarExpression

    public init(x: PluginScalarExpression, y: PluginScalarExpression) {
        self.x = x
        self.y = y
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case x
        case y
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        x = try values.decode(PluginScalarExpression.self, forKey: .x)
        y = try values.decode(PluginScalarExpression.self, forKey: .y)
    }
}

public struct PluginRectExpression: Codable, Hashable, Sendable {
    public var x: PluginScalarExpression
    public var y: PluginScalarExpression
    public var width: PluginScalarExpression
    public var height: PluginScalarExpression

    public init(
        x: PluginScalarExpression,
        y: PluginScalarExpression,
        width: PluginScalarExpression,
        height: PluginScalarExpression
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case x
        case y
        case width
        case height
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        x = try values.decode(PluginScalarExpression.self, forKey: .x)
        y = try values.decode(PluginScalarExpression.self, forKey: .y)
        width = try values.decode(PluginScalarExpression.self, forKey: .width)
        height = try values.decode(PluginScalarExpression.self, forKey: .height)
    }
}
