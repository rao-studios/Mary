//
//  PageInteractionPlanValidator+Diagnostics.swift
//  MaryFoundation
//
//  WHAT: Locations, scalars, and the issue vocabulary the parsers speak.
//  IN:   PageInteractionPlanValidator+Commands
//  OUT:  admitted values, or a named issue
//  PIN:  A BOOL IS NOT A NUMBER. `true` bridges to NSNumber and would read as 1, so a
//        `count: true` would admit as one click. The type id is checked, once, here.
//

import CoreFoundation
import Foundation

extension PageInteractionPlanValidator {

    // MARK: - Plan shape

    /// A hover is useful only while the plan still holds the pointer — to reveal a menu
    /// the next click names. The pointer is put back when the plan ends, so a plan whose
    /// last real act is a hover asks for something that cannot survive its own ending.
    static func terminalHover(in plan: PageInteractionPlan) -> Int? {
        for (offset, command) in plan.commands.enumerated() {
            guard case .hover = command.action else { continue }
            let leadsSomewhere = plan.commands[(offset + 1)...].contains {
                if case .wait = $0.action { return false }
                return true
            }
            if !leadsSomewhere { return command.sourceIndex }
        }
        return nil
    }

    // MARK: - Locations

    static func pointerLocation(
        _ object: [String: Any], sourceIndex: Int, issues: inout [PageInteractionPlanIssue]
    ) -> PageInteractionPointerLocation? {
        let hasTarget = object["target"] != nil
        let hasPoint = object["point"] != nil
        guard hasTarget != hasPoint else {
            append(
                .mutuallyExclusiveFields, sourceIndex: sourceIndex, field: "target",
                message: "A pointer command takes exactly one of target or point.", to: &issues)
            return nil
        }
        if hasTarget {
            return requiredTarget(object["target"], sourceIndex: sourceIndex, issues: &issues)
                .map(PageInteractionPointerLocation.target)
        }
        return point(
            object["point"]!, field: "point", sourceIndex: sourceIndex, issues: &issues)
            .map(PageInteractionPointerLocation.point)
    }

    static func point(
        _ raw: Any, field: String, sourceIndex: Int, issues: inout [PageInteractionPlanIssue]
    ) -> PageInteractionNormalizedPoint? {
        guard let object = raw as? [String: Any] else {
            invalidType(
                field, expected: "an object with x and y",
                sourceIndex: sourceIndex, issues: &issues)
            return nil
        }
        for unknown in Set(object.keys).subtracting(["x", "y"]).sorted() {
            append(
                .unknownField, sourceIndex: sourceIndex, field: "\(field).\(unknown)",
                message: "\(field) has no field named \(unknown).", to: &issues)
        }
        var x: Double?
        if let rawX = object["x"] {
            x = boundedNumber(
                rawX, field: "\(field).x", range: 0 ... 1,
                sourceIndex: sourceIndex, issues: &issues)
        } else {
            missing("\(field).x", sourceIndex: sourceIndex, issues: &issues)
        }
        var y: Double?
        if let rawY = object["y"] {
            y = boundedNumber(
                rawY, field: "\(field).y", range: 0 ... 1,
                sourceIndex: sourceIndex, issues: &issues)
        } else {
            missing("\(field).y", sourceIndex: sourceIndex, issues: &issues)
        }
        guard let x, let y else { return nil }
        return .init(x: x, y: y)
    }

    static func requiredTarget(
        _ raw: Any?, sourceIndex: Int, issues: inout [PageInteractionPlanIssue]
    ) -> String? {
        guard let raw else {
            missing("target", sourceIndex: sourceIndex, issues: &issues)
            return nil
        }
        return target(raw, sourceIndex: sourceIndex, issues: &issues)
    }

    static func optionalTarget(
        _ raw: Any?, sourceIndex: Int, issues: inout [PageInteractionPlanIssue]
    ) -> String? {
        guard let raw else { return nil }
        return target(raw, sourceIndex: sourceIndex, issues: &issues)
    }

