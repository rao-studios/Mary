//
//  SpokenDuration.swift
//  MaryPlugin
//
//  WHAT: "Two minutes", "thirty seconds", "1:30", "a minute and a half" — a
//        spoken length of time, and which way it points.
//  IN:   a phrase the person said
//  OUT:  the browsing adapter's seek; anything else that takes a time
//  PIN:  THE SAME CLOSED ENGLISH VOCABULARY AS `SpokenOrdinal`, and on the same
//        side of the doctrine for the same reason "third" is: these are the
//        words a person counts time with, not a page's words. A number without
//        a unit is not a time — "go to 90" could be a page, a percent, a
//        second — so it answers nil rather than guess.
//

import Foundation

public enum SpokenDuration {

    /// Where a seek should land.
    public enum Seek: Equatable, Sendable {
        /// An absolute position from the start.
        case to(TimeInterval)
        /// A move from wherever it is now; negative is backwards.
        case by(TimeInterval)
    }

    static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
        "forty": 40, "fifty": 50, "sixty": 60, "ninety": 90, "half": 0.5, "quarter": 0.25,
    ]
    static let unitSeconds: [String: Double] = [
        "second": 1, "seconds": 1, "sec": 1, "secs": 1,
        "minute": 60, "minutes": 60, "min": 60, "mins": 60,
        "hour": 3600, "hours": 3600, "hr": 3600, "hrs": 3600,
    ]
    /// Words that point a move backwards.
    static let backwardWords: Set<String> = [
        "back", "backward", "backwards", "rewind", "earlier", "before",
    ]
    /// Words that make a time a destination rather than a distance.
    static let destinationWords: Set<String> = ["to", "at"]

    /// The seek a phrase asks for, or nil when it names no length of time.
    public static func seek(in phrase: String) -> Seek? {
        let tokens = phrase.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":")).inverted)
            .filter { !$0.isEmpty }
        guard let (seconds, span) = duration(in: tokens) else { return nil }
        // "three minutes in" / "go to three minutes" / "at 1:30" are places;
        // "back two minutes" / "skip thirty seconds" are moves.
        let before = tokens[..<span.lowerBound]
        let after = tokens[(span.upperBound + 1)...]
        // A trailing "in" — "three minutes in" — is a place; "back two minutes
        // in the video" is a move, and its "in" belongs to the video.
        let isDestination = before.last.map(destinationWords.contains) == true
            || Array(after) == ["in"]
            || (before.last == "back" && before.dropLast().last == "go" && after.first == "to")
        if isDestination { return .to(seconds) }
        let backwards = tokens.contains(where: backwardWords.contains)
        return .by(backwards ? -seconds : seconds)
    }

    /// The first length of time in the tokens, and the token span it occupies.
    static func duration(in tokens: [String]) -> (seconds: Double, span: ClosedRange<Int>)? {
        for (index, token) in tokens.enumerated() {
            // A clock: 1:30, 2:05:10.
            if token.contains(":"), let clock = clockSeconds(token) {
                return (clock, index...index)
            }
            // A number, spoken or written, followed by a unit — "two minutes",
            // "30 seconds", "a minute and a half", "half a minute".
            guard let quantity = number(token), index + 1 < tokens.count else { continue }
            var unitIndex = index + 1
            // "half a minute": the fraction, then an article, then the unit.
            if tokens[unitIndex] == "a" || tokens[unitIndex] == "an", unitIndex + 1 < tokens.count {
                unitIndex += 1
            }
            guard let unit = unitSeconds[tokens[unitIndex]] else { continue }
            var seconds = quantity * unit
            var end = unitIndex
            // "and a half" / "and a quarter" after the unit.
            if unitIndex + 3 < tokens.count, tokens[unitIndex + 1] == "and",
               tokens[unitIndex + 2] == "a", let fraction = numberWords[tokens[unitIndex + 3]],
               fraction < 1 {
                seconds += fraction * unit
                end = unitIndex + 3
            }
            return (seconds, index...end)
        }
        return nil
    }

    static func number(_ token: String) -> Double? {
        if let spoken = numberWords[token] { return spoken }
        return Double(token)
    }

    static func clockSeconds(_ token: String) -> Double? {
        let parts = token.split(separator: ":").map { Double($0) }
        guard parts.allSatisfy({ $0 != nil }), (2...3).contains(parts.count) else { return nil }
        let values = parts.compactMap { $0 }
        return values.reduce(0) { $0 * 60 + $1 }
    }

    /// `2:00`, or `1:02:03` past the hour — the spoken form of a length.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(abs(seconds).rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, rest) }
        return String(format: "%d:%02d", minutes, rest)
    }
}
