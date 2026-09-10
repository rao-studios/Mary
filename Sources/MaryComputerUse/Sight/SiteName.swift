//
//  SiteName.swift
//  MaryComputerUse
//
//  WHAT: The site a URL belongs to, as a person would say it.
//  IN:   a shell reading's address; a page row's own link
//  OUT:  spoken summaries; the site a row belongs to, at the seal
//  PIN:  A URL IS HELD, NEVER SPOKEN. Reading an address aloud is unusable as speech
//        and leaks query strings into a transcript; the site's name is what a person
//        actually asked about. Pure derivation, no table — a site is named by its host,
//        not by anything here knowing what the site is.
//

import Foundation

public enum SiteName {

    /// Host labels that name a registry rather than a site, so the label before them
    /// is the one worth saying.
    static let genericLabels: Set<String> = [
        "com", "org", "net", "co", "io", "gov", "edu", "ac", "uk", "us", "app", "dev",
        "www", "m", "en", "www2",
    ]

    /// The host of a URL, or nil when it has none.
    public static func host(url: String) -> String? {
        if let parsed = URL(string: url)?.host, !parsed.isEmpty { return parsed }
        // A user-typed address without a scheme still has a host.
        guard let parsed = URL(string: "https://\(url)")?.host, !parsed.isEmpty else { return nil }
        return parsed
    }

    /// The words a host is made of, registry and www stripped.
    public static func words(host: String) -> [String] {
        host.lowercased()
            .split(separator: ".")
            .map(String.init)
            .filter { !genericLabels.contains($0) }
    }

    /// What to call the site: "youtube", "ycombinator news", "google docs".
    public static func spoken(url: String) -> String? {
        guard let host = host(url: url) else { return nil }
        let words = words(host: host)
        guard !words.isEmpty else { return host }
        // Reversed, because a host reads right to left: `docs.google.com` is Google Docs.
        return words.reversed().joined(separator: " ")
    }
}
