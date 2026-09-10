//
//  PluginValidator+Steps.swift
//  MaryFoundation
//
//  WHAT: One input and one recipe step — anchors, values, ordering.
//  IN:   PluginValidator+Operations.
//  OUT:  PluginValidator+Expressions, +Tokens.
//

import Foundation

extension PluginValidator {
    static func validate(
        _ input: PluginOperationInputSchema,
        path: String,
        error: (String, String, String) -> Void
    ) {
        if !callableNameIsValid(input.name) {
            error("invalid-plugin-input", "\(path).name", "Plugin input names use lower-case snake_case.")
        }
        if input.required && input.defaultValue != nil {
            error(
                "required-plugin-input-default",
                "\(path).defaultValue",
                "A required Plugin input cannot also declare a fallback value.")
        }
        if let minimum = input.minimum, !minimum.isFinite {
            error("invalid-plugin-input-bound", "\(path).minimum", "Input bounds must be finite.")
        }
        if let maximum = input.maximum, !maximum.isFinite {
            error("invalid-plugin-input-bound", "\(path).maximum", "Input bounds must be finite.")
        }
        if let minimum = input.minimum, let maximum = input.maximum, minimum > maximum {
            error("invalid-plugin-input-range", path, "An input minimum cannot exceed its maximum.")
        }
        if !input.enumValues.isEmpty,
           input.kind != .text {
            error(
                "plugin-input-enum-type",
                "\(path).enumValues",
                "Only text inputs may declare a closed enum vocabulary.")
        }
        if [.text, .boolean].contains(input.kind),
           input.minimum != nil || input.maximum != nil {
            error(
                "plugin-input-bound-type",
                path,
                "Only number and integer inputs may declare numeric bounds.")
        }
        if input.enumValues.count > 64 {
            error(
                "too-many-plugin-input-enum-values",
                "\(path).enumValues",
                "A text input may declare at most 64 enum values.")
        }
        for duplicate in duplicates(input.enumValues) {
            error(
                "duplicate-plugin-input-enum-value",
                "\(path).enumValues",
                "Enum value \(duplicate) appears more than once.")
        }
        for (index, value) in input.enumValues.enumerated()
        where !printableTextIsValid(value) {
            error(
                "invalid-plugin-input-enum-value",
                "\(path).enumValues[\(index)]",
                "Text enum values must be bounded printable text without line breaks.")
        }
        if let value = input.defaultValue,
           !inputValueIsValid(value, for: input) {
            error(
                "invalid-plugin-input-default",
                "\(path).defaultValue",
                "The fallback does not satisfy this Plugin input contract.")
        }
    }

