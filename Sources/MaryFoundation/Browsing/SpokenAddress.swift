//
//  SpokenAddress.swift
//  MaryFoundation
//
//  WHAT: Where an address the MODEL wrote is allowed to point.
//  IN:   open_location's argument + the turn's utterance
//  OUT:  the address unchanged, or nil
//  PIN:  THE RULE IS PROVENANCE, NOT DEPTH. A host is knowledge — a model may hold
//        "example.com". A path is a claim about someone else's database: nothing the
//        model can read tells it which video, issue or order that identifier names, and
//        a well-shaped invented id opens a page that does not exist. So a deep link is
//        admitted only when the USER said it, and then it is not the model's claim at
//        all. Mary never shows a model a URL — the whole browsing lane speaks site
//        names — which is exactly why the address parameter must not accept one back.
//        REFUSING EVERY DEEP LINK WAS ALSO WRONG. People read links aloud off a page or
//        a message; a rule that cannot tell whose claim it is refuses the honest ones.
//        A HARVESTED ADDRESS NEVER COMES HERE. A link read off the page carries its own
//        provenance; this gate is for authored strings only.
//

import Foundation

public enum SpokenAddress {

    /// A site's front door. Nothing more — deeper is not forbidden, it needs provenance.
    static let frontDoorPaths: Set<String> = ["", "/"]

    /// Below this a path segment is vocabulary rather than identity. "watch", "video"
    /// and "index" turn up in ordinary speech; an identifier does not.
    static let minimumDistinctiveRun = 6

    /// The address as it may be opened, or nil when the model overreached.
    ///
    /// Returned UNCHANGED. Canonicalizing would rewrite what the person asked for, and a
    /// dictated address is the one case where a deep link is legitimate.
    public static func admit(_ value: String, spokenIn utterance: String = "") -> String? {
        // A BARE HOST IS A HOST. "Go to youtube.com" reaches this as
        // `youtube.com`, scheme-less, and was refused as "guessing at that
        // address" — a sentence about provenance, about a value whose
        // provenance was the person's own mouth. The rule is provenance, not
        // spelling: a host the person said is admitted, and the scheme it lacks
        // is the one every front door has. A path is still a claim and still
        // needs to have been spoken.
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.lowercased().hasPrefix("http://"), !trimmed.lowercased().hasPrefix("https://"),
           looksLikeAnAddress(trimmed) {
            return admit("https://" + trimmed, spokenIn: utterance)
        }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        if frontDoorPaths.contains(components.path),
           components.query == nil, components.fragment == nil {
            return value
        }
        return wasSpoken(value, in: utterance) ? value : nil
    }

    /// Did this address come out of the person's own mouth?
    ///
    /// MATCHED ON THE DISTINCTIVE PART, because the two strings never agree literally.
    /// Dictation writes "example dot com slash watch", a paste carries a scheme nobody
    /// said, and recognition drops punctuation. What survives both is the identifying
    /// tail — the id, the issue number, the slug — so that is what is looked for, with
    /// the separators stripped from both sides. False is the safe answer and the
    /// default: a miss costs a sentence, a false positive opens a fabricated page.
    static func wasSpoken(_ value: String, in utterance: String) -> Bool {
        guard !utterance.isEmpty else { return false }
        let heard = collapsed(utterance)
        guard !heard.isEmpty else { return false }
        if heard.contains(collapsed(value)) { return true }
        return distinctiveRuns(of: value).contains { heard.contains($0) }
    }

    /// Lowercased, with everything speech and dictation disagree about removed.
    static func collapsed(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The identifying pieces of a path and query, long enough to be evidence.
    static func distinctiveRuns(of value: String) -> [String] {
        guard let components = URLComponents(string: value) else { return [] }
        let parts = (components.path + " " + (components.query ?? ""))
            .split { !($0.isLetter || $0.isNumber) }
            .map { collapsed(String($0)) }
        return parts.filter { $0.count >= minimumDistinctiveRun }
    }

    /// Whether this address carries a content claim the model could not have read.
    public static func isDeepLink(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else { return false }
        return !frontDoorPaths.contains(components.path)
            || components.query != nil
            || components.fragment != nil
    }

    /// THE REFUSAL, which states the condition and stops.
    ///
    /// No "shall I search instead" tail: read as an instruction, it drives the loop
    /// straight into a search that navigates, and the turn cycles.
    public static func refusal(for value: String) -> String {
        let site = siteWords(value)
        return "I'd be guessing at that address\(site) — I only have a real link when you give me one or when I open it from the page itself."
    }

    /// " for example dot com", or nothing. The host as words, never the URL.
    static func siteWords(_ value: String) -> String {
        guard let host = URLComponents(string: value)?.host, !host.isEmpty else { return "" }
        let stripped = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return " for \(stripped)"
    }

    // MARK: - Searching versus opening

    /// Is this something to TYPE AT A SEARCH ENGINE rather than open as an address?
    ///
    /// PIN: THE ADDRESS BAR TAKES BOTH, and that is the hazard. A browser's address
    /// field searches whatever is not an address and navigates whatever is — so a
    /// one-word query that happens to carry a dot ("example.com") silently becomes a
    /// navigation to a site nobody named. A query with a space is unambiguous; a bare
    /// dotted token is not, and the honest answer is to say which one was meant.
    public static func looksLikeAnAddress(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" ") else { return false }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return true
        }
        guard let dot = trimmed.lastIndex(of: ".") else { return false }
        let tail = trimmed[trimmed.index(after: dot)...]
        // A trailing run of letters after a dot is a top-level domain shape. A trailing
        // number ("3.5") or nothing at all is not.
        return tail.count >= 2 && tail.allSatisfy { $0.isLetter }
    }
}
