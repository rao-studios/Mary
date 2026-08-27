//
//  AmbientAge.swift
//  MaryBrain
//
//  Coarse ages — "seconds vs minutes vs hours", the vocabulary
//  `PagesContextWatcher.livenessLine` already speaks, in ONE place so the
//  prompt and the pane can never phrase the same age two ways.
//
//  Tiny on purpose and public on purpose: the report, the inspector and the
//  prompt all stamp ages, and an age formatted three ways reads as three
//  different facts.
//

import Foundation

public enum AmbientAge {
    public static func string(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "an unknown time" }
        if seconds < 90 { return "\(Int(seconds.rounded()))s" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded()))m" }
        if seconds < 86_400 * 30 { return "\(Int((seconds / 3600).rounded()))h" }
        return "an unknown time"
    }
}
