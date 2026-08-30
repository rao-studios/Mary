//
//  SkillOutcome.swift
//
//  WHAT COMES BACK FROM RUNNING ONE SKILL BINDING.
//
//  It lives with the contract rather than with the brain because it is the
//  return type every adapter writes — twenty-seven files named it before
//  this package existed. A plugin author needs it; the inference engine
//  merely passes it along.
//

import Foundation

/// WHAT A SKILL RESULT MEANS FOR MEMORY.
///
/// Declared by the binding rather than guessed from a name table, on
/// `SkillOutcome.deferred`'s precedent: the binding knows its own semantics.
///
/// Lives beside the outcome because the outcome is its only consumer. Bonnie
/// kept it with the durable-indexing machinery, which meant deferring that
/// machinery would have taken a field of the outcome with it.
public enum ArchivePolicy: String, Sendable, Equatable {
    /// A record of something that HAPPENED. Every occurrence is its own
    /// document, kept forever — "I sent the mail at four" does not obsolete
    /// "I sent the other mail at three".
    case episodic
    /// A statement about the CURRENT STATE of the thing in view. The next
    /// statement about the same thing replaces this one, because the older
    /// one is not history — it is a wrong answer waiting to be retrieved.
    case stateSnapshot
    /// Not worth remembering at all.
    case none
}


/// WHAT A PASSAGE EDIT DID TO THE DOCUMENT, as a typed fact rather than a
/// wording difference. `foundNothing`'s sibling: `ok` alone cannot carry it,
/// because `ok: false` reads as retryable to a small model — and a write that
/// MAY have landed must never be retried — while `ok: true` used to let the
/// report speak "Done" over a change nothing confirmed.
public enum EditDisposition: String, Sendable, Equatable {
    /// Verified against the document: the change is there.
    case landed
    /// The change was SENT and nothing confirmed it — the document may or may
    /// not hold it. Never a retry candidate; never a "Done".
    case unconfirmed
    /// Nothing differed; the document was not touched.
    case unchanged
}

/// WHAT A KEYBOARD TYPING RUN DELIVERED — nil for everything that is not a
/// typing run. `EditDisposition`'s sibling for the typer: a paused or
/// focus-lost run returns `ok: true` (the pause is correct behavior with a
/// saved remainder for resume_typing), but "typed 2 words then lost focus"
/// must never read upstream as a fully delivered draft. `.partialResumable`
/// is that distinction, carried structurally.
public enum TypingDisposition: String, Sendable, Equatable {
    /// The whole passage landed.
    case completed
    /// Some of it landed; the remainder is saved and resume_typing continues.
    case partialResumable
}

