//
//  AmbientRanking+ThreeWayRule.swift
//  MaryAmbient
//
//  WHAT: User's three-way ordering rule over places (not worlds).
//  IN:   AmbientRanker
//  OUT:  prompt assembly
//  PIN:  Transform branch first — exception to focused-world priority.
//

import Foundation

extension AmbientRanker {

    // MARK: - The three-way rule

    /// THE SAME RULE OVER PLACES, and the one the live callers use. It had to widen with the
    /// worlds. PIN: transform branch first — exception to focused-world priority.
    public static func mode(
        utterance: String, focusedPlace: AmbientPlace?
    ) -> AmbientRankingMode {
        guard let focusedPlace else { return .relevance }
        let named = namedPlacesForRanking(in: utterance)
        if namesTransform(utterance), !named.isEmpty, !named.contains(focusedPlace) {
            return .transformUnfocused
        }
        return concernsFocusedPlace(utterance: utterance, focusedPlace: focusedPlace)
            ? .focusedWorld : .relevance
    }

    /// The places an utterance names, for the ranking rule. Private to it: `namedPlaces` is the
    /// admission ladder's spelling and deliberately keeps its own shape. A REGISTRATION THAT
    /// NAMES ITSELF STANDS DOWN THE CUE'S GUESS. A discipline cue admits every place.
    static func namedPlacesForRanking(in utterance: String) -> Set<AmbientPlace> {
        let named = explicitlyNamedPlaces(in: utterance)
            .filter { $0.hasEyes }
        guard named.isEmpty else { return named }
        return namedPlaces(in: utterance).filter { $0.hasEyes }
    }

    /// Does the utterance point at the focused place? Either it NAMES it, or it is DEICTIC —
    /// "this paragraph", "what's on my screen", "right here" — which points at whatever is in
    /// front of the user by definition.
    public static func concernsFocusedPlace(
        utterance: String, focusedPlace: AmbientPlace
    ) -> Bool {
        let named = namedPlacesForRanking(in: utterance)
        if named.contains(focusedPlace) { return true }
        if !named.isEmpty { return false }
        return isDeictic(utterance)
    }

    /// WHICH DISCIPLINE an utterance names, when it names one by cue rather than by
    /// application. Asked of the installed graph — every discipline package's
    /// own authored triggers — rather than of a list of domain words.
    public static func namedDiscipline(in utterance: String) -> WorkspaceFocus? {
        AmbientCapabilityIndexProvider.current.discipline(in: utterance)
    }

    /// Which PLACES an utterance names — `namedWorlds(in:)` as places, unioned with every
    /// registered DYNAMIC application on the installed roster whose profile (title and aliases;
    /// the title IS the display name) the utterance mentions.
    public static func namedPlaces(in utterance: String) -> Set<AmbientPlace> {
        var places = Set<AmbientPlace>()
        // THE DISCIPLINE CUE, RESOLVED BY THE REALM RESOLVER. THIS USED TO BE THE SCAN ITSELF: a
        // loop over the roster testing one discipline, collapsed into this set and forgotten. It
        // was a realm computed inline over a two-value need.
        if let discipline = namedDiscipline(in: utterance) {
            let realm = AmbientRealmResolver.candidates(
                for: AmbientNeed(discipline: discipline),
                .init(utterance: utterance, discipline: discipline))
            for candidate in realm where candidate.hasEyes && candidate.conformsByDiscipline {
                places.insert(candidate.place)
            }
        }
        // NO `legacyAttention == nil` FILTER. It read as "a native place never discriminates a lane
        // inside its own world", which was true while every projecting registration WAS the
        // compiled world it projected onto.
        for registration in AmbientApplicationIndexProvider.current.all
        where registration.profile.isMentioned(in: utterance) {
            places.insert(registration.place)
        }
        return places
    }

    /// Places this turn's words re-admit. Shared by AbilityRuntime roster
    /// scoping and prompt fragment suppression.
    /// STEPS: route.namedPlaces → referent's world → watched display-name hit
    ///        → Xcode if the words carry a coding cue → real-work evidence.
    public static func admittedPlaceMentions(
        route: AmbientRoute?,
        referent: ResolvedReferent?,
        utterance: String,
        glanced: Set<AmbientPlace> = WorkspaceFocusTracker.shared.signal().glanced,
        evidence: [AmbientPlace: FocusEvidence] = WorkspaceFocusTracker.shared.freshEvidence()
    ) -> Set<AmbientPlace> {
        var admitted: Set<AmbientPlace> = []
        if let route {
            admitted.formUnion(route.namedPlaces)
        } else {
            admitted.formUnion(
                namedPlaces(in: utterance).filter { $0.application != nil })
        }
        if let referent {
            admitted.insert(referent.place)
        }
        // Rung 4 — the words themselves, answered by the roster.
        admitted.formUnion(namedPlaces(in: utterance))
        // Rung 5 — GLANCED places (a fresh look_at_screen at that app).
        admitted.formUnion(glanced)
        // Rung 6 — REAL-WORK places: the user was just there, whether or not
        // it is frontmost now. The same warrant `stickyLead` reads for the
        // prompt, applied here to the roster.
        admitted.formUnion(evidence.values.filter { $0.kind == .activity }.map(\.place))
        return admitted
    }