    static func validate(
        _ step: PluginRecipeStepSchema,
        inputs: [String: PluginOperationInputSchema],
        availableAnchors: Set<String>,
        path: String,
        error: (String, String, String) -> Void
    ) {
        if !SchemaIdentifierValidation.isValid(step.id) {
            error("invalid-plugin-step-id", "\(path).id", "Recipe step ids use portable lower-case identifiers.")
        }
        for duplicate in duplicates(step.modifiers.map(\.rawValue)) {
            error("duplicate-plugin-modifier", "\(path).modifiers", "Modifier \(duplicate) appears more than once.")
        }
        func rejectUnexpected(
            key: Bool = false,
            modifiers: Bool = false,
            text: Bool = false,
            point: Bool = false,
            rect: Bool = false,
            delta: Bool = false,
            accessibilityLocator: Bool = false,
            space: Bool = false,
            capture: Bool = false,
            aspect: Bool = false,
            button: Bool = false,
            clickCount: Bool = false,
            duration: Bool = false,
            windowChange: Bool = false
        ) {
            let unexpected = (step.key != nil && !key)
                || (!step.modifiers.isEmpty && !modifiers)
                || (step.text != nil && !text)
                || (step.point != nil && !point)
                || (step.rect != nil && !rect)
                || ((step.deltaX != nil || step.deltaY != nil) && !delta)
                || (step.accessibilityLocator != nil && !accessibilityLocator)
                || (step.coordinateSpace != nil && !space)
                || (step.captureAnchor != nil && !capture)
                || (step.aspectRatio != nil && !aspect)
                || (step.button != nil && !button)
                || (step.clickCount != nil && !clickCount)
                || (step.durationSeconds != nil && !duration)
                || (step.requiresWindowChange != nil && !windowChange)
            if unexpected {
                error(
                    "plugin-step-shape-mismatch",
                    path,
                    "A \(step.kind.rawValue) step contains fields owned by another recipe instruction.")
            }
        }

        switch step.kind {
        case .keyChord:
            rejectUnexpected(key: true, modifiers: true)
            if step.key == nil {
                error("missing-plugin-key", "\(path).key", "A keyChord step must name one closed key.")
            }
        case .typeText:
            rejectUnexpected(text: true)
            guard let expression = step.text else {
                error("missing-plugin-text", "\(path).text", "A typeText step needs one literal or declared text input.")
                return
            }
            validate(expression, inputs: inputs, path: "\(path).text", error: error)
        case .pointerMove:
            rejectUnexpected(point: true, space: true, duration: true)
            if let point = step.point {
                validate(point, inputs: inputs, path: "\(path).point", error: error)
            } else {
                error("missing-plugin-point", "\(path).point", "A pointerMove step needs a normalized point.")
            }
            if let duration = step.durationSeconds,
               !duration.isFinite || duration < 0 || duration > maximumWaitSeconds {
                error(
                    "invalid-plugin-pointer-duration",
                    "\(path).durationSeconds",
                    "A pointer move must last between zero and \(Int(maximumWaitSeconds)) seconds.")
            }
        case .pointerClick:
            rejectUnexpected(point: true, space: true, button: true, clickCount: true)
            if let point = step.point {
                validate(point, inputs: inputs, path: "\(path).point", error: error)
            } else {
                error("missing-plugin-point", "\(path).point", "A pointerClick step needs a normalized point.")
            }
            if let count = step.clickCount, !(1...3).contains(count) {
                error("invalid-plugin-click-count", "\(path).clickCount", "Click count must be between one and three.")
            }
        case .pointerDrag, .pointerSquareDrag:
            rejectUnexpected(
                rect: true,
                space: true,
                capture: true,
                aspect: step.kind == .pointerDrag,
                button: true,
                duration: true)
            if let rect = step.rect {
                validate(rect, inputs: inputs, path: "\(path).rect", error: error)
                if step.kind == .pointerSquareDrag,
                   rect.width != rect.height {
                    error(
                        "plugin-square-drag-needs-one-side",
                        "\(path).rect",
                        "A pointerSquareDrag must use the same scalar expression for width and height.")
                }
            } else {
                error(
                    "missing-plugin-rect",
                    "\(path).rect",
                    "A \(step.kind.rawValue) step needs a normalized rectangle.")
            }
            if let duration = step.durationSeconds,
               !duration.isFinite || duration < 0.05 || duration > maximumWaitSeconds {
                error(
                    "invalid-plugin-drag-duration",
                    "\(path).durationSeconds",
                    "A pointer drag must last between 0.05 and \(Int(maximumWaitSeconds)) seconds.")
            }
            if let aspectRatio = step.aspectRatio,
               !aspectRatio.isFinite || aspectRatio < 0.05 || aspectRatio > 20 {
                error(
                    "invalid-plugin-aspect-ratio",
                    "\(path).aspectRatio",
                    "A drag aspect ratio must be finite and between 0.05 and 20.")
            }
        case .scroll:
            rejectUnexpected(delta: true, duration: true)
            guard step.deltaX != nil || step.deltaY != nil else {
                error(
                    "missing-plugin-scroll-delta",
                    path,
                    "A scroll step needs a horizontal or vertical delta.")
                return
            }
            if let deltaX = step.deltaX {
                validateScroll(deltaX, inputs: inputs, path: "\(path).deltaX", error: error)
            }
            if let deltaY = step.deltaY {
                validateScroll(deltaY, inputs: inputs, path: "\(path).deltaY", error: error)
            }
            if let duration = step.durationSeconds,
               !duration.isFinite || duration < 0 || duration > maximumWaitSeconds {
                error(
                    "invalid-plugin-scroll-duration",
                    "\(path).durationSeconds",
                    "A scroll must last between zero and \(Int(maximumWaitSeconds)) seconds.")
            }
        case .rebindFocusedWindow:
            rejectUnexpected(windowChange: true)
        case .captureAccessibilityAnchor:
            rejectUnexpected(accessibilityLocator: true, capture: true)
            guard let locator = step.accessibilityLocator else {
                error(
                    "missing-plugin-accessibility-locator",
                    "\(path).accessibilityLocator",
                    "A captureAccessibilityAnchor step needs one closed public-Accessibility locator.")
                return
            }
            if !boundedAccessibilityIdentifierIsValid(locator.identifier) {
                error(
                    "invalid-plugin-accessibility-identifier",
                    "\(path).accessibilityLocator.identifier",
                    "An Accessibility identifier must be nonempty bounded printable text.")
            }
            if locator.descendantRole == nil,
               locator.descendantIdentifier != nil {
                error(
                    "orphaned-plugin-accessibility-descendant-identifier",
                    "\(path).accessibilityLocator.descendantIdentifier",
                    "A descendant Accessibility identifier requires one closed descendant role.")
            }
            if let descendantIdentifier = locator.descendantIdentifier,
               !boundedAccessibilityIdentifierIsValid(descendantIdentifier) {
                error(
                    "invalid-plugin-accessibility-descendant-identifier",
                    "\(path).accessibilityLocator.descendantIdentifier",
                    "A descendant Accessibility identifier must be nonempty bounded printable text.")
            }
            let descendantDiscriminators = [
                locator.descendantIdentifier,
                locator.descendantTitle,
                locator.descendantLabelText,
            ].compactMap { $0 }
            if descendantDiscriminators.count > 1 {
                error(
                    "conflicting-plugin-accessibility-descendant",
                    "\(path).accessibilityLocator",
                    "A descendant resolves by at most one discriminator: identifier, exact title, or row label.")
            }
            if locator.descendantRole == nil,
               locator.descendantTitle != nil
                || locator.descendantLabelText != nil {
                error(
                    "orphaned-plugin-accessibility-descendant-identifier",
                    "\(path).accessibilityLocator",
                    "A titled or row-labeled descendant requires one closed descendant role.")
            }
            for text in [locator.descendantTitle, locator.descendantLabelText]
            where text != nil && !boundedAccessibilityIdentifierIsValid(text!) {
                error(
                    "invalid-plugin-accessibility-descendant-identifier",
                    "\(path).accessibilityLocator",
                    "A descendant title or row label must be nonempty bounded printable text.")
            }
            if step.captureAnchor == nil {
                error(
                    "missing-plugin-capture-anchor",
                    "\(path).captureAnchor",
                    "A captureAccessibilityAnchor step must name the bounded coordinate anchor it captures.")
            }
        case .wait:
            rejectUnexpected(duration: true)
            guard let duration = step.durationSeconds,
                  duration.isFinite,
                  duration > 0,
                  duration <= maximumWaitSeconds else {
                error(
                    "invalid-plugin-wait",
                    "\(path).durationSeconds",
                    "A wait step must be greater than zero and no longer than \(Int(maximumWaitSeconds)) seconds.")
                return
            }
        }
        if let space = step.coordinateSpace,
           space != "content",
           space != "window",
           !availableAnchors.contains(space) {
            error(
                "unknown-plugin-coordinate-space",
                "\(path).coordinateSpace",
                "Coordinate space \(space) must be window, content, or an anchor captured by an earlier drag.")
        }
        if let capture = step.captureAnchor,
           !SchemaIdentifierValidation.isValid(capture) {
            error(
                "invalid-plugin-capture-anchor",
                "\(path).captureAnchor",
                "Captured anchor names use portable lower-case identifiers.")
        }
    }
}
