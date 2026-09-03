//
//  PairedRead.swift
//  MaryComputerUse
//
//  WHAT: One observation per listing row. Bracket property reads with
//        identifier lists; emit only if both ID lists match.
//  OUT:  rows | movedToken (caller speaks the miss)
//  PIN:  Length clamp is not this guard. Retry once, then the token.
//

import Foundation

public enum PairedRead {

    /// One listing column: Apple Event landing var, list var, whole-column get.
    public struct Column {
        public let raw: String
        public let list: String
        public let expression: String

        public init(raw: String, list: String, expression: String) {
            self.raw = raw
            self.list = list
            self.expression = expression
        }
    }

    /// Returned instead of rows when the collection moved between ID brackets.
    /// PIN: no field separator; unspeakable so a leak fails loudly.
    public static let movedToken = "MARY-COLLECTION-MOVED"

    /// True when output is the moved token, not rows.
    /// PIN: test this before emptiness — the token parses to zero rows.
    public static func moved(_ output: String) -> Bool {
        output.trimmingCharacters(in: .whitespacesAndNewlines) == movedToken
    }

    /// Bracketed AppleScript: IDs, fields, IDs again. Retry once.
    /// OUT: binds `rowCount` and each `Column.list` for the caller's emit loop.
    /// PIN: both ID reads use the identical expression.
    public static func block(
        application: String,
        setup: [String] = [],
        identifiers: Column,
        fields: [Column]
    ) -> String {
        var lines: [String] = []
        lines.append("set rowsPaired to false")
        lines.append("repeat with attemptNumber from 1 to 2")
        lines.append("    try")
        lines.append("        tell application \"\(application)\"")
        for line in setup {
            lines.append("            \(line)")
        }
        lines.append("            set \(identifiers.raw) to \(identifiers.expression)")
        for field in fields {
            lines.append("            set \(field.raw) to \(field.expression)")
        }
        // Same ID expression, second look. Mismatch → collection moved.
        lines.append("            set recheckIDs to \(identifiers.expression)")
        lines.append("        end tell")
        // PIN: one-row collections arrive as a bare value; `count of` a string is characters.
        lines.append("        set \(identifiers.list) to \(identifiers.raw) as list")
        for field in fields {
            lines.append("        set \(field.list) to \(field.raw) as list")
        }
        lines.append("        set rowCount to count of \(identifiers.list)")
        lines.append("        set sameLengths to true")
        for field in fields {
            lines.append(
                "        if (count of \(field.list)) is not equal to rowCount then set sameLengths to false")
        }
        // PIN: Notes IDs are text; AppleScript compares them case-insensitively otherwise.
        lines.append("        considering case")
        lines.append("            set sameRows to ((recheckIDs as list) is equal to \(identifiers.list))")
        lines.append("        end considering")
        lines.append("        if sameRows and sameLengths then")
        lines.append("            set rowsPaired to true")
        lines.append("            exit repeat")
        lines.append("        end if")
        // Retry once. Mid-read mutation → second attempt; permission errors pass through.
        lines.append("    on error errorText number errorNumber")
        lines.append("        if attemptNumber is 2 then error errorText number errorNumber")
        lines.append("    end try")
        lines.append("end repeat")
        lines.append("if rowsPaired is false then return \"\(movedToken)\"")
        return lines.joined(separator: "\n")
    }
}
