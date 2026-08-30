//
//  SpokenPhrase.swift
//  MaryBrain
//
//  WHAT: Everything plugins render for the ear — time, weekday, counts, sizes, phones, sites.
//  IN:   Skill summaries → TTS
//  PIN:  No ISO dates, 24-hour clocks, URLs, or punctuation soup.
//
import Foundation

public enum SpokenPhrase {

    /// "10 AM", "4:30 PM", "noon", "midnight".
    public static func timePhrase(_ date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        if minute == 0 {
            if hour == 12 { return "noon" }
            if hour == 0 { return "midnight" }
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = minute == 0 ? "h a" : "h:mm a"
        return formatter.string(from: date)
    }

    /// "today", "tomorrow", "yesterday", "on Tuesday", "on Tuesday, July 28".
    public static func dayPhrase(_ date: Date, relativeTo now: Date, calendar: Calendar = .current) -> String {
        let target = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: today, to: target).day ?? 0

        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        default:
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = (2...6).contains(days) ? "EEEE" : "EEEE, MMMM d"
            return "on " + formatter.string(from: date)
        }
    }

    /// Small counts as words — they're spoken.
    public static func countWord(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six",
                     "seven", "eight", "nine", "ten", "eleven", "twelve"]
        return n < words.count ? words[n] : String(n)
    }

    /// Oxford-free spoken joining: "a", "a and b", "a, b, and c".
    public static func joinSpoken(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }

    /// "two point three megabytes", "five hundred kilobytes", "1.2 gigabytes".
    public static func sizePhrase(bytes: Int64) -> String {
        let units: [(Int64, String)] = [
            (1 << 30, "gigabytes"), (1 << 20, "megabytes"), (1 << 10, "kilobytes"),
        ]
        for (scale, name) in units where bytes >= scale {
            let value = Double(bytes) / Double(scale)
            if value >= 10 {
                return "\(Int(value.rounded())) \(name)"
            }
            let rounded = (value * 10).rounded() / 10
            if rounded == rounded.rounded() {
                return "\(Int(rounded)) \(name)"
            }
            let whole = Int(rounded)
            let tenth = Int((rounded * 10).rounded()) % 10
            return "\(whole) point \(tenth) \(name)"
        }
        return "\(bytes) bytes"
    }

    /// First `limit` items spoken, remainder counted: "a, b, …and three more".
    public static func boundedList(_ items: [String], limit: Int) -> String {
        guard items.count > limit else { return joinSpoken(items) }
        let shown = items.prefix(limit).joined(separator: ", ")
        return "\(shown), and \(countWord(items.count - limit)) more"
    }

    /// Phone digits grouped for speech: "four one five, five five five, one two one two".
    public static func phonePhrase(_ number: String) -> String {
        let digits = number.filter(\.isNumber)
        guard !digits.isEmpty else { return number }
        var groups: [String] = []
        var remaining = Substring(digits)
        // Last four, then threes from the front (US-ish grouping, harmless elsewhere).
        if remaining.count > 4 {
            let tail = remaining.suffix(4)
            remaining = remaining.dropLast(4)
            var head: [String] = []
            while !remaining.isEmpty {
                head.append(String(remaining.prefix(3)))
                remaining = remaining.dropFirst(3)
            }
            groups = head + [String(tail)]
        } else {
            groups = [String(remaining)]
        }
        return groups
            .map { $0.map(String.init).joined(separator: " ") }
            .joined(separator: ", ")
    }

    /// "nytimes dot com" — site names, never raw URLs, in speech.
    public static func domainPhrase(url: String) -> String {
        var host = url
        if let parsed = URL(string: url), let component = parsed.host {
            host = component
        } else if let range = url.range(of: "://") {
            host = String(url[range.upperBound...].prefix(while: { $0 != "/" }))
        }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host.replacingOccurrences(of: ".", with: " dot ")
    }
}
