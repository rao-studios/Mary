//
//  AmbientRanking+ThreeWayRule.swift
//

import Foundation

extension AmbientRanker {

    // MARK: - The three-way rule

    /// The user's rule, in order. The transform branch is tested FIRST because
    /// it is the stated EXCEPTION to focused-world priority: without it, "fix
    /// the typo in my Scrivener chapter" asked while Pages is focused would
    /// hoist the Pages facts over the chapter the user just named.

    /// THE SAME RULE OVER PLACES, and the one the live callers use.
    ///
    /// It had to widen with the worlds. `namedWorlds` falls back to the CUE
    /// classifier, whose writing arm is the compiled editors — so with the
    /// focused place a taught manuscript application, "fix the typo in my
    /// chapter" named a set the focused place could not be in, and the branch
    /// that exists to protect a named-but-unfocused world fired against the
    /// one the user was actually in. Asking over realms lets a package's own
    /// declared aliases answer, which is where those words live now.
    public static func mode(
        utterance: String, focusedPlace: AmbientRealm?
    ) -> AmbientRankingMode {
        guard let focusedPlace else { return .relevance }
        let named = namedPlacesForRanking(in: utterance)
        if namesTransform(utterance), !named.isEmpty, !named.contains(focusedPlace) {
            return .transformUnfocused
        }
        return concernsFocusedPlace(utterance: utterance, focusedPlace: focusedPlace)
            ? .focusedWorld : .relevance
    }

    /// The places an utterance names, for the ranking rule. Private to it:
    /// `namedRealms` is the admission ladder's spelling and deliberately
    /// keeps its own shape.
    ///
    /// A REGISTRATION THAT NAMES ITSELF STANDS DOWN THE CUE'S GUESS. A
    /// discipline cue admits every place that realizes it, which is a guess
    /// about what the user meant; an actual name is not a guess. Leaving the
    /// cue's places in beside a real name would leave the focused place
    /// "named" by a word the user never said.
    static func namedPlacesForRanking(in utterance: String) -> Set<AmbientRealm> {
        let named = explicitlyNamedRealms(in: utterance)
            .filter { $0.hasEyes }
        guard named.isEmpty else { return named }
        return namedRealms(in: utterance).filter { $0.hasEyes }
    }

    /// Does the utterance point at the focused place? Either it NAMES it, or
    /// it is DEICTIC — "this paragraph", "what's on my screen", "right here" —
    /// which points at whatever is in front of the user by definition. An
    /// utterance that names a DIFFERENT place does not concern this one, and
    /// an utterance that names no place and points at nothing (small talk, a
    /// general question) concerns none at all: relevance decides.
    public static func concernsFocusedPlace(
        utterance: String, focusedPlace: AmbientRealm
    ) -> Bool {
        let named = namedPlacesForRanking(in: utterance)
        if named.contains(focusedPlace) { return true }
        if !named.isEmpty { return false }
        return isDeictic(utterance)
    }

    /// WHICH DISCIPLINE an utterance names, when it names one by cue rather
    /// than by application.
    ///
    /// Bonnie answered this in WORLDS — a `.writing` cue returned Pages and
    /// TextEdit, the compiled writing worlds, and a taught application had no
    /// case and so could never be named by a cue. Mary has no compiled
    /// application worlds to return, so the cue is answered as what it
    /// actually is: a discipline. `namedRealms` below turns that into places
    /// by asking the roster which registrations realize it, which means a
    /// package installed this morning is nameable by cue the same way
    /// anything else is.
    public static func namedDiscipline(in utterance: String) -> WorkspaceFocus? {
        FocusOverride.classifyOverride(utterance: utterance)
    }

