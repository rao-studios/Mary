//
//  PluginValidator+Expressions.swift
//  MaryFoundation
//
//  Admission for the recipe expression grammar: exactly one literal or input
//  reference per expression, inputs that actually exist, and coordinates that
//  stay inside the normalized unit interval.
//

import Foundation

extension PluginValidator {
    static func validate(
        _ expression: PluginTextExpression,
        inputs: [String: PluginOperationInputSchema],
        path: String,
        error: (String, String, String) -> Void
    ) {
        guard (expression.value == nil) != (expression.input == nil) else {
            error(
                "invalid-plugin-text-expression",
                path,
                "Text must contain exactly one literal or declared input reference.")
            return
        }
        if let value = expression.value, !printableTextIsValid(value) {
            error(
                "invalid-plugin-text",
                "\(path).value",
                "Remote-hand text must be bounded printable text without line breaks or control characters.")
        }
        if let fallback = expression.defaultValue, !printableTextIsValid(fallback) {
            error(
                "invalid-plugin-text",
                "\(path).defaultValue",
                "Remote-hand text fallbacks must be bounded printable text without line breaks or control characters.")
        }
        guard let inputName = expression.input else { return }
        guard let input = inputs[inputName] else {
            error("unknown-plugin-input", "\(path).input", "Recipe input \(inputName) is not declared by its operation.")
            return
        }
        guard input.kind == .text else {
            error("plugin-text-input-type", "\(path).input", "Text entry requires a declared text input.")
            return
        }
    }

    static func validateScroll(
        _ scalar: PluginScalarExpression,
        inputs: [String: PluginOperationInputSchema],
        path: String,
        error: (String, String, String) -> Void
    ) {
        guard (scalar.value == nil) != (scalar.input == nil) else {
            error("invalid-plugin-scalar-expression", path, "A scroll delta must contain exactly one literal or input reference.")
            return
        }
        if let offset = scalar.offset {
            if scalar.value != nil {
                error("plugin-scalar-offset-on-literal", "\(path).offset", "An offset composes with an input reference; fold it into the literal instead.")
            }
            if !offset.isFinite || abs(offset) > 10_000 {
                error("invalid-plugin-scalar-offset", "\(path).offset", "Scalar offsets must be finite values between -10000 and 10000.")
            }
        }
        func bounded(_ value: Double) -> Bool {
            value.isFinite && abs(value) <= 10_000
        }
        if let value = scalar.value, !bounded(value) {
            error("invalid-plugin-scroll-delta", "\(path).value", "Scroll deltas must be finite values between -10000 and 10000.")
        }
        if let fallback = scalar.defaultValue, !bounded(fallback) {
            error("invalid-plugin-scroll-delta", "\(path).defaultValue", "Scroll delta fallbacks must be finite values between -10000 and 10000.")
        }
        guard let inputName = scalar.input else { return }
        guard let input = inputs[inputName] else {
            error("unknown-plugin-input", "\(path).input", "Recipe input \(inputName) is not declared by its operation.")
            return
        }
        guard [.number, .integer].contains(input.kind) else {
            error("plugin-scroll-input-type", "\(path).input", "Scroll deltas require a number or integer input.")
            return
        }
        if input.minimum.map({ $0 < -10_000 }) ?? true
            || input.maximum.map({ $0 > 10_000 }) ?? true {
            error(
                "unbounded-plugin-scroll-input",
                "\(path).input",
                "Scroll inputs must declare bounds contained by -10000 through 10000.")
        }
    }

    static func validate(
        _ point: PluginPointExpression,
        inputs: [String: PluginOperationInputSchema],
        path: String,
        error: (String, String, String) -> Void
    ) {
        validate(point.x, inputs: inputs, path: "\(path).x", positive: false, error: error)
        validate(point.y, inputs: inputs, path: "\(path).y", positive: false, error: error)
    }

    static func validate(
        _ rect: PluginRectExpression,
        inputs: [String: PluginOperationInputSchema],
        path: String,
        error: (String, String, String) -> Void
    ) {
        validate(rect.x, inputs: inputs, path: "\(path).x", positive: false, error: error)
        validate(rect.y, inputs: inputs, path: "\(path).y", positive: false, error: error)
        validate(rect.width, inputs: inputs, path: "\(path).width", positive: true, error: error)
        validate(rect.height, inputs: inputs, path: "\(path).height", positive: true, error: error)
    }

    static func validate(
        _ scalar: PluginScalarExpression,
        inputs: [String: PluginOperationInputSchema],
        path: String,
        positive: Bool,
        error: (String, String, String) -> Void
    ) {
        guard (scalar.value == nil) != (scalar.input == nil) else {
            error("invalid-plugin-scalar-expression", path, "A coordinate must contain exactly one literal or input reference.")
            return
        }
        if let offset = scalar.offset {
            if scalar.value != nil {
                error("plugin-scalar-offset-on-literal", "\(path).offset", "An offset composes with an input reference; fold it into the literal instead.")
            }
            if !offset.isFinite || abs(offset) > 10_000 {
                error("invalid-plugin-scalar-offset", "\(path).offset", "Scalar offsets must be finite values between -10000 and 10000.")
            }
        }
        func bounded(_ value: Double) -> Bool {
            value.isFinite && (positive ? value > 0 : value >= 0) && value <= 1
        }
        if let value = scalar.value, !bounded(value) {
            error("invalid-plugin-coordinate", "\(path).value", "Normalized coordinates must be within the unit interval.")
        }
        if let fallback = scalar.defaultValue, !bounded(fallback) {
            error("invalid-plugin-coordinate", "\(path).defaultValue", "Normalized coordinate fallbacks must be within the unit interval.")
        }
        guard let inputName = scalar.input else { return }
        guard let input = inputs[inputName] else {
            error("unknown-plugin-input", "\(path).input", "Recipe input \(inputName) is not declared by its operation.")
            return
        }
        guard [.number, .integer].contains(input.kind) else {
            error("plugin-coordinate-input-type", "\(path).input", "Coordinates require a number or integer input.")
            return
        }
        if input.minimum.map({ positive ? $0 <= 0 : $0 < 0 }) ?? true
            || input.maximum.map({ $0 > 1 }) ?? true {
            error(
                "unbounded-plugin-coordinate-input",
                "\(path).input",
                "Coordinate inputs must declare bounds contained by the normalized unit interval.")
        }
    }
}
