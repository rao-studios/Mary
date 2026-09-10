//
//  AbilityStudioHandsControls.swift
//  Mary
//
//  WHAT: The three controls the macUI block editor still needs, in Mary's language.
//  IN:   Recipe row → hands editor → block cards.
//  OUT:  Views/Kit chrome.
//  PIN:  These keep the old kit's binding-shaped API because the block cards
//        pass `draftBinding(...)` straight through. Only the look changed.
//

import MaryBrain
import SwiftUI

/// Binding-shaped text field. `StudioField` owns the value-and-commit form; the
/// block editors were written against a Binding, so this wraps it.
struct AbilityStudioTextField: View {
    let title: String
    let path: String
    @Binding var text: String
    var monospaced = false

    init(
        _ title: String,
        path: String,
        text: Binding<String>,
        monospaced: Bool = false
    ) {
        self.title = title
        self.path = path
        _text = text
        self.monospaced = monospaced
    }

    var body: some View {
        StudioField(
            title,
            value: text,
            mono: monospaced
        ) { text = $0 }
    }
}

/// Seconds, offsets, ratios. Commits on focus loss like every other field, and
/// clamps before it leaves.
struct AbilityStudioDoubleField: View {
    let title: String
    let path: String
    let value: Double
    var range: ClosedRange<Double>?
    let onChange: (Double) -> Void

    init(
        _ title: String,
        path: String,
        value: Double,
        range: ClosedRange<Double>? = nil,
        onChange: @escaping (Double) -> Void
    ) {
        self.title = title
        self.path = path
        self.value = value
        self.range = range
        self.onChange = onChange
    }

    var body: some View {
        StudioField(
            title,
            value: Self.text(value),
            mono: true
        ) { next in
            guard let parsed = Double(next.trimmingCharacters(in: .whitespaces)) else { return }
            onChange(range.map { min(max(parsed, $0.lowerBound), $0.upperBound) } ?? parsed)
        }
    }

    /// Whole numbers read as whole numbers; a step is not more precise for
    /// showing "2.0".
    static func text(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%g", value)
    }
}

/// Machine path under a control. The panes speak plain words; the block editor
/// is close enough to the schema that the path earns its place.
struct AbilityStudioSchemaPath: View {
    let path: String
    init(_ path: String) { self.path = path }
    var body: some View { StudioSchemaPath(path) }
}
