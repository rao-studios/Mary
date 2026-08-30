//
//  Paper+Type.swift
//  Mary
//
//  WHAT: Serif type roles. Passage = Text.note + italic + lineSpacing(7) + kerning(0.3).
//

import SwiftUI

extension Text {
    enum Size {
        case title
        case body
        case note
        case note2

        func toColor() -> Color {
            switch self {
            case .title, .body:
                return .primary.opacity(0.75)
            case .note, .note2:
                return .primary.opacity(0.6)
            }
        }

        func toSize() -> CGFloat {
            switch self {
            case .title: return 24
            case .body: return 20
            case .note: return 18
            case .note2: return 16
            }
        }

        func toWeight() -> Font.Weight {
            switch self {
            case .title, .body: return .regular
            case .note, .note2: return .light
            }
        }
    }

    static func base(text: String, size: Size) -> Text {
        Text(text)
            .foregroundStyle(size.toColor())
            .font(.system(size: size.toSize(), weight: size.toWeight(), design: .serif))
    }

    static func attributedBase(text: AttributedString, size: Size) -> Text {
        Text(text)
            .foregroundStyle(size.toColor())
            .font(.system(size: size.toSize(), weight: size.toWeight(), design: .serif))
    }

    static func title(_ text: String) -> Text { .base(text: text, size: .title) }
    static func body(_ text: String) -> Text { .base(text: text, size: .body) }
    static func note(_ text: String) -> Text { .base(text: text, size: .note) }
    static func note(_ text: AttributedString) -> Text { .attributedBase(text: text, size: .note) }
    static func note2(_ text: String) -> Text { .base(text: text, size: .note2) }
    static func note2(_ text: AttributedString) -> Text { .attributedBase(text: text, size: .note2) }
}

extension String {
    /// Inline-only markdown (bold/italic/inline code), whitespace preserved.
    /// Ported from Gita (originally Sis's String extension).
    var attributed: AttributedString? {
        try? AttributedString(
            markdown: self,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }
}
