//
//  TextBudget.swift
//  MaryPlugin
//
//  FITTING TEXT INTO A PROMPT WITHOUT LYING ABOUT WHAT WAS CUT.
//
//  Every read that reaches the model passes through here. It keeps the HEAD
//  and the TAIL and says how much went missing in between, because a plain
//  `prefix(n)` produces something indistinguishable from a document that
//  simply ends there — and a model handed a truncated file with no marker
//  will confidently describe it as complete.
//

import Foundation

public enum TextBudget {

    /// Head, an honest gap, tail.
    ///
    /// THREE QUARTERS TO THE HEAD, because the beginning of a document says
    /// what it is and the end says where it got to; the middle is the part a
    /// reader can most often do without.
    public static func truncate(_ output: String, limit: Int = 4000) -> String {
        // A budget of zero can only honestly return nothing; without this the
        // arithmetic below would slice with negative lengths.
        guard limit > 0 else { return "" }
        guard output.count > limit else { return output }
        let headLength = limit * 3 / 4
        let head = output.prefix(headLength)
        let tail = output.suffix(limit - headLength)
        let omitted = output.count - limit
        return "\(head)\n… [\(omitted) more characters] …\n\(tail)"
    }
}
