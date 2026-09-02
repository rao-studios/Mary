//
//  PerceptionReport.swift
//  MaryRuntime
//
//  WHAT: Copy serializer — whole perception pane as deterministic text.
//  OUT:  paste-ready report (golden-tested; change tests with the format)
//  PIN:  one `key: value` per line; watched cards then unavailable; ISO-8601 UTC
//

import MaryBrain
import Foundation

package enum PerceptionReport {

    /// The whole pane: focus block + every recognized card, fixed order
    /// regardless of input order. Unavailable Keynote is retained on purpose.
    package static func serialize(focus: FocusSummary, cards: [PerceptionCard], at now: Date) -> String {
        let ordered = PerceptionWorld.current().compactMap { world in
            cards.first { $0.world == world }
        }
        var blocks = [focusBlock(focus, at: now)]
        blocks.append(contentsOf: ordered.map { cardBlock($0, at: now) })
        return blocks.joined(separator: "\n\n")
    }

    /// One card (the inspector's Copy) — focus block + that card.
    package static func serialize(focus: FocusSummary, card: PerceptionCard, at now: Date) -> String {
        focusBlock(focus, at: now) + "\n\n" + cardBlock(card, at: now)
    }

    /// `1.2s` under a minute, `3m 12s` under an hour, `1h 3m` beyond.
    package static func ageString(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        if clamped < 60 { return String(format: "%.1fs", clamped) }
        let total = Int(clamped)
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    // MARK: - Blocks

    private static func focusBlock(_ focus: FocusSummary, at now: Date) -> String {
        var lines = ["=== Mary PERCEPTION \(timestamp(now)) ==="]
        lines.append("focus.ambient: \(token(focus.ambient))")
        lines.append("focus.effective: \(token(focus.effective))")
        lines.append("focus.pin: \(focus.pinned?.reportToken ?? "none")")
        // Only when false — "open and not leading" is a decision, not a lost app.
        if !focus.writingInPlay {
            lines.append("focus.writing-in-play: no")
        }
        // Last Skill-read destination. `read: read discarded — reached nobody` is the miss.
        if let read = focus.readDelivery {
            lines.append("read: \(read.summary)")
            lines.append("read.age: \(age(of: read.at, at: now))")
        } else {
            lines.append("read: none this session")
        }
        // Held facts from the store (bounds + age). Eyeless facts live only here —
        // calendar/reminders have no watched-world card.
        if !focus.heldReads.isEmpty {
            lines.append("held.ranking: \(focus.rankingMode.rawValue)")
            for fact in focus.heldReads {
                lines.append("held.\(fact.key.id): \(oneLine(fact.mentionLine(at: now)))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func cardBlock(_ card: PerceptionCard, at now: Date) -> String {
        var lines = ["--- \(card.world.rawValue) (\(card.world.representativeBundleID)) ---"]
        lines.append("running: \(card.isRunning ? "yes" : "no")")
        lines.append("watcher: \(card.blindness == .watcherInactive ? "inactive" : "active")")
        lines.append("blind: \(card.blindness?.label ?? "none")")
        if let blindness = card.blindness {
            lines.append("remedy: \(oneLine(blindness.remedy))")
        }
        lines.append("age: \(age(of: card.capturedAt, at: now))")
        lines.append("poll: \(card.pollDescription)")
        lines.append("last-success: \(age(of: card.lastSuccessAt, at: now))")
        lines.append("last-error: \(card.lastError.map(oneLine) ?? "none")")
        lines.append("pinned: \(card.isPinned ? "yes" : "no")")
        lines.append("routing: \(card.routing)")
        // Which lanes got it — beside routing so a pasted report shows the mismatch.
        lines.append("delivery: \(card.delivery)")
        for field in card.fields {
            lines.append("\(field.label): \(oneLine(field.value))")
        }
        if let contribution = card.contribution {
            lines.append("contribution:")
            lines.append(quoted(contribution))
        } else {
            lines.append("contribution: none")
        }
        for extra in card.extraContributions {
            lines.append("\(extra.label):")
            lines.append(quoted(extra.value))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Atoms

    private static func token(_ focus: WorkspaceFocus?) -> String {
        focus?.rawValue ?? "none"
    }

    private static func age(of date: Date?, at now: Date) -> String {
        guard let date else { return "never" }
        return ageString(now.timeIntervalSince(date))
    }

    /// ISO-8601 UTC, second precision — `2026-07-27T14:03:22Z`.
    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Field rows must stay rows — greppability beats fidelity here; the
    /// quoted contribution block keeps the real newlines.
    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }

    private static func quoted(_ text: String) -> String {
        text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
    }
}