public struct SkillOutcome: Sendable {
    public var ok: Bool
    /// Machine-readable terminal state for receipts and routing diagnostics.
    /// In particular, schema-policy denial is `.blocked`, not an adapter
    /// failure disguised as an ordinary `ok == false` result.
    public var status: SkillRunStatus
    /// Spoken back to the user via the confirmation round.
    public var summary: String
    /// True when `summary` is a fire-and-forget acknowledgement whose real
    /// result lands later on another channel (delegate_coding spawns a
    /// background session and reports via the completion multicast). The brain
    /// won't archive a deferred ack into the Totem context — an "on it" note
    /// carries no settled result worth recalling, and re-retrieving it as RAG
    /// filler is exactly the voice noise we're cutting.
    public var deferred: Bool
    /// What this result MEANS for memory — the binding's own declaration,
    /// following `deferred`'s precedent. `.episodic` (the default) keeps
    /// today's behavior: a fresh document per dispatch, kept forever.
    /// `.stateSnapshot` says "this describes the document in view as it now
    /// stands", which keys the deposit by document identity so the next one
    /// REPLACES it. `.none` says don't remember this at all.
    public var archivePolicy: ArchivePolicy
    /// The binding LOOKED and what was asked for is not in what it can read.
    /// `ok` stays TRUE — the read ran, this is its honest answer, and a model
    /// that called the binding itself needs the summary's reasons (in Pages:
    /// headers, footers, text boxes and table cells live outside `body text`).
    /// What this flag denies is AUTHORITY.
    ///
    /// THE FAILURE THIS FIXES (confirmed against a live user session): a
    /// `find` miss returned `ok: true` with "…has no \"section 5\" in its body
    /// text… Read the whole document with pages_body and no target to check"
    /// (that closing instruction is GONE now — the miss carries the document
    /// itself instead of ordering a second round for it — but the flag is what
    /// this comment is about, and the flag is unchanged),
    /// and `AbilityRuntime.readNamedPart` — which only checked `ok` — carried
    /// it into the voice's live block under "I read this just now, for exactly
    /// what they asked about — it IS the authority for their question". Mary
    /// recited the Skill's miss-message to the user: "I'm on it — let me pull
    /// up the full document to check for section 5."
    ///
    /// A SENTINEL rather than `ok: false`, deliberately. `ok: false` is read
    /// by two other mechanisms that would each turn the miss into a different
    /// costume of the same bug: the turn's "silent success, SPOKEN failure"
    /// rule would speak it aloud as "that didn't go through — <miss text>",
    /// and the orchestrator would see a failed read it is entitled to retry.
    /// A miss is not a failure. It is an answer that must not be dressed as a
    /// passage.
    public var foundNothing: Bool
    /// THE PASSAGE THIS RESULT IS ABOUT — `[S1]`, minted by `PassageRegistry`.
    ///
    /// A STRUCTURAL FIELD, following `foundNothing`'s precedent, and it is
    /// structural for the reason the whole passage contract exists. The handle
    /// has to reach `AmbientFact` so `mentionLine` can show it, and the ONLY
    /// alternative was re-parsing it back out of the summary prose — which is
    /// exactly how `characters 68–916 of 916` travelled: `regionOutcome`
    /// printed it, `AmbientBridge.parseBounds` scraped it back, and the model
    /// was handed integers no primitive accepted. A handle recovered from
    /// prose is a handle a model can hallucinate into existence; a handle
    /// carried in a field is one the registry either knows or does not.
    ///
    /// It also decides WHICH WORLD the read's fact is filed under
    /// (`AbilityRuntime.registerRead`): `find_passage` is owned by `typer`,
    /// and a Pages passage filed under Typer would be a fact about a place
    /// that has no documents.
    public var passageHandle: String?
    /// The immutable package/Ability/Skill identity that authorized this
    /// execution. Normally the caller already has it; confirmed replays carry
    /// it here because they execute a binding frozen on the preceding turn.
    public var skillReference: AbilitySkillReference?
    /// Typed machine outputs keyed by the Skill's declared output-port name.
    /// Existing adapters may continue returning only `summary`; typed-native
    /// adapters fill this map so workflows can pass Values without flattening
    /// them into provider text.
    public var typedOutputs: [String: ValueEnvelope]
    /// WHAT AN EDIT DID TO THE DOCUMENT — nil for everything that is not a
    /// passage edit. Carried structurally so `EditReport` can refuse to speak
    /// "Done" over `.unconfirmed`, and the detached settle path can refuse to
    /// settle it silently. The one place the flag can be lost is the
    /// `LaneOutcome` mapping; both mapping sites carry it.
    public var editDisposition: EditDisposition?
    /// THE ADAPTER ALREADY FILED THIS READ'S AMBIENT FACT ITSELF — richer
    /// than the dispatcher's generic one (a named document, an outline), so
    /// the dispatcher must not file a second. One read, one fact: two records
    /// of the same look spend the lane's budget twice and read as two
    /// observations in the pane. False by default; an adapter that deposits
    /// out-of-band says so here.
    public var ambientDeposited: Bool
    /// WHAT A TYPING RUN DELIVERED — see `TypingDisposition`. Nil for
    /// everything that is not a keyboard typing run.
    public var typingDisposition: TypingDisposition?
    /// THE ACTING INTENT IS SATISFIED — the change the user asked for has
    /// happened, and the turn has nothing left to carry out.
    ///
    /// THE LOOP THIS ENDS. The lane's continuation nudge decides whether an
    /// acting turn finished by asking what KIND of skills ran — read-only,
    /// non-effectful, surface-preparing — and never what they DELIVERED. That
    /// is right for the case it was built for (a raised document still needs
    /// filling) and wrong for a skill that is the whole errand: `search_web`
    /// found the video and pressed play, and was then told "the asked-for
    /// change has not landed yet — call the command that carries it out now".
    /// Re-running a navigation navigates again, off the page it just opened.
    /// The user saw the video open, vanish, and open again.
    ///
    /// A DECLARATION COULD NOT HAVE FIXED IT, which is why this is a field on
    /// the OUTCOME. `open_in_new_tab` legitimately prepares a surface when a
    /// write follows and legitimately completes the request when none does;
    /// the binding cannot know which turn it is in, and only the run can say.
    ///
    /// SET IT ONLY ON PROVEN EFFECT. `false` is the honest default and the
    /// answer whenever the effect was merely DISPATCHED — a press that
    /// returned true is not a page that changed. The design-plan receipts draw
    /// the same line in the same word: delivery is never effect, and `.landed`
    /// is assigned after observation, not after sending. A skill that claims
    /// this without checking re-creates the bug with the sign flipped: the
    /// turn stops while the request is still unmet, in silence.
    public var landed: Bool

