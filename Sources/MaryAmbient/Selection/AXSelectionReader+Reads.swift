//
//  AXSelectionReader+Reads.swift
//  MaryAmbient
//
//  Split out of AXSelectionReader.swift (docs/DECOMPOSITION.md Wave 4)
//  — pure relocation, no declaration changed.
//

import AppKit
import ApplicationServices
import MaryFoundation
import Foundation

extension AXSelectionReader {

    // MARK: - Reads

    /// Extract a selection from the element that AX says changed. This is the
    /// shared primitive for generic capture and Pages' richer adapter; neither
    /// caller guesses at a role or walks an arbitrary document tree to decide
    /// what a real selection means.
    public static func selectionState(
        of element: AXUIElement,
        role suppliedRole: String? = nil,
        resolution: PerceptionElementResolution? = nil
    ) -> SelectionState {
        let role = suppliedRole ?? copyString(element, kAXRoleAttribute)
        guard !isSecureField(role: role) else { return .unavailable }
        let range = cfRange(of: element, attribute: kAXSelectedTextRangeAttribute)

        if let selected = selectedText(of: element), !selected.isEmpty {
            return .selected(reading(
                text: selected, range: range, extraction: .selectedText,
                element: element, role: role, resolution: resolution))
        }
        if let markerText = textForSelectedMarkerRange(of: element), !markerText.isEmpty {
            return .selected(reading(
                text: markerText, range: range, extraction: .textMarkerRange,
                element: element, role: role, resolution: resolution))
        }
        guard let range else { return .unavailable }
        if range.isEmpty { return .caret(range: range) }
        if let rangeText = textForRange(range, in: element), !rangeText.isEmpty {
            return .selected(reading(
                text: rangeText, range: range, extraction: .characterRange,
                element: element, role: role, resolution: resolution))
        }
        if let valueText = valueSlice(range, in: element), !valueText.isEmpty {
            return .selected(reading(
                text: valueText, range: range, extraction: .valueSlice,
                element: element, role: role, resolution: resolution))
        }
        return .unreadableNonemptyRange(range: range)
    }

    private static func reading(
        text: String,
        range: Range<Int>?,
        extraction: Extraction,
        element: AXUIElement,
        role: String?,
        resolution: PerceptionElementResolution?
    ) -> Reading {
        let wasTruncated = text.count > readCap
        let capped = String(text.prefix(readCap))
        return Reading(
            text: capped,
            surroundingText: surroundingText(
                of: element, selectedText: text, range: range),
            role: role,
            resolution: resolution,
            range: range,
            extraction: extraction,
            editability: editability(of: element),
            sourceSurfaceID: sourceSurfaceID(of: element),
            completeness: wasTruncated ? .truncated : .complete,
            valueDigest: AmbientSelectionHandoff.digest(text))
    }

    private static func selectedText(of element: AXUIElement) -> String? {
        AX.string(element, kAXSelectedTextAttribute)
    }

    private static func surroundingText(
        of element: AXUIElement, selectedText: String, range suppliedRange: Range<Int>?
    ) -> String? {
        guard let value = copyString(element, kAXValueAttribute),
              let range = suppliedRange ?? cfRange(of: element, attribute: kAXSelectedTextRangeAttribute)
        else { return nil }
        let body = value as NSString
        guard range.lowerBound >= 0, range.upperBound <= body.length,
              body.substring(with: NSRange(location: range.lowerBound, length: range.count)) == selectedText
        else { return nil }
        let lower = max(0, range.lowerBound - surroundingContextRadius)
        let upper = min(body.length, range.upperBound + surroundingContextRadius)
        let context = body.substring(with: NSRange(location: lower, length: upper - lower))
        return context == selectedText ? nil : context
    }

    /// Canvas editors may publish their selection only as an opaque marker
    /// range. Its string is already in the element's coordinate system, so it
    /// is stronger than attempting to map a Pages document range elsewhere.
    private static func textForSelectedMarkerRange(of element: AXUIElement) -> String? {
        guard let markerRef = AX.attribute(element, kAXSelectedTextMarkerRangeAttribute),
              CFGetTypeID(markerRef) == AXTextMarkerRangeGetTypeID()
        else { return nil }
        return parameterizedString(
            element,
            parameter: markerRef,
            stringAttribute: kAXStringForTextMarkerRangeParameterizedAttribute,
            attributedStringAttribute: kAXAttributedStringForTextMarkerRangeParameterizedAttribute)
    }

    private static func textForRange(_ range: Range<Int>, in element: AXUIElement) -> String? {
        var cfRange = CFRange(location: range.lowerBound, length: range.count)
        guard let parameter = withUnsafePointer(to: &cfRange, {
            AXValueCreate(.cfRange, $0)
        }) else { return nil }
        return parameterizedString(
            element,
            parameter: parameter,
            stringAttribute: kAXStringForRangeParameterizedAttribute,
            attributedStringAttribute: kAXAttributedStringForRangeParameterizedAttribute)
    }

    private static func parameterizedString(
        _ element: AXUIElement,
        parameter: CFTypeRef,
        stringAttribute: String,
        attributedStringAttribute: String
    ) -> String? {
        var textRef: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(
            element, stringAttribute as CFString, parameter, &textRef
        ) == .success, let text = textRef as? String {
            return text
        }
        var attributedRef: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(
            element, attributedStringAttribute as CFString, parameter, &attributedRef
        ) == .success {
            if let attributed = attributedRef as? NSAttributedString { return attributed.string }
            if let text = attributedRef as? String { return text }
        }
        return nil
    }

    private static func valueSlice(_ range: Range<Int>, in element: AXUIElement) -> String? {
        guard let value = copyString(element, kAXValueAttribute) else { return nil }
        let string = value as NSString
        guard range.lowerBound >= 0, range.upperBound <= string.length else { return nil }
        return string.substring(with: NSRange(location: range.lowerBound, length: range.count))
    }

    private static func cfRange(of element: AXUIElement, attribute: String) -> Range<Int>? {
        AX.range(element, attribute)
    }

    // MARK: - CF plumbing

    static func copyElement(
        _ element: AXUIElement, _ attribute: String
    ) -> AXUIElement? {
        AX.element(element, attribute)
    }

    static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        AX.string(element, attribute)
    }
}