    /// THE PLACES THE USER ACTUALLY NAMED.
    public static func explicitlyNamedPlaces(
        in utterance: String
    ) -> Set<AmbientPlace> {
        var places = Set<AmbientPlace>()
        for registration in AmbientApplicationIndexProvider.current.all
        where registration.profile.isMentioned(in: utterance) {
            places.insert(registration.place)
        }
        return places
    }

    /// Deixis: the utterance points at what is in front of the user rather than naming it. Kept
    /// small and word-bounded — a wide list here would make every turn "about the focused
    /// world" and quietly retire the relevance default.
    public static func isDeictic(_ utterance: String) -> Bool {
        // Normalize punctuation into token boundaries before phrase matching.
        let tokens = utterance.lowercased().split {
            !$0.isLetter && !$0.isNumber && $0 != "'"
        }
        let text = " " + tokens.joined(separator: " ") + " "
        let phrases = [
            " this ", " these ", " here ", " right here ",
            " on screen", " on my screen", " on the screen",
            " in front of me", " looking at", " i'm reading", " im reading",
            " what i just ", " currently open", " open right now",
            " what i highlighted", " what i've highlighted", " what i have highlighted",
            " what i selected", " what i've selected", " what i have selected",
        ]
        return phrases.contains { text.contains($0) }
            || referencesSelection(utterance)
    }

    /// Whether this utterance can inherit the last explicitly resolved application without
    /// pretending that a generic pronoun is a text selection.
    public static func referencesApplicationAnaphorically(
        _ utterance: String
    ) -> Bool {
        var tokens = utterance.lowercased().split {
            !$0.isLetter && !$0.isNumber && $0 != "'"
        }.map(String.init)
        let text = " " + tokens.joined(separator: " ") + " "
        if [
            " that app ", " the app ", " same app ",
            " that application ", " the application ", " same application ",
        ].contains(where: { text.contains($0) }) {
            return true
        }
        // Location questions are the bounded conversational continuation from “create it in
        // Sketch” to “Where is it?”.
        if tokens.first == "where", tokens.contains("it") { return true }

        while let first = tokens.first,
              ["and", "then", "please", "just"].contains(first) {
            tokens.removeFirst()
        }
        if tokens.count >= 2,
           EditIntentClassifier.requestFrames.contains([tokens[0], tokens[1]]) {
            tokens.removeFirst(2)
            if tokens.first == EditIntentClassifier.politeTail {
                tokens.removeFirst()
            }
        }
        // TWO VOCABULARIES FOR ONE IDEA, and the gap between them was a bug. These were the
        // CREATION verbs only.
        let continuationVerbs: Set<String> = [
            "add", "create", "do", "draw", "make", "move", "place", "put",
            "resize", "rename", "show",
            // The transform family — same words `namesTransform` matches.
            "rewrite", "revise", "edit", "change", "fix", "tighten",
            "shorten", "expand", "polish", "reword", "rephrase", "proofread",
            "correct", "refactor", "replace", "delete", "remove", "insert",
            "append", "translate", "reformat", "format", "tidy", "update",
        ]
        guard let verb = tokens.first, continuationVerbs.contains(verb) else {
            return false
        }
        // "HERE" JOINS THE OBJECTS, and its absence was a real miss: "can you add a draft here" is
        // the continuation shape this function exists to catch, and it returned false.
        return tokens.dropFirst().contains(where: {
            ["it", "there", "another", "here", "this", "that"].contains($0)
        })
    }

    /// Explicit references to the source-owned selection Interaction.
    public static func referencesSelection(_ utterance: String) -> Bool {
        let tokens = utterance.lowercased().split {
            !$0.isLetter && !$0.isNumber && $0 != "'"
        }
        let selectionWords: Set<Substring> = [
            "highlight", "highlighted", "selection", "selected",
        ]
        if tokens.contains(where: selectionWords.contains) { return true }
        let text = " " + tokens.joined(separator: " ") + " "
        return [
            " the part ", " that part ", " this part ",
            " the passage ", " that passage ", " this passage ",
        ].contains { text.contains($0) }
    }

    /// The verbs that TRANSFORM rather than ask. Deliberately excludes pure reading verbs
    /// ("read", "show", "what does it say") — reading an unfocused world is a question about
    /// it, not a transformation of it, and the user's rule names transformation specifically.
    public static func namesTransform(_ utterance: String) -> Bool {
        let text = " " + utterance.lowercased() + " "
        let verbs = [
            "rewrite", "rewriting", "revise", "revising", "edit", "editing",
            "change", "changing", "fix", "fixing", "tighten", "tightening",
            "shorten", "shortening", "expand", "expanding", "polish",
            "reword", "rephrase", "proofread", "proof-read", "correct",
            "refactor", "rename", "replace", "delete", "remove", "insert",
            "add ", "append", "translate", "reformat", "format", "clean up",
            "tidy", "update", "make it", "turn it into",
        ]
        return verbs.contains { text.contains(" \($0)") }
    }

}
