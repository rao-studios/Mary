import MaryBrain
import SwiftUI

// MARK: - Closed-vocabulary presentation

extension PluginRecipeStepSchema {
    static func editorDefault(kind: PluginRecipeStepKind, id: String) -> Self {
        switch kind {
        case .keyChord:
            return .init(id: id, kind: kind, key: .n, modifiers: [.command])
        case .typeText:
            return .init(id: id, kind: kind, text: .init(value: "Text"))
        case .pointerMove:
            return .init(
                id: id,
                kind: kind,
                point: .init(x: .init(value: 0.5), y: .init(value: 0.5)),
                durationSeconds: 0.15)
        case .pointerClick:
            return .init(
                id: id,
                kind: kind,
                point: .init(x: .init(value: 0.5), y: .init(value: 0.5)),
                button: .left)
        case .pointerDrag, .pointerSquareDrag:
            return .init(
                id: id,
                kind: kind,
                rect: .init(
                    x: .init(value: 0.3), y: .init(value: 0.3),
                    width: .init(value: 0.2), height: .init(value: 0.2)),
                button: .left,
                durationSeconds: 0.25)
        case .scroll:
            return .init(
                id: id,
                kind: kind,
                deltaY: .init(value: -120),
                durationSeconds: 0.15)
        case .rebindFocusedWindow:
            return .init(id: id, kind: kind)
        case .captureAccessibilityAnchor:
            return .init(
                id: id,
                kind: kind,
                accessibilityLocator: .init(
                    role: .group,
                    identifier: "accessibility-element"),
                captureAnchor: "accessibility-area")
        case .wait:
            return .init(id: id, kind: kind, durationSeconds: 0.1)
        }
    }

    var chordLabel: String {
        (PluginKeyModifier.editorOrder
            .filter(modifiers.contains)
            .map(\.editorGlyph) + [key?.editorLabel ?? "…"])
            .joined()
    }
}

extension PluginRecipeStepKind {
    /// WHAT THE EXECUTOR CAN ACTUALLY PERFORM. Mary's hands post keys, text,
    /// waits, window rebinds, and the pointer family — move, click, drag,
    /// scroll, and a read-only Accessibility capture used as a later
    /// coordinate space. An editor must not author what the runtime will
    /// not run; these cases are exactly that set.
    static var authorableCases: [Self] {
        [
            .keyChord, .typeText, .pointerMove, .pointerClick, .pointerDrag,
            .pointerSquareDrag, .scroll, .captureAccessibilityAnchor,
            .wait, .rebindFocusedWindow,
        ]
    }

    var editorTitle: String {
        switch self {
        case .keyChord: return "Key Chord"
        case .typeText: return "Type Text"
        case .pointerMove: return "Pointer Move"
        case .pointerClick: return "Pointer Click"
        case .pointerDrag: return "Pointer Drag"
        case .pointerSquareDrag: return "Square Drag"
        case .scroll: return "Scroll"
        case .rebindFocusedWindow: return "Accept New Window"
        case .captureAccessibilityAnchor: return "Capture Accessibility Area"
        case .wait: return "Bounded Wait"
        }
    }

    var editorSymbol: String {
        switch self {
        case .keyChord: return "command"
        case .typeText: return "text.cursor"
        case .pointerMove: return "cursorarrow.motionlines"
        case .pointerClick: return "cursorarrow.click"
        case .pointerDrag: return "arrow.up.left.and.arrow.down.right"
        case .pointerSquareDrag: return "square.dashed"
        case .scroll: return "scroll"
        case .rebindFocusedWindow: return "macwindow.on.rectangle"
        case .captureAccessibilityAnchor: return "viewfinder.rectangular"
        case .wait: return "timer"
        }
    }

    var editorColor: Color {
        switch self {
        case .keyChord: return .purple
        case .typeText: return .teal
        case .pointerMove, .pointerClick: return .blue
        case .pointerDrag, .pointerSquareDrag: return .indigo
        case .scroll: return .cyan
        case .rebindFocusedWindow: return .green
        case .captureAccessibilityAnchor: return .mint
        case .wait: return .orange
        }
    }
}

extension PluginKeyModifier {
    /// Conventional macOS chord presentation order. Schema arrays retain
    /// their authored order; Studio renders the set consistently.
    static let editorOrder: [Self] = [
        .control, .option, .shift, .command, .function,
    ]

    var editorGlyph: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        case .function: return "fn"
        }
    }
}

extension PluginKey {
    var editorLabel: String {
        switch self {
        case .zero: return "0"
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        case .four: return "4"
        case .five: return "5"
        case .six: return "6"
        case .seven: return "7"
        case .eight: return "8"
        case .nine: return "9"
        case .escape: return "esc"
        case .return: return "↩"
        case .tab: return "⇥"
        case .space: return "space"
        case .delete: return "⌫"
        case .forwardDelete: return "⌦"
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        default: return rawValue.uppercased()
        }
    }
}

extension PluginPointExpression {
    var literalPoint: CGPoint {
        CGPoint(
            x: x.value ?? x.defaultValue ?? 0.5,
            y: y.value ?? y.defaultValue ?? 0.5)
    }
}

extension PluginRectExpression {
    var literalRect: CGRect {
        CGRect(
            x: x.value ?? x.defaultValue ?? 0.3,
            y: y.value ?? y.defaultValue ?? 0.3,
            width: width.value ?? width.defaultValue ?? 0.2,
            height: height.value ?? height.defaultValue ?? 0.2)
    }
}
