//
//  PageInteractionPlanValidator+Commands.swift
//  MaryFoundation
//
//  WHAT: One parser per command kind, and the field set each admits.
//  IN:   PageInteractionPlanValidator.validate
//  OUT:  PageInteractionAction, or issues naming exactly what was wrong
//  PIN:  AN UNKNOWN FIELD IS AN ERROR, NOT A SHRUG. A misspelled `targt` silently
//        ignored becomes a click with no target, which is a click somewhere nobody
//        chose. Every kind lists what it takes and refuses the rest by name.
//

import CoreFoundation
import Foundation

extension PageInteractionPlanValidator {

    static func allowedFields(for kind: PageInteractionCommandKind) -> Set<String> {
        let fields: Set<String>
        switch kind {
        case .click:
            fields = ["target", "point", "button", "count"]
        case .hover:
            fields = ["target", "point"]
        case .drag:
            fields = ["target", "point", "destination", "targetFraction", "button", "duration"]
        case .keyChord:
            fields = ["key"]
        case .typeText:
            fields = ["target", "text", "submit"]
        case .adjust:
            fields = ["target", "mode", "fraction"]
        case .scroll:
            fields = ["deltaX", "deltaY", "settle"]
        case .wait:
            fields = ["seconds"]
        case .navigate:
            // Unreachable: admission refuses it before the fields are read.
            fields = []
        }
        return fields.union(structuralFields)
    }

    static func parse(
        _ kind: PageInteractionCommandKind,
        object: [String: Any],
        sourceIndex: Int,
        issues: inout [PageInteractionPlanIssue]
    ) -> PageInteractionAction? {
        switch kind {
        case .click: return parseClick(object, sourceIndex: sourceIndex, issues: &issues)
        case .hover: return parseHover(object, sourceIndex: sourceIndex, issues: &issues)
        case .drag: return parseDrag(object, sourceIndex: sourceIndex, issues: &issues)
        case .keyChord: return parseKeyChord(object, sourceIndex: sourceIndex, issues: &issues)
        case .typeText: return parseTypeText(object, sourceIndex: sourceIndex, issues: &issues)
        case .adjust: return parseAdjust(object, sourceIndex: sourceIndex, issues: &issues)
        case .scroll: return parseScroll(object, sourceIndex: sourceIndex, issues: &issues)
        case .wait: return parseWait(object, sourceIndex: sourceIndex, issues: &issues)
        // Unreachable: admission refuses an engine-only kind first.
        case .navigate: return nil
        }
    }

    // MARK: - Pointer

    static func parseClick(
        _ object: [String: Any], sourceIndex: Int, issues: inout [PageInteractionPlanIssue]
    ) -> PageInteractionAction? {
        let location = pointerLocation(object, sourceIndex: sourceIndex, issues: &issues)
        let button: PageInteractionPointerButton?
        if let raw = object["button"] {
            button = token(
                raw, as: PageInteractionPointerButton.self, field: "button",
                sourceIndex: sourceIndex, issues: &issues)
        } else {
            button = .left
        }
        let count: Int?
        if let raw = object["count"] {
            count = integer(
                raw, field: "count", range: 1 ... 3, sourceIndex: sourceIndex, issues: &issues)
        } else {
            count = 1
        }
        guard let location, let button, let count else { return nil }
        return .click(.init(location: location, button: button, count: count))
    }

    static func parseHover(
        _ object: [String: Any], sourceIndex: Int, issues: inout [PageInteractionPlanIssue]
    ) -> PageInteractionAction? {
        guard let location = pointerLocation(object, sourceIndex: sourceIndex, issues: &issues)
        else { return nil }
        return .hover(.init(location: location))
    }

    static func parseDrag(
        _ object: [String: Any], sourceIndex: Int, issues: inout [PageInteractionPlanIssue]
    ) -> PageInteractionAction? {
        let source = pointerLocation(object, sourceIndex: sourceIndex, issues: &issues)
        let hasDestination = object["destination"] != nil
        let hasFraction = object["targetFraction"] != nil
        if hasDestination == hasFraction {
            append(
                .mutuallyExclusiveFields, sourceIndex: sourceIndex, field: "destination",
                message: "drag takes exactly one of destination or targetFraction.", to: &issues)
        }

        var destination: PageInteractionDragDestination?
        if hasDestination {
            destination = point(
                object["destination"]!, field: "destination",
                sourceIndex: sourceIndex, issues: &issues)
                .map(PageInteractionDragDestination.point)
        } else if hasFraction {
            if let fraction = boundedNumber(
                object["targetFraction"]!, field: "targetFraction", range: 0 ... 1,
                sourceIndex: sourceIndex, issues: &issues) {
                destination = .targetFraction(fraction)
            }
            if let source, case .point = source {
                append(
                    .invalidValue, sourceIndex: sourceIndex, field: "targetFraction",
                    message: "targetFraction needs a named drag source.", to: &issues)
            }
        }

        let duration: Double?
        if let raw = object["duration"] {
            duration = boundedNumber(
                raw, field: "duration",
                range: minimumDragDurationSeconds ... maximumDurationSeconds,
                sourceIndex: sourceIndex, issues: &issues)
        } else {
            duration = defaultDragDurationSeconds
        }
        let button: PageInteractionPointerButton?
        if let raw = object["button"] {
            button = token(
                raw, as: PageInteractionPointerButton.self, field: "button",
                sourceIndex: sourceIndex, issues: &issues)
        } else {
            button = .left
        }
        guard let source, let destination, let button, let duration else { return nil }
        return .drag(.init(
            source: source, destination: destination, button: button,
            durationSeconds: duration))
    }