    /// Which PLACES an utterance names — `namedWorlds(in:)` as places,
    /// unioned with every registered DYNAMIC application on the installed
    /// roster whose profile (title and aliases; the title IS the display
    /// name) the utterance mentions. Matching COMPOSES
    /// `ApplicationProfile.isMentioned`, the exact matcher the intent gate
    /// already runs, rather than inventing a second spelling of "did the
    /// user name it". Native registrations contribute through their world —
    /// a native place never discriminates a lane inside its own world.
    public static func namedRealms(in utterance: String) -> Set<AmbientRealm> {
        var places = Set<AmbientRealm>()
        // THE DISCIPLINE CUE, resolved through the roster. A "writing" vibe
        // names the writing SIDE without choosing an application, so every
        // registration that realizes it counts as named — which is what lets
        // "not the focused place" still answer correctly when the focus is a
        // coding place and the cue was about writing.
        //
        // EYELESS PLACES STAY OUT, and must. This feeds `mode`, and
        // `mode == .focusedWorld` is a PARTITION: admitting a place nothing
        // is looking at would let "what's on my calendar" hoist calendar
        // facts over the document the user is actually writing in. An
        // eyeless source earns its place by RELEVANCE, never by taking the
        // lead — the same statement as "eyes decide what she perceives, not
        // what she may use", read from the other end.
        if let discipline = namedDiscipline(in: utterance) {
            for registration in AmbientApplicationIndexProvider.current.all
            where registration.hasEyes && registration.place.focus == discipline {
                places.insert(registration.place)
            }
        }
        // NO `legacyWorld == nil` FILTER. It read as "a native place never
        // discriminates a lane inside its own world", which was true while
        // every projecting registration WAS the compiled world it projected
        // onto. A taught application that projects onto one still has aliases
        // of its own, and skipping it meant the package's declared words were
        // matched by nothing — `registration.place` is that world for a native
        // and the guest's own realm otherwise, so the insert is correct either
        // way and the set stays deduplicated.
        for registration in AmbientApplicationIndexProvider.current.all
        where registration.profile.isMentioned(in: utterance) {
            places.insert(registration.place)
        }
        return places
    }

    /// The places this turn's WORDS re-admit — THE ONE MENTIONS LADDER,
    /// shared by the dispatcher's roster scoping
    /// (`AbilityRuntime.admittedRealmMentions`) and the prompt's writing-
    /// fragment suppression, so the schema list and the fragments can never
    /// disagree about what the words re-admitted. Four rungs:
    ///
    ///   1. The route's `namedRealms` — native worlds the classifier heard
    ///      plus every registered application the gate matched by name,
    ///      COMPOSED from the gate's own matches rather than re-matched.
    ///      On a route-less turn the roster matcher contributes registered
    ///      mentions only; native admission keeps rung 3, because widening
    ///      it here would let a route-less turn admit worlds no route ever
    ///      named.
    ///   2. The world of a referent the utterance resolved ("the sourdough
    ///      note").
    ///   3. Any watched world whose display name appears in the words.
    ///   4. Xcode, whenever the words carry a coding cue.
    public static func admittedRealmMentions(
        route: AmbientRoute?,
        referent: ResolvedReferent?,
        utterance: String,
        glanced: Set<AmbientRealm> = WorkspaceFocusTracker.shared.signal().glanced
    ) -> Set<AmbientRealm> {
        var admitted: Set<AmbientRealm> = []
        if let route {
            admitted.formUnion(route.namedRealms)
        } else {
            admitted.formUnion(
                namedRealms(in: utterance).filter { $0.application != nil })
        }
        if let referent {
            admitted.insert(referent.place)
        }
        // Rung 4 — the words themselves, answered by the roster. Bonnie
        // scanned its compiled watched worlds' display names here and then
        // hardcoded Xcode for a coding cue; both are roster questions now,
        // and `namedRealms` is the one place they are asked.
        admitted.formUnion(namedRealms(in: utterance))
        // Rung 5 — GLANCED realms (a fresh look_at_screen at that app). A
        // glance is the user deliberately bringing a place into the
        // conversation, exactly as naming it would; admitting it keeps the
        // glanced app's Skills on the roster and its fragment standing for
        // the handoff turn ("look at that doc → now write it in Pages").
        // Defaulted from the shared tracker so all three consumers of this
        // ladder stay unanimous without threading; a fresh tracker holds no
        // glances, so existing behavior is byte-identical.
        admitted.formUnion(glanced)
        return admitted
    }

