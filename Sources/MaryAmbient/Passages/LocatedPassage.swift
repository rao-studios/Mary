//
//  LocatedPassage.swift
//  MaryBrain
//
//  WHAT SHE IS ALREADY HOLDING WHEN A TURN TURNS OUT TO BE A REVISION — the
//  passage the user named, found BEFORE the Skill execution lane opens its mouth, so the
//  choice between composing and revising is made against something real.
//
//  THE LIVE FAILURE, in the user's words. In Pages: "replace the Purpose
//  section with the tighter version." She called `type_at_cursor`, typed the
//  new prose wherever the caret happened to be, and left the Purpose section
//  standing. Their own diagnosis: "intended for live writing behavior rather
//  than revision behavior."
//
//  The verb to do it properly already exists — `replace_passage` changes a
//  located passage where it sits. This type is about her CHOOSING it. The
//  doctrine this tree keeps arriving at is MECHANICAL GATES OVER PROMPT
//  BEGGING: `ActionClassifier`, `bareDecision` and `hasPendingSkillConfirmation` were each
//  introduced because an instruction the model ignored had to become a
//  mechanism it could not. A gate needs a FACT to stand on — a handle, minted,
//  resolvable, in hand before the lane runs — and this is that fact.
//
//  NIL IS A FIRST-CLASS ANSWER AND A COMMON ONE. No passage located means no
//  gate fires, the lane does exactly what it would have done without any of
//  this, and the report says plainly that she could not find it. That is the
//  same bound `readNamedPart`'s nil already provides: an over-eager
//  classification with nothing in view costs nothing at all.
//
//  IT NEVER STOPS TO ASK. "Ambiguous/missing target → read wider, then decide
//  alone" is the user's own fixed decision, so `widened` exists to say WHEN we
//  decided for them — which is what entitles the report to offer a way back.
//

import Foundation

/// A passage found for a revision turn, and everything the gates downstream
/// need to act on it without re-deriving any of it.
///
/// Deliberately FLAT and Sendable-by-value: this crosses from the dispatcher
/// into the brain's turn state, and a reference to live app machinery would
/// make "the thing she is holding" mean something different by the time it was
/// read.
public struct LocatedPassage: Sendable, Equatable {

    /// THE COMPACT FORM, for the two places a gate has to speak.
    ///
    /// Deterministic prose, built here, never model prose — `EditReport`'s rule
    /// and for `EditReport`'s reason: the sentence that redirects a wrong Skill
    /// call must say the same thing every time, or the redirect becomes one
    /// more thing the model gets to interpret.
    public struct Brief: Sendable, Equatable {
        /// ONE LINE INTO THE SKILL EXECUTION LANE'S PROMPT. Turn-scoped, appended the way
        /// `orchestratorAddendum` and `actionRetryNudge` already are — so it
        /// costs nothing against the standing prompt budget and disappears with
        /// the turn that needed it.
        public var line: String
        /// THE SYNTHETIC SKILL RESULT the revision veto answers a caret-write
        /// with. It opens by saying nothing was typed, because a Skill result
        /// that only scolds reads to a small model as a failure it should
        /// retry — and the retry is the same wrong call again.
        public var redirect: String

        public init(line: String, redirect: String) {
            self.line = line
            self.redirect = redirect
        }
    }

    /// `S1`, bare — the registry's own spelling. Bracketed only where it is
    /// SHOWN (`[S1]`), never where it is compared, because a model writes it
    /// back four different ways and `PassageRegistry.resolve` is the one thing
    /// that normalizes them.
    public var handle: String
    /// Which place the document lives in. Eyes-bearing by construction: a
    /// passage cannot be minted for anything else (`Passage.init?`).
    public var place: AmbientPlace
    /// What to CALL the document out loud. Display only, never an identity —
    /// the identity is on the `Passage` the handle resolves to.
    public var documentTitle: String
    /// The passage's own words, whole. The consumer decides how much of it to
    /// spend; the brief already carries a bounded form for the prompt.
    public var text: String
    /// HOW BIG IT IS, IN WORDS. Not offsets, and that is the standing rule
    /// rather than a preference here: `characters 68–916 of 916` reached the
    /// model through exactly this kind of field, and no primitive anywhere
    /// accepted an end offset. Digits about POSITION stay in the chip, the
    /// AbilityExecutionLog and the ambient fact.
    public var boundsLabel: String
    /// The binding that changes this passage, from the world's own
    /// `targetedEdit` — so nothing upstream of the plugins learns a Skill name.
    public var binding: String
    /// The parameter of `binding` that carries `handle`.
    public var parameter: String
    /// DID WE CHOOSE, OR DID THEIR OWN WORDS? False only when the first thing
    /// they called it matched one thing and matched it whole. Everything else
    /// — a second-choice phrase, a contested pick, a fuzzy rung, the fallback
    /// to what they had selected — is us deciding unattended, which is what the
    /// undo offer in the report is for.
    public var widened: Bool
    public var brief: Brief

