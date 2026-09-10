//
//  AwarenessBrief.swift
//  MaryPlugin
//
//  WHAT: What a trace reads like — standing (every turn) and asked (this turn).
//  IN:   EnclosingUnit / TraceHit
//  OUT:  AwarenessObserver.promptContribution / AwarenessAdapter summaries
//  PIN:  BEARINGS, NOT PROSE. This renders facts and their file:line so the
//        model can say what a thing IS; the sentences about how to speak them
//        belong to PromptCatalog, which is the only place that writes persona.
//

import Foundation

public enum AwarenessBrief {

    /// The standing block: small enough to carry every turn, specific enough
    /// to be worth carrying.
    public static let standingBudget = 900
    /// The asked block: what one question is worth.
    public static let surroundingsBudget = 2400

    /// One traced line — "readBuffer — CodeSurfaceAdapter.swift:132: guard let …".
    public static func line(_ hit: TraceHit) -> String {
        let where_ = "\(hit.relativePath):\(hit.line)"
        guard let enclosing = hit.enclosing, !enclosing.isEmpty else {
            return "- \(where_): \(hit.snippet)"
        }
        return "- \(enclosing) — \(where_): \(hit.snippet)"
    }

    /// The standing brief the observer keeps: what the unit IS, and its
    /// bearings. Never the unit's body — the caret window already carries the
    /// text, and repeating it would spend the live section twice.
    public static func standing(
        unit: EnclosingUnit,
        fileName: String,
        callers: [TraceHit],
        callees: [TraceHit],
        /// Whether the walk that produced these actually finished. A partial
        /// walk may not say "nothing reaches it" — it did not look everywhere.
        complete: Bool = true
    ) -> String {
        var lines = [
            "Around what they are working on (traced from the project on disk):",
            "In \(fileName), \(unit.display) — lines \(unit.startLine) to \(unit.endLine).",
        ]
        if unit.chain.count > 1 {
            lines.append("Inside \(unit.scope).")
        }
        if callers.isEmpty {
            if complete {
                lines.append("Nothing else in the project reaches it that I can see.")
            }
        } else {
            lines.append("Reached from:")
            lines.append(contentsOf: callers.map(line))
        }
        if !callees.isEmpty {
            lines.append("It reaches:")
            lines.append(contentsOf: callees.map(line))
        }
        return clipped(lines.joined(separator: "\n"), to: standingBudget)
    }

    // MARK: - A page

    /// The standing brief for a page: which page, and what it is offering.
    ///
    /// PIN: WHAT IS KNOWN, AND WHEN IT WAS KNOWN. The offers come from a read a
    /// SKILL made, not from anything this poll did, so the brief says how long
    /// ago — a list of buttons with no age on it invites acting on a page that
    /// has since moved. A page nobody has read says so plainly and names the
    /// verb that would read it, which is more useful than silence and more
    /// honest than a guess.
    public static func page(
        shell: WebSurfaceAX.Reading,
        roster: PageRoster?,
        age: TimeInterval?,
        browser: String
    ) -> String {
        var lines: [String] = []
        let title = shell.title ?? "an untitled page"
        if let site = shell.siteName {
            lines.append("What they are looking at: \(title), at \(site), in \(browser).")
        } else {
            lines.append("What they are looking at: \(title), in \(browser).")
        }
        // THE BROWSER IS ASKING, AND THAT COMES BEFORE THE PAGE. A modal question
        // stands in front of everything below; a brief that listed the page's
        // rows without it would invite acts the page cannot take. The choices
        // are the vocabulary: one of them, said back, is the answer.
        if let dialog = shell.dialog {
            lines.append(
                "\(dialog.spoken) Until it is answered nothing on the page can be read or "
                + "pressed; a choice said back — through click_on_page — answers it.")
            return lines.joined(separator: "\n")
        }
        if let roster, !roster.actionable.isEmpty {
            // HOW THE PAGE IS LAID OUT, BEFORE WHAT IS ON IT.
            //
            // PIN: THE BRIEF IS THE VOCABULARY, AND THAT IS THE WHOLE POINT.
            // A person who cannot see the page has to be told its SHAPE before
            // any of the words they would naturally point with mean anything —
            // "the search box at the top", "the third link in the sidebar". This
            // sentence names exactly the places `PageRegion.named(in:among:)`
            // will accept back, so what Mary says the page looks like and what
            // she can be asked about it are the same list. A brief that
            // described the page in words the resolver did not take would invite
            // requests it then had to refuse.
            if let landscape = PageListing.landscape(roster) { lines.append(landscape) }
            let tail = PageListing.tail(roster)
            if !tail.isEmpty {
                lines.append(ageWords(age).map { "Read \($0). \(tail)" } ?? tail)
            }
        } else {
            lines.append(
                "I have not read this page yet — read_page lists what is on it, "
                + "and read_page_text reads what it says.")
        }
        return clipped(lines.joined(separator: "\n"), to: standingBudget)
    }

    /// "12 seconds ago" / "3 minutes ago". Nil when there is no reading to date.
    static func ageWords(_ age: TimeInterval?) -> String? {
        guard let age, age >= 0 else { return nil }
        if age < 90 { return "\(Int(age.rounded())) seconds ago" }
        return "\(Int((age / 60).rounded())) minutes ago"
    }

    /// The asked block: the same bearings, plus wherever the words landed.
    public static func surroundings(
        unit: EnclosingUnit?,
        fileName: String?,
        callers: [TraceHit],
        callees: [TraceHit],
        matches: [TraceHit],
        query: String?
    ) -> String? {
        var lines: [String] = []
        if let unit {
            let place = fileName.map { "\($0), " } ?? ""
            lines.append("\(unit.display) — \(place)lines \(unit.startLine) to \(unit.endLine).")
        }
        if !callers.isEmpty {
            lines.append("Reached from:")
            lines.append(contentsOf: callers.map(line))
        }
        if !callees.isEmpty {
            lines.append("It reaches:")
            lines.append(contentsOf: callees.map(line))
        }
        if !matches.isEmpty {
            let about = query.map { " for \"\($0)\"" } ?? ""
            lines.append("Elsewhere in the project\(about):")
            lines.append(contentsOf: matches.map(line))
        }
        // A unit line alone is a receipt, not evidence — say nothing instead.
        guard callers.count + callees.count + matches.count > 0 else { return nil }
        return clipped(lines.joined(separator: "\n"), to: surroundingsBudget)
    }

    /// Whole lines only: a bearing cut mid-path is worse than one fewer.
    static func clipped(_ text: String, to budget: Int) -> String {
        guard text.count > budget else { return text }
        var kept: [String] = []
        var spent = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let cost = line.count + 1
            guard spent + cost <= budget else { break }
            kept.append(String(line))
            spent += cost
        }
        return kept.joined(separator: "\n")
    }
}
