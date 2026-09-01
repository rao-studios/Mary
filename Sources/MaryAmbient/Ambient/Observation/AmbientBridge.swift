//
//  AmbientBridge.swift
//  MaryBrain
//
//  WHAT: Watchers' write path into the ambient store — snapshot → facts.
//  IN:   watcher snapshots
//  OUT:  AmbientContextStore.register / replacePerceived. Selection: recordSelection.
//  PIN:  Pure mapping, table-testable. Document poll cannot erase a source-owned selection.
//

import Foundation

public enum AmbientBridge {

    /// Cap on a stored excerpt. IT NO LONGER TRACKS `PagesContextWatcher.excerptCap`, and the
    /// split is deliberate. That number just dropped 800 → 400 because the PROMPT's excerpt
    /// changed job — it is the neighbourhood of the cursor now, under a complete outline.
    public static let excerptCap = 800

    // MARK: - Pages

    // MARK: - TextEdit

    // MARK: - Reads (the dispatcher's write path)

    /// A READ RESULT, registered instead of vanishing. THE fix for the user's complaint: "I
    /// continued the conversation and mary has lost the context of the page and the paragraph
    /// it found earlier." `phrase` is what the read was targeted at.
    public static func readFact(
        attention: AmbientAttention,
        application: String? = nil,
        phrase: String,
        summary: String,
        document: String? = nil,
        passageHandle: String? = nil,
        at now: Date = Date()
    ) -> AmbientFact? {
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !wanted.isEmpty else { return nil }
        let parsed = parseBounds(in: text)
        return AmbientFact(
            attention: attention, application: application,
            slot: .read(wanted, in: document),
            content: text,
            subject: parsed.subject,
            bounds: parsed.bounds,
            documentTotal: parsed.total,
            provenance: .recipeRead,
            registration: .askedFor,
            capturedAt: now,
            passageHandle: passageHandle)
    }

    /// Pull `Name — characters 12927–13835 of 15775` back out of a read's own bounds label.
    public static func parseBounds(
        in summary: String
    ) -> (subject: String?, bounds: Range<Int>?, total: Int?) {
        // DEFENSIVE, and it defends the SUBJECT rather than the numbers.
        let head = stripLeadingHandle(summary.components(separatedBy: "\n").first ?? summary)
        var subject: String?
        if let dash = head.range(of: " — ") {
            let name = String(head[head.startIndex..<dash.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { subject = name }
        }
        guard let regex = try? NSRegularExpression(
            pattern: "characters\\s+(\\d+)[–-](\\d+)\\s+of\\s+(\\d+)"),
            let match = regex.firstMatch(
                in: head, range: NSRange(head.startIndex..<head.endIndex, in: head)),
            match.numberOfRanges == 4,
            let lowerRange = Range(match.range(at: 1), in: head),
            let upperRange = Range(match.range(at: 2), in: head),
            let totalRange = Range(match.range(at: 3), in: head),
            let lower = Int(head[lowerRange]), let upper = Int(head[upperRange]),
            let total = Int(head[totalRange]),
            lower <= upper
        else { return (subject, nil, nil) }
        return (subject, lower..<upper, total)
    }

    /// `"[S1] Essay — …"` → `"Essay — …"`. Only a WELL-FORMED handle at the very front is
    /// removed: the prefix letter `PassageRegistry.handlePrefix` followed by digits, in
    /// brackets, followed by a space. Deliberately not "drop everything up to the first `]`".
    public static func stripLeadingHandle(_ line: String) -> String {
        let prefix = PassageRegistry.handlePrefix.lowercased()
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
              line.index(after: close) < line.endIndex,
              line[line.index(after: close)] == " "
        else { return line }
        let inner = line[line.index(after: line.startIndex)..<close]
        guard inner.lowercased().hasPrefix(prefix),
              !inner.dropFirst(prefix.count).isEmpty,
              inner.dropFirst(prefix.count).allSatisfy(\.isNumber)
        else { return line }
        return String(line[line.index(close, offsetBy: 2)...])
    }
}
