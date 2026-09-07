//
//  TripScoreboard.swift
//  MaryPlugin
//
//  WHAT: What a round found, per category and per layer, as a table.
//  IN:   the recordings a round wrote
//  OUT:  docs/browsing-trips.md; the probe's --score
//  PIN:  A ROUND ENDS WITH A NUMBER OR IT DID NOT END. The engine is "proper"
//        when the scoreboard says so — that is the whole of the exit criterion —
//        and a round whose findings live in somebody's terminal scrollback
//        cannot be compared with the round before it.
//        COUNTED BY LAYER, BECAUSE THE LAYERS ARE THE WORK. Twelve failures that
//        are all `P` is one detector afternoon in VisionAX; twelve spread across
//        five layers is five different arguments. The shape of the column is the
//        plan for the next round.
//        PENDING IS NOT PASSING AND NOT FAILING. A corpus authored ahead of the
//        engine has legs that cannot run yet, and folding them into either
//        column would either flatter the round or condemn it.
//

import Foundation

public struct TripScoreboard: Sendable {

    /// One category's column.
    public struct Row: Sendable, Equatable {
        public var category: String
        public var passed: Int
        public var failed: Int
        public var pending: Int
        public var unstageable: Int
        /// Legs this runner cannot answer for — the other one does.
        public var unmeasured: Int = 0
        /// How many failures each layer owns.
        public var byLayer: [TripFailureLayer: Int]

        public var total: Int { passed + failed + pending + unstageable + unmeasured }
        /// Of the legs that could run, how many passed.
        public var rate: Double {
            let live = passed + failed
            return live == 0 ? 0 : Double(passed) / Double(live)
        }
    }

    public var rows: [Row]
    public var recordedAt: Date
    public var round: String

    public init(rows: [Row] = [], recordedAt: Date = Date(), round: String = "0") {
        self.rows = rows
        self.recordedAt = recordedAt
        self.round = round
    }

    // MARK: - Counting

    public static func score(
        _ recordings: [TripRecording], round: String? = nil
    ) -> TripScoreboard {
        var byCategory: [String: Row] = [:]
        for recording in recordings {
            var row = byCategory[recording.category]
                ?? Row(category: recording.category, passed: 0, failed: 0,
                       pending: 0, unstageable: 0, byLayer: [:])
            for leg in recording.legs {
                switch leg.verdict {
                case .passed: row.passed += 1
                case .failed:
                    row.failed += 1
                    if let layer = leg.layer {
                        row.byLayer[layer, default: 0] += 1
                    }
                case .pending: row.pending += 1
                case .unstageable: row.unstageable += 1
                case .unmeasured: row.unmeasured += 1
                }
            }
            byCategory[recording.category] = row
        }
        return TripScoreboard(
            rows: byCategory.values.sorted { $0.category < $1.category },
            round: round ?? recordings.first?.round ?? "0")
    }

    // MARK: - Reading it

    public var totals: Row {
        var total = Row(
            category: "all", passed: 0, failed: 0, pending: 0, unstageable: 0,
            byLayer: [:])
        for row in rows {
            total.passed += row.passed
            total.failed += row.failed
            total.pending += row.pending
            total.unstageable += row.unstageable
            total.unmeasured += row.unmeasured
            for (layer, count) in row.byLayer {
                total.byLayer[layer, default: 0] += count
            }
        }
        return total
    }

    /// THE EXIT CRITERION, ASKED OF ONE ROUND. Categories 1–7 at ninety per cent
    /// or better, every `context` ambient and speech expectation met, and no
    /// page-routing failures left on the recorded corpus. Two rounds in a row
    /// answering yes is what ends the cycle; one round cannot say that, so this
    /// answers for itself alone.
    public func meetsExitCriterion() -> (met: Bool, because: [String]) {
        var problems: [String] = []

        // A ROUND THAT COULD NOT RUN IS NOT A ROUND THAT PASSED.
        //
        // PIN: MEASURED, ON THE FIRST LIVE RUN OF THIS FILE. Seven trips came
        // back unstageable for want of an address and one leg passed, and this
        // reported the exit criterion MET — a rate computed over the legs that
        // ran says nothing about the ones that could not, and "100% of one" is
        // the same silence as a corpus that shrinks to nothing and stays green.
        let total = totals
        let live = total.passed + total.failed
        if live == 0 {
            problems.append("nothing ran — every leg was pending or unstageable")
        } else if total.unstageable > live {
            problems.append(
                "\(total.unstageable) leg(s) unstageable against \(live) that ran"
                    + " — stage the machine before reading this table")
        }
        let silent = rows.filter { $0.passed + $0.failed == 0 }.map(\.category)
        if !silent.isEmpty {
            problems.append(
                "no leg ran in " + silent.sorted().joined(separator: ", "))
        }
        // AND EVERY CATEGORY THE CORPUS HAS MUST BE IN THE TABLE AT ALL. A round
        // that never opened a category cannot be compared with one that did.
        let missing = BrowsingTrip.categories.subtracting(rows.map(\.category))
        if !missing.isEmpty {
            problems.append(
                "no recordings at all for " + missing.sorted().joined(separator: ", "))
        }

        let workingCategories = rows.filter { $0.category != "context" }
        for row in workingCategories where row.rate < 0.9 && (row.passed + row.failed) > 0 {
            problems.append(
                "\(row.category) at \(percent(row.rate)) — under 90%")
        }
        if let context = rows.first(where: { $0.category == "context" }),
           context.failed > 0 {
            problems.append("context has \(context.failed) failing leg(s)")
        }
        let routing = totals.byLayer[.pageRouting] ?? 0
        if routing > 0 {
            problems.append("\(routing) page-routing failure(s) on the recorded corpus")
        }
        return (problems.isEmpty, problems)
    }

