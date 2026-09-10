//
//  TextBudget.swift
//  MaryPlugin
//
//  WHAT: Fit text into a prompt without lying about the cut (head + gap + tail).
//  PIN:  Three quarters to the head.

import Foundation

public enum TextBudget {

    /// Head, an honest gap, tail. THREE QUARTERS TO THE HEAD, because the beginning of a
    /// document says what it is and the end says where it got to; the middle is the part a
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