    static func target(
        _ raw: Any, sourceIndex: Int, issues: inout [PageInteractionPlanIssue]
    ) -> String? {
        guard let value = raw as? String else {
            invalidType("target", expected: "a string", sourceIndex: sourceIndex, issues: &issues)
            return nil
        }
        guard printableTarget(value) else {
            append(
                .invalidValue, sourceIndex: sourceIndex, field: "target",
                message: "target must be printable text under \(maximumTargetBytes) bytes.",
                to: &issues)
            return nil
        }
        return value
    }

    static func printableTarget(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximumTargetBytes
            && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
    }

    // MARK: - Scalars

    static func token<T>(
        _ raw: Any, as type: T.Type, field: String, sourceIndex: Int,
        issues: inout [PageInteractionPlanIssue]
    ) -> T? where T: RawRepresentable & CaseIterable, T.RawValue == String {
        guard let text = raw as? String else {
            invalidType(field, expected: "a string", sourceIndex: sourceIndex, issues: &issues)
            return nil
        }
        guard let value = T(rawValue: text) else {
            let known = T.allCases.map(\.rawValue).sorted().joined(separator: ", ")
            append(
                .invalidValue, sourceIndex: sourceIndex, field: field,
                message: "\(field) does not take \(text) — only \(known).", to: &issues)
            return nil
        }
        return value
    }

    static func boolean(
        _ raw: Any, field: String, sourceIndex: Int, issues: inout [PageInteractionPlanIssue]
    ) -> Bool? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            invalidType(field, expected: "true or false", sourceIndex: sourceIndex, issues: &issues)
            return nil
        }
        return number.boolValue
    }

    static func integer(
        _ raw: Any, field: String, range: ClosedRange<Int>, sourceIndex: Int,
        issues: inout [PageInteractionPlanIssue]
    ) -> Int? {
        guard let value = number(raw), value.rounded(.towardZero) == value,
              value >= Double(Int.min), value <= Double(Int.max)
        else {
            invalidType(field, expected: "a whole number", sourceIndex: sourceIndex, issues: &issues)
            return nil
        }
        let whole = Int(value)
        guard range.contains(whole) else {
            append(
                .invalidValue, sourceIndex: sourceIndex, field: field,
                message: "\(field) must be between \(range.lowerBound) and \(range.upperBound).",
                to: &issues)
            return nil
        }
        return whole
    }

    static func boundedNumber(
        _ raw: Any, field: String, range: ClosedRange<Double>, sourceIndex: Int,
        issues: inout [PageInteractionPlanIssue]
    ) -> Double? {
        guard let value = number(raw), value.isFinite else {
            invalidType(field, expected: "a finite number", sourceIndex: sourceIndex, issues: &issues)
            return nil
        }
        guard range.contains(value) else {
            append(
                .invalidValue, sourceIndex: sourceIndex, field: field,
                message: "\(field) must be between \(compact(range.lowerBound)) and \(compact(range.upperBound)).",
                to: &issues)
            return nil
        }
        return value
    }

    static func number(_ raw: Any) -> Double? {
        if let number = raw as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue
        }
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        return nil
    }

    // MARK: - Issues

    static func rejectUnknownFields(
        in object: [String: Any], allowed: Set<String>, sourceIndex: Int,
        issues: inout [PageInteractionPlanIssue]
    ) {
        for field in Set(object.keys).subtracting(allowed).sorted() {
            append(
                .unknownField, sourceIndex: sourceIndex, field: field,
                message: "\(object["kind"] as? String ?? "command") has no field named \(field).",
                to: &issues)
        }
    }

    static func missing(
        _ field: String, sourceIndex: Int, issues: inout [PageInteractionPlanIssue]
    ) {
        append(
            .missingField, sourceIndex: sourceIndex, field: field,
            message: "This command needs \(field).", to: &issues)
    }

    static func invalidType(
        _ field: String, expected: String, sourceIndex: Int,
        issues: inout [PageInteractionPlanIssue]
    ) {
        append(
            .invalidType, sourceIndex: sourceIndex, field: field,
            message: "\(field) must be \(expected).", to: &issues)
    }

    static func append(
        _ code: PageInteractionPlanIssueCode, sourceIndex: Int? = nil, field: String? = nil,
        message: String, to issues: inout [PageInteractionPlanIssue]
    ) {
        issues.append(.init(sourceIndex: sourceIndex, code: code, field: field, message: message))
    }

    static func compact(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}