    func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    // MARK: - The table

    /// The Markdown a round writes into `docs/browsing-trips.md`.
    public func markdown() -> String {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withFullDate]
        var lines: [String] = []
        lines.append("### Round \(round) — \(stamp.string(from: recordedAt))")
        lines.append("")
        lines.append("| Category | Passed | Failed | Pending | Unstageable | Rate | Layers |")
        lines.append("|---|---:|---:|---:|---:|---:|---|")
        for row in rows {
            lines.append(
                "| \(row.category) | \(row.passed) | \(row.failed) | \(row.pending) "
                    + "| \(row.unstageable) | \(percent(row.rate)) | \(layers(row)) |")
        }
        let total = totals
        lines.append(
            "| **all** | **\(total.passed)** | **\(total.failed)** | **\(total.pending)** "
                + "| **\(total.unstageable)** | **\(percent(total.rate))** "
                + "| \(layers(total)) |")
        lines.append("")
        let exit = meetsExitCriterion()
        if exit.met {
            // ONE ROUND IS NOT THE CRITERION, AND SAYING SO IS THE POINT.
            //
            // PIN: THE DOCTRINE SAYS "ON TWO CONSECUTIVE ROUNDS" AND THIS
            // MEASURED ONE. Three whole-corpus samples of the same build came
            // back 77, 72 and 74 — the spread is a live page changing under a
            // live read, and a criterion satisfied by whichever sample was run
            // last is a criterion about luck. A scoreboard cannot see the
            // previous round; what it can do is refuse to call a single sample
            // the answer, and name what is still owed.
            lines.append(
                "Every check passed for this round. The exit criterion asks for TWO"
                    + " consecutive rounds — run it again before claiming it.")
        } else {
            lines.append("Exit criterion not met: " + exit.because.joined(separator: "; ") + ".")
        }
        return lines.joined(separator: "\n")
    }

    func layers(_ row: Row) -> String {
        let named = TripFailureLayer.allCases.compactMap { layer -> String? in
            guard let count = row.byLayer[layer], count > 0 else { return nil }
            return "\(layer.rawValue) \(count)"
        }
        return named.isEmpty ? "—" : named.joined(separator: " · ")
    }

    /// Replace the round's section in a document, or append it.
    ///
    /// PIN: ONE SECTION PER ROUND, REWRITTEN IN PLACE. A scoreboard that only
    /// ever appends grows a second table for round 0 every time somebody re-runs
    /// it, and the file stops saying what the round found.
    ///
    /// AND ONLY ITS OWN. The section this rewrites is the one it wrote — the
    /// heading with the DATE after the dash. Measured: round 8's narrative was
    /// headed "### Round 8 — the revision …", the writer matched the prefix,
    /// and two hundred and seventy-eight lines of what the round found were
    /// replaced by its table.
    public func merged(into document: String) -> String {
        var lines = document.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { Self.isScoreHeading($0, round: round) }) else {
            let separator = document.hasSuffix("\n") ? "" : "\n"
            return document + separator + "\n" + markdown() + "\n"
        }
        var end = start + 1
        while end < lines.count, !lines[end].hasPrefix("### "), !lines[end].hasPrefix("## ") {
            end += 1
        }
        lines.replaceSubrange(start..<end, with: markdown().components(separatedBy: "\n") + [""])
        return lines.joined(separator: "\n")
    }

    /// `### Round N — YYYY-MM-DD`, exactly — a heading somebody wrote a
    /// sentence after is theirs.
    static func isScoreHeading(_ line: String, round: String) -> Bool {
        let prefix = "### Round \(round) — "
        guard line.hasPrefix(prefix) else { return false }
        let rest = line.dropFirst(prefix.count)
        return rest.count == 10 && rest.enumerated().allSatisfy { index, character in
            (index == 4 || index == 7) ? character == "-" : character.isNumber
        }
    }
}