    public init(
        handle: String,
        place: AmbientPlace,
        documentTitle: String,
        text: String,
        boundsLabel: String,
        binding: String,
        parameter: String,
        widened: Bool,
        brief: Brief
    ) {
        self.handle = handle
        self.place = place
        self.documentTitle = documentTitle
        self.text = text
        self.boundsLabel = boundsLabel
        self.binding = binding
        self.parameter = parameter
        self.widened = widened
        self.brief = brief
    }

    /// THE ONLY WAY THIS GETS BUILT IN PRODUCTION: from a `Passage` the
    /// registry actually minted, plus the verb the world actually declared.
    ///
    /// Both halves are deliberate. A `LocatedPassage` assembled from loose
    /// strings could name a handle no registry knows — and a handle recovered
    /// from prose is one the model can hallucinate into existence, which is
    /// precisely how `characters 68–916 of 916` came to be quoted at a model
    /// that had nowhere to spend it.
    public init(
        passage: Passage,
        label: String,
        verb: (binding: String, parameter: String),
        widened: Bool
    ) {
        let bounds = Self.boundsLabel(
            kind: passage.unitKind, label: label, text: passage.text)
        self.init(
            handle: passage.handle,
            place: passage.place,
            documentTitle: passage.documentTitle,
            text: passage.text,
            boundsLabel: bounds,
            binding: verb.binding,
            parameter: verb.parameter,
            widened: widened,
            brief: Self.brief(
                handle: passage.handle,
                documentTitle: passage.documentTitle,
                bounds: bounds,
                verb: verb,
                widened: widened))
    }

    // MARK: - The verb

    /// THE ONE SPELLING of "the binding that changes a located passage, and the
    /// parameter that carries the handle".
    ///
    /// It lives at the PLUGIN layer, which is the whole point: the brain asks a
    /// world what its revision verb is and is told; it never learns a Skill name
    /// by hardwiring one, the same discipline `targetedRead` established. That
    /// the binding is registered by `typer` rather than by the world itself is
    /// an ownership detail of `PassageRecipes` — a revision is an ACT, not a
    /// place — and it is invisible from here, exactly as it should be.
    ///
    /// Pinned against `PassageRecipes.skillBindings()` by a test, because a constant
    /// that names a binding in another file is a rename away from being a lie.
    public static let changeVerb: (binding: String, parameter: String) =
        ("replace_passage", "passage")

    // MARK: - Saying how big it is

    /// Below this, the exact count IS the honest answer — "about 8 words" about
    /// eight words is a hedge with nothing to hedge. Twenty is where a person
    /// stops counting and starts estimating.
    public static let exactWordCount = 20

    /// The first few words, for a passage with no name of its own. Six, because
    /// that is enough to recognise a paragraph you wrote and short enough to
    /// sit inside a sentence twice.
    public static let openingWords = 6

    public static func boundsLabel(kind: PassageUnitKind, label: String, text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let counted = words.count <= exactWordCount
            ? words.count
            : Int((Double(words.count) / 10).rounded()) * 10
        let extent = "about \(counted) word\(counted == 1 ? "" : "s")"
        let named = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !named.isEmpty { return "the \(named) \(kind.spokenNoun), \(extent)" }
        let opening = words.prefix(openingWords).joined(separator: " ")
        guard !opening.isEmpty else { return "\(kind.spokenNoun), \(extent)" }
        return "the \(kind.spokenNoun) starting \"\(opening)\", \(extent)"
    }

    // MARK: - The two sentences

    public static func brief(
        handle: String,
        documentTitle: String,
        bounds: String,
        verb: (binding: String, parameter: String),
        widened: Bool
    ) -> Brief {
        let whereItIs = documentTitle.isEmpty ? "" : " in \(documentTitle)"
        let chosen = widened
            ? " I picked it from more than one possible match."
            : ""
        // The lane's prompt line. It names the handle, the verb and the
        // parameter, and then says the ONE thing the shipped failure turned on:
        // the cursor is where NEW words go, not where existing ones are
        // changed. `TyperPlugin.promptFragment` says the same in the standing
        // prompt and was ignored; this says it with a handle attached.
        let line = "The part they mean is already located: [\(handle)] — "
            + "\(bounds)\(whereItIs). Change it with \(verb.binding) "
            + "(\(verb.parameter): \"\(handle)\").\(chosen) "
            + "Typing at the cursor adds new words at the caret; it does not revise this."
        // The veto's Skill result. "Nothing was typed" leads, because a result
        // that reads as a failure gets retried — and the retry is the same
        // caret write again.
        let redirect = "Nothing was typed. That part is already located: "
            + "[\(handle)] — \(bounds)\(whereItIs). Typing at the cursor would "
            + "put the new words wherever the caret happens to be and leave "
            + "[\(handle)] standing. Call \(verb.binding) with "
            + "\(verb.parameter)=\"\(handle)\" and the new wording instead."
        return Brief(line: line, redirect: redirect)
    }
}
