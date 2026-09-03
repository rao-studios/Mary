//
//  MaryBrain+Vocabulary.swift
//  MaryBrain
//
//  WHAT: Deterministic spoken/filed sentences.
//  IN:   routines / finish / confirm
//  OUT:  stalledLine / couldNotActLine / confirmQuestion / …
//  PIN:  Wording is spoken verbatim — do not casual-edit.
//
import MaryVoice
import Foundation

extension MaryBrain {

    /// Spoken label for the busy note and stop ack — the user's own words, clipped.
    static func routineLabel(from userText: String) -> String {
        let words = userText.split(whereSeparator: \.isWhitespace).prefix(8)
        let clipped = words.joined(separator: " ")
        return clipped.isEmpty ? "that request" : clipped
    }

    /// Stall sentence — one wording, four callers (watchdog, attached-lane bound, action-retry bound).
    static func stalledLine(label: String) -> String {
        "That one stalled — \(label) never came back, so I stopped waiting. Ask me again and I'll retry."
    }

    /// Deterministic "put that in at your cursor" sentence.
    static func wroteOfferedProseLine(place: String?) -> String {
        guard let place, !place.isEmpty else {
            return "Done — I've put that in at your cursor."
        }
        return "Done — I've put that into \(place) at your cursor."
    }

    /// Could-not-write sentence. `detail` is the typer's own reason.
    static func couldNotWriteOfferedProseLine(detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "I couldn't put that on the page, so nothing has changed."
        }
        return "I couldn't put that on the page — \(trimmed)"
    }

    static func couldNotActLine(label: String) -> String {
        "I couldn't work out how to do that — \(label). Nothing ran, and I've set that request aside; say it again if you still want it."
    }

    /// Spoken line when a named Dynamic application's provider is unavailable.
    static func providerUnavailableLine(
        applicationID: String,
        snapshot: AbilityRuntime.Snapshot
    ) -> String? {
        guard let profile = snapshot.plugins.applicationProfiles.first(where: {
            $0.id == applicationID
        }) else { return nil }
        // Resolve only manifests belonging to this exact application.
        let manifests = snapshot.plugins.adapterManifests.filter {
            $0.resolvedProvider.applicationID == applicationID
        }
        guard !manifests.isEmpty else { return nil }
        guard manifests.allSatisfy({ !$0.isAvailable }) else { return nil }
        let reason = manifests.compactMap(\.unavailableReason).first
            ?? "its local operator is unavailable"
        if reason.lowercased().contains(PermissionKind.accessibility.rawValue) {
            return "\(profile.title)'s Ability is active, but Mary needs macOS Accessibility access before she can operate it. Allow Mary in System Settings → Privacy & Security → Accessibility."
        }
        return "\(profile.title)'s Ability is active, but its Dynamic Plugin is unavailable: \(reason)"
    }

    static func couldNotReplaceSelectionLine() -> String {
        "I couldn't apply that revision to the selection in its source app."
    }

    /// File a deterministic sentence onto the transcript, whatever the ear was told.
    static func filed(_ text: String, _ sentence: String) -> String {
        let lead = sentence.hasPrefix(" ") ? String(sentence.dropFirst()) : sentence
        guard !lead.isEmpty else { return text }
        return text.isEmpty ? lead : text + " " + lead
    }

    /// The routine's own duration, said the way a duration is said.
    static func spokenDuration(since spawn: DispatchTime) -> String {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- spawn.uptimeNanoseconds
        return String(format: "%.1fs", Double(elapsed) / 1_000_000_000)
    }


    /// Elapsed milliseconds, unrounded — lane log, compared against the 250 ms join grace.
    static func elapsedMs(since start: DispatchTime) -> UInt64 {
        (DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }

    /// Fold case, punctuation, and whitespace so spoken and echoed window acks compare equal.
    static func normalizedForEcho(_ text: String) -> String {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { out, ch in
                if ch == " ", out.hasSuffix(" ") { return }
                out.append(ch)
            }
            .trimmingCharacters(in: .whitespaces)
    }

    /// True when the candidate says nothing the baseline hasn't — containment, not equality.
    static func addsNothing(_ candidate: String, over baseline: String) -> Bool {
        let folded = normalizedForEcho(candidate)
        guard !folded.isEmpty else { return true }
        return normalizedForEcho(baseline).contains(folded)
    }

    /// Capped epilogue a silently-settled routine leaves in history.
    static func doneMarker(outcomes: [LaneOutcome]) -> String {
        let skills = outcomes.map(\.skillName).joined(separator: ", ")
        // Honest tense over the whole outcome list.
        let verb: String
        if outcomes.contains(where: { !$0.ok }) {
            verb = "couldn't"
        } else if outcomes.contains(where: \.deferred) {
            verb = "started"
        } else {
            verb = "done"
        }
        let brief = (outcomes.first?.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = brief.count > 160 ? String(brief.prefix(160)) + "…" : brief
        return capped.isEmpty ? "(\(verb): \(skills))" : "(\(verb): \(skills) — \(capped))"
    }

    /// "CONFIRM: <question>" → the question; falls back to a generic ask.
    static func confirmQuestion(fromOutcomes summaries: [String]) -> String {
        for summary in summaries.reversed() {
            guard let range = summary.range(of: "CONFIRM:") else { continue }
            let question = summary[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !question.isEmpty { return question }
        }
        return "There's an action waiting for your approval — should I go ahead?"
    }
}