    /// THE PLACES THE USER ACTUALLY NAMED — every registration whose package
    /// DECLARED a word the utterance used, and nothing else.
    ///
    /// Bonnie kept a compiled lexicon beside this: literal tests for
    /// `" xcode"`, `" pages"`, `" textedit"`, `" keynote"`. Its own comments
    /// record what that cost — a Scrivener lexicon sat here as a verbatim
    /// copy of that package's declared aliases, in a compiled file no package
    /// could edit, so a second manuscript application could declare its words
    /// and never be matched, while the uninstalled one's words kept firing.
    /// Mary has no compiled lexicon to drift: the words come from the
    /// packages, which is the only place they were ever true.
    ///
    /// Alias matching goes through `ApplicationProfile.isMentioned`, the exact
    /// matcher the intent gate already runs, so "did the user name it" has one
    /// answer and not two.
    public static func explicitlyNamedRealms(
        in utterance: String
    ) -> Set<AmbientRealm> {
        var places = Set<AmbientRealm>()
        for registration in AmbientApplicationIndexProvider.current.all
        where registration.profile.isMentioned(in: utterance) {
            places.insert(registration.place)
        }
        return places
    }

    /// Deixis: the utterance points at what is in front of the user rather
    /// than naming it. Kept small and word-bounded — a wide list here would
    /// make every turn "about the focused world" and quietly retire the
    /// relevance default.
    public static func isDeictic(_ utterance: String) -> Bool {
        // Normalize punctuation into token boundaries before phrase matching.
        // The former space-padding missed the most common spoken/chat shape —
        // a deictic word immediately before punctuation (`this?`) — even
        // though the same word followed by another token (`this line`) worked.
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

    /// Whether this utterance can inherit the last explicitly resolved
    /// application without pretending that a generic pronoun is a text
    /// selection. Application continuity is deliberately separate from
    /// `isDeictic`: making bare “it” selection-deictic would let an unrelated
    /// stale highlight capture turns such as “Where is it?”.
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
        // Location questions are the bounded conversational continuation from
        // “create it in Sketch” to “Where is it?”. A generic `it`, `there`, or
        // `another` is not enough: those words occur constantly in unrelated
        // questions (“what time is it?”, “is there anything else?”).
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
        // TWO VOCABULARIES FOR ONE IDEA, and the gap between them was a bug.
        // These were the CREATION verbs only — the design-canvas shapes this
        // function was first written for — while `namesTransform` twenty lines
        // down already knew the whole edit family. So a turn could be
        // understood as an edit and NOT as a continuation, which is exactly
        // the state "Can we reword this" landed in.
        //
        // THE FAILURE THIS FIXES (live, in the transcript): "update this
        // document in chrome" armed the Chrome referent; the very next turn,
        // "Can we reword this", failed this gate on `reword` alone, inherited
        // nothing, and fell through to a stale writing lead — "I'm looking at
        // the live text in front of you in Scrivener right now". The user had
        // to say "Oh no no I mean chrome".
        //
        // Kept as a literal set rather than calling `namesTransform`: that one
        // scans the whole utterance, and the LEADING-verb property is what
        // keeps "what time is it here" out of this line.
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
        // "HERE" JOINS THE OBJECTS, and its absence was a real miss: "can you
        // add a draft here" is the continuation shape this function exists to
        // catch, and it returned false — so the browser referent armed one
        // turn earlier had nothing to inherit through, and the turn fell to a
        // stale writing lead. Safe for the same reason the others are: a
        // continuation verb must LEAD, so "what time is it here" never
        // reaches this line.
        // "THIS"/"THAT" JOIN THEM for the same reason "here" did, and their
        // absence was the other half of the reword miss: "reword this" and
        // "fix that" are the commonest continuation objects in speech, and
        // neither could reach a referent. Safe on the same argument — the verb
        // must LEAD, so "what is this" and "that's fine" never arrive here.
        return tokens.dropFirst().contains(where: {
            ["it", "there", "another", "here", "this", "that"].contains($0)
        })
    }

    /// Explicit references to the source-owned selection Interaction. Keep
    /// this separate from the broader deixis vocabulary so the turn boundary
    /// can preserve a just-used highlight for a conversational follow-up such
    /// as “yeah, the part I highlighted.” The previous phrase list recognized
    /// only “what I highlighted,” which made the same Interaction disappear
    /// when the user changed the surrounding sentence.
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

    /// The verbs that TRANSFORM rather than ask. Deliberately excludes pure
    /// reading verbs ("read", "show", "what does it say") — reading an
    /// unfocused world is a question about it, not a transformation of it, and
    /// the user's rule names transformation specifically.
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
