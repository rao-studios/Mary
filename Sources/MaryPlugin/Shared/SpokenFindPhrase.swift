//
//  SpokenFindPhrase.swift
//  MaryPlugin
//
//  WHAT: "Find the word budget on this page" — the words to look for, out of
//        the sentence that asked.
//  IN:   the span the lane hands a find verb
//  OUT:  the browsing adapter's find_in_page
//  PIN:  THE VERB'S OWN ENGLISH, NOT A PAGE'S. What is stripped is how a person
//        asks to find something — the asking verb, "the word", "the phrase",
//        "on this page" — never a word a page might carry. What survives is
//        what they want highlighted, quotes and all removed.
//

import Foundation

public enum SpokenFindPhrase {

    static let askingVerbs = [
        "where does it say", "where does it mention", "where is", "look for",
        "search for", "search", "find", "locate", "highlight", "show me",
    ]
    static let framing = ["the word", "the phrase", "the words", "the term", "for"]
    static let trailing = [
        "on this page", "in this page", "on the page", "in the page", "on this site",
        "here", "for me", "please",
    ]

    /// The words to find, or nil when nothing is left once the asking is removed.
    public static func needle(in phrase: String) -> String? {
        var text = phrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!"))
        let lower = { text.lowercased() }
        for tail in trailing where lower().hasSuffix(" " + tail) || lower() == tail {
            text = String(text.dropLast(tail.count)).trimmingCharacters(in: .whitespaces)
        }
        for verb in askingVerbs where lower().hasPrefix(verb + " ") || lower() == verb {
            text = String(text.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        for frame in framing where lower().hasPrefix(frame + " ") || lower() == frame {
            text = String(text.dropFirst(frame.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ "))
        return text.isEmpty ? nil : text
    }
}