    /// WHAT THIS ACTED ON — the element, with its frame, as it was at the
    /// moment of acting.
    ///
    /// The geometry half of the behavioural record: "type at cursor" becomes
    /// "typed into the text area of the Essay window, at this rectangle, on
    /// this screen". Bonnie discarded this everywhere — its typer awaited a
    /// focused text surface and returned a Bool, its hands returned a window
    /// rect and an opaque token — so no record of any action could say what
    /// it touched.
    ///
    /// EVIDENCE, NOT AN ADDRESS. Nothing re-finds a target through this; every
    /// actuation path re-reads and re-locates by identity first. It is what
    /// was true when the act happened, offered for reasoning and for learning.
    /// Nil is correct for a skill with no surface — one that only thinks, or
    /// answers from held context.
    public var target: AXElementRecord?

    /// The adapters that fulfilled this, primary first.
    ///
    /// Usually one. More than one when fulfilment fell through a ladder — a
    /// prose write that lands by keystroke names the prose surface and then
    /// the typer. The trail is what makes "how did she actually do that?"
    /// answerable from the record instead of from a log.
    public var adapterTrail: [AdapterID]

    public init(
        ok: Bool,
        summary: String,
        status: SkillRunStatus? = nil,
        deferred: Bool = false,
        archivePolicy: ArchivePolicy = .episodic,
        foundNothing: Bool = false,
        passageHandle: String? = nil,
        skillReference: AbilitySkillReference? = nil,
        typedOutputs: [String: ValueEnvelope] = [:],
        editDisposition: EditDisposition? = nil,
        ambientDeposited: Bool = false,
        typingDisposition: TypingDisposition? = nil,
        landed: Bool = false,
        target: AXElementRecord? = nil,
        adapterTrail: [AdapterID] = []
    ) {
        self.ok = ok
        self.summary = summary
        self.status = status ?? (deferred ? .deferred : (ok ? .succeeded : .failed))
        self.deferred = deferred
        self.archivePolicy = archivePolicy
        self.foundNothing = foundNothing
        self.passageHandle = passageHandle
        self.skillReference = skillReference
        self.typedOutputs = typedOutputs
        self.editDisposition = editDisposition
        self.ambientDeposited = ambientDeposited
        self.typingDisposition = typingDisposition
        self.landed = landed
        self.target = target
        self.adapterTrail = adapterTrail
    }
}
