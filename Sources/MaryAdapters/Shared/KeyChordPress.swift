//
//  KeyChordPress.swift
//  MaryAdapters
//
//  PRESSING A DECLARED KEY CHORD — ⌘N, ⌘S, ⇧⌘M.
//
//  The typer posts TEXT and Return; a chord is a different act. It carries
//  modifiers, it goes to whatever holds focus, and its whole purpose is to
//  reach a menu command an application never exposed any other way. That is
//  the one thing a Plugin recipe can express (`keyChord`), so this is the
//  compiled floor beneath the declarative step vocabulary as well as beneath
//  the prose lane's `newDocument`.
//
//  IT DOES NOT DECIDE WHERE. A chord lands wherever focus is, and every
//  caller must have brought the target forward and verified it first —
//  `VerifiedActivation` exists for that. A chord posted at an unverified
//  target is a keystroke into an unknown application, which for ⌘N is
//  harmless and for the chords that follow it is not.
//
//  THE VOCABULARY IS THE SCHEMA'S. Keys and modifiers arrive as the closed
//  enums a package may declare, so a package cannot name a key this cannot
//  press, and this cannot press a key no package can name.
//

import CoreGraphics
import Foundation
import MaryFoundation

public enum KeyChordPress {

    /// Press one chord. False when the key has no keycode on this layout or
    /// the events could not be created — never a claim about what the
    /// application did with it.
    @discardableResult
    public static func press(key: PluginKey, modifiers: [PluginKeyModifier]) -> Bool {
        guard let code = keyCode(for: key) else { return false }
        let flags = flags(for: modifiers)

        // The source is nil (HID level) for the same reason the typer's is: a
        // session-level tap is filtered by applications that guard against
        // synthetic input, and the guard is right to filter it.
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    static func flags(for modifiers: [PluginKeyModifier]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            case .shift: flags.insert(.maskShift)
            case .function: flags.insert(.maskSecondaryFn)
            }
        }
        return flags
    }

    /// ANSI virtual keycodes, which are POSITIONS on the keyboard rather than
    /// characters.
    ///
    /// That distinction is why this is a table and not arithmetic: the codes
    /// are not alphabetical, not contiguous, and not derivable from the
    /// letter — A is 0 and B is 11. Pressing a POSITION is also what a menu
    /// shortcut means, so ⌘Z is the bottom-left key on a Dvorak layout too.
    static func keyCode(for key: PluginKey) -> CGKeyCode? {
        switch key {
        case .a: return 0
        case .b: return 11
        case .c: return 8
        case .d: return 2
        case .e: return 14
        case .f: return 3
        case .g: return 5
        case .h: return 4
        case .i: return 34
        case .j: return 38
        case .k: return 40
        case .l: return 37
        case .m: return 46
        case .n: return 45
        case .o: return 31
        case .p: return 35
        case .q: return 12
        case .r: return 15
        case .s: return 1
        case .t: return 17
        case .u: return 32
        case .v: return 9
        case .w: return 13
        case .x: return 7
        case .y: return 16
        case .z: return 6
        case .zero: return 29
        case .one: return 18
        case .two: return 19
        case .three: return 20
        case .four: return 21
        case .five: return 23
        case .six: return 22
        case .seven: return 26
        case .eight: return 28
        case .nine: return 25
        case .equal: return 24
        case .minus: return 27
        case .rightBracket: return 30
        case .leftBracket: return 33
        case .quote: return 39
        case .semicolon: return 41
        case .backslash: return 42
        case .comma: return 43
        case .slash: return 44
        case .period: return 47
        case .grave: return 50
        case .escape: return 53
        case .return: return 36
        case .tab: return 48
        case .space: return 49
        case .delete: return 51
        case .forwardDelete: return 117
        case .home: return 115
        case .pageUp: return 116
        case .end: return 119
        case .pageDown: return 121
        case .leftArrow: return 123
        case .rightArrow: return 124
        case .downArrow: return 125
        case .upArrow: return 126
        }
    }
}