    // MARK: - Keys and text

    static func parseKeyChord(
        _ object: [String: Any], sourceIndex: Int, issues: inout [PageInteractionPlanIssue]
    ) -> PageInteractionAction? {
        guard let raw = object["key"] else {
            missing("key", sourceIndex: sourceIndex, issues: &issues)
            return nil
        }
        // THE UNSUPPORTED-VALUE MESSAGE IS THE TEACHING. A model asking for ⌘F or "k"
        // gets told which three keys exist rather than a bare rejection.
        guard let key = token(
            raw, as: PageInteractionKey.self, field: "key",
            sourceIndex: sourceIndex, issues: &issues)
        else { return nil }
        return .keyChord(.init(key: key))
    }

    static func parseTypeText(
        _ object: [String: Any], sourceIndex: Int, issues: inout [PageInteractionPlanIssue]
    ) -> PageInteractionAction? {
        let target = optionalTarget(object["target"], sourceIndex: sourceIndex, issues: &issues)
        let submit: Bool?
        if let raw = object["submit"] {
            submit = boolean(raw, field: "submit", sourceIndex: sourceIndex, issues: &issues)
        } else {
            submit = false
        }
        guard let raw = object["text"] else {
            missing("text", sourceIndex: sourceIndex, issues: &issues)
            return nil
        }
        guard let value = raw as? String else {
            invalidType("text", expected: "a string", sourceIndex: sourceIndex, issues: &issues)
            return nil
        }
        guard !value.isEmpty, value.utf8.count <= maximumTypeTextBytes else {
            append(
                .invalidValue, sourceIndex: sourceIndex, field: "text",
                message: "text has to be between 1 and \(maximumTypeTextBytes) bytes.",
                to: &issues)
            return nil
        }
        guard let submit else { return nil }
        return .typeText(.init(target: target, text: value, submit: submit))
    }

    // MARK: - Ranges, scrolling, waiting

    static func parseAdjust(
        _ object: [String: Any], sourceIndex: Int, issues: inout [PageInteractionPlanIssue]
    ) -> PageInteractionAction? {
        let target = requiredTarget(object["target"], sourceIndex: sourceIndex, issues: &issues)
        let mode: PageInteractionAdjustmentMode?
        if let raw = object["mode"] {
            mode = token(
                raw, as: PageInteractionAdjustmentMode.self, field: "mode",
                sourceIndex: sourceIndex, issues: &issues)
        } else {
            missing("mode", sourceIndex: sourceIndex, issues: &issues)
            mode = nil
        }

        var fraction: Double?
        if mode == .fraction {
            if let raw = object["fraction"] {
                fraction = boundedNumber(
                    raw, field: "fraction", range: 0 ... 1,
                    sourceIndex: sourceIndex, issues: &issues)
            } else {
                missing("fraction", sourceIndex: sourceIndex, issues: &issues)
            }
        } else if mode != nil, object["fraction"] != nil {
            append(
                .invalidValue, sourceIndex: sourceIndex, field: "fraction",
                message: "fraction belongs only to adjust mode fraction.", to: &issues)
        }
        guard let target, let mode else { return nil }
        if mode == .fraction, fraction == nil { return nil }
        return .adjust(.init(target: target, mode: mode, fraction: fraction))
    }

    static func parseScroll(
        _ object: [String: Any], sourceIndex: Int, issues: inout [PageInteractionPlanIssue]
    ) -> PageInteractionAction? {
        let range = -maximumScrollDelta ... maximumScrollDelta
        let deltaX = object["deltaX"].map {
            boundedNumber(
                $0, field: "deltaX", range: range, sourceIndex: sourceIndex, issues: &issues)
        } ?? 0
        let deltaY = object["deltaY"].map {
            boundedNumber(
                $0, field: "deltaY", range: range, sourceIndex: sourceIndex, issues: &issues)
        } ?? 0
        let settle = object["settle"].map {
            boundedNumber(
                $0, field: "settle", range: 0 ... maximumDurationSeconds,
                sourceIndex: sourceIndex, issues: &issues)
        } ?? 0
        guard let deltaX, let deltaY, let settle else { return nil }
        guard deltaX != 0 || deltaY != 0 else {
            append(
                .invalidValue, sourceIndex: sourceIndex, field: "deltaX/deltaY",
                message: "scroll needs at least one delta that is not zero.", to: &issues)
            return nil
        }
        return .scroll(.init(deltaX: deltaX, deltaY: deltaY, settleSeconds: settle))
    }

    static func parseWait(
        _ object: [String: Any], sourceIndex: Int, issues: inout [PageInteractionPlanIssue]
    ) -> PageInteractionAction? {
        guard let raw = object["seconds"] else {
            missing("seconds", sourceIndex: sourceIndex, issues: &issues)
            return nil
        }
        guard let seconds = boundedNumber(
            raw, field: "seconds", range: 0 ... maximumDurationSeconds,
            sourceIndex: sourceIndex, issues: &issues)
        else { return nil }
        return .wait(.init(seconds: seconds))
    }
}
