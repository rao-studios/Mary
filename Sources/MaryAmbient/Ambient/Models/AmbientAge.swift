//
//  AmbientAge.swift
//  MaryBrain
//
//  WHAT: Coarse ages ("seconds vs minutes vs hours") in one phrasing.
//  OUT:  prompt and pane. Caller: PagesContextWatcher.livenessLine
//  PIN:  An age formatted three ways reads as three facts.
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
