//
//  PromptCatalog+Voice.swift
//  MaryBrain
//
//  The speaking lane's sections. Every literal came out of
//  `MaryPrompts.seerInstructions` unchanged, with its post-mortem.
//
//  COARSER GRAIN THAN `system()`, and that is forced by the source rather than
//  chosen. `reachClause` is spliced INSIDE the retrieval paragraph's last
//  sentence; the sight paragraph and the three authority blocks sit INSIDE the
//  live-work frame, whose closing words are what tell the model its excerpt is
//  bounded. Those are children, not siblings, and promoting them would move
//  the frame's ending — a byte change and a meaning change at once. Each frame
//  is one section that composes its own children, exactly as the source does.
//
//  THE JOINERY HERE IS SUB-SENTENCE and that is honest, not a smell: the
//  persona is joined to the preamble by a single SPACE, the capability by
//  another, and only the last two clauses lead with "\n\n". Sections carry
//  their own separators; see `PromptSection`'s header.
//

import Foundation

extension PromptCatalog {

    static var voiceSections: [PromptSection] {
        [
            seerPreamble,
            seerPersonaRead, seerPersonaGrounded, seerPersonaConverse,
            seerPersonaInTurn,
            seerCapability, seerRetrieval, seerSightPending,
            seerRunningActions, seerLiveWork,
        ]
    }

    // MARK: - Running actions

    /// Routines from EARLIER turns that are still going, so the new turn does
    /// not double-promise their results.
    ///
    /// THE BUG THIS SECTION EXISTS TO FIX. This note used to be appended to
    /// the FINISHED instructions string — `instructions += "\n\n" +
    /// runningActionsNote(...)` — which put it AFTER the live-work block. That
    /// block is terminal by doctrine: "nothing may follow it, or the model
    /// reads the following doctrine as part of the document." So on any turn
    /// with both a live document and a running routine, a sentence about
    /// background actions was appended to the user's own prose and read as
    /// part of it.
    ///
    /// No pin caught it because every pin calls `seerInstructions` directly,
    /// and the append happened two hundred lines away in the turn loop. Making
    /// it a SECTION is what fixes it: the plan puts it before `seerLiveWork`,
    /// and `PromptPlan.validate` now refuses any order that would put it back.
    static let seerRunningActions = PromptSection(
        id: .seerRunningActions,
        rationale: "Earlier routines still running — must land BEFORE the live text, never after."
    ) { inputs in
        guard !inputs.runningActions.isEmpty else { return "" }
        return "\n\n" + MaryPrompts.runningActionsNote(labels: inputs.runningActions)
    }

    // MARK: - Clock and spoken register

    /// Clock and TTS only. Who she is lives on `SeerWire.Persona.mary` and
    /// rides the chat `persona` object into Seer's personality section —
    /// putting it here as well stacked "You are Mary" under "Your name is
    /// Mary".
    ///
    /// Ends WITHOUT a trailing space; the turn persona that follows leads
    /// with one.
    static let seerPreamble = PromptSection(
        id: .seerPreamble,
        rationale: "The clock and TTS register. Always first in instructions; identity is the chat persona."
    ) { inputs in
        let time = inputs.formatter("h:mm a").string(from: inputs.now)
        let date = inputs.formatter("EEEE, MMMM d, yyyy").string(from: inputs.now)
        return """
        Right now it is \
        \(time) on \
        \(date) (\(inputs.timeZone.identifier)); never \
        guess the date or time. Your words are read aloud by a text-to-speech \
        voice: answer in plain spoken prose, one to three short sentences by \
        default, longer only when the user asks for detail. No markdown, no \
        lists, no URLs; say numbers and symbols as words. Be warm, natural, \
        lightly playful — good company first.
        """
    }

    // MARK: - The three personas

    /// THE READ PERSONA — a third persona, because the other two are both
    /// wrong for a read.
    ///
    /// THE FAILURE THIS FIXES (confirmed against a live bug): a targeted read
    /// SUCCEEDED — `pages_body` returned "characters 12927–13835 of 15775,
    /// from \"batteries\"" — and the voice answered "I don't see anything
    /// about batteries". Closing the delivery gap alone is not enough: the
    /// only grounded persona that existed said "You just FINISHED actions… ONE
    /// short spoken sentence… never repeat the content that was written",
    /// which would have made the voice refuse to read the passage it was
    /// finally holding. A read's whole point is to be spoken, at the length
    /// the passage needs.
    ///
    /// FIRST IN THE PLAN, which is how its precedence over `groundedResults`
    /// is expressed — the source's `if readReport` leads the same ladder.
    static let seerPersonaRead = PromptSection(
        id: .seerPersonaRead,
        rationale: "She just READ what they asked about — reciting IS the answer.",
        exclusive: .seerPersona
    ) { inputs in
        guard inputs.readReport else { return "" }
        return " " + """
        You just READ exactly what the user asked about. It sits at the \
        very end of these instructions, and it is what they wanted. Give \
        it to them: answer from it in your own voice, quoting the text \
        itself generously and at whatever length the answer actually \
        needs — when they asked to hear a passage, reciting IS the \
        answer, so do not compress it to a sentence out of habit. Never \
        say you cannot see it or that it isn't there; you are holding it. \
        Don't describe how you fetched it, and don't speak character \
        counts, offsets, file names or Skill names aloud.
        """
    }

    static let seerPersonaGrounded = PromptSection(
        id: .seerPersonaGrounded,
        rationale: "Actions really ran — report the outcome in one sentence.",
        exclusive: .seerPersona
    ) { inputs in
        guard let grounded = inputs.groundedResults else { return "" }
        return " " + """
        You just FINISHED actions the user asked for earlier — these \
        really ran; the grounded results are below. Tell the user the \
        outcome in ONE short spoken sentence, stating the result plainly \
        — never hedge about whether it happened, never describe the \
        mechanics of how, and never repeat the content that was written.

        \(grounded)
        """
    }

    /// THE TURN ASKED FOR NOTHING — and until this section existed, no persona
    /// said so.
    ///
    /// THE FAILURE THIS FIXES (confirmed against a live session): Mary
    /// answering small conversational turns with "I'm adding that now.", "I'm
    /// stopping that now." — present-progress action language over a turn
    /// where nothing had been requested and nothing was running. Seer's
    /// resonance pass then extracted those sentences as retrievable memory,
    /// so yesterday's phantom work primed today's.
    ///
    /// IT COULD NOT HAVE GONE OTHERWISE. `seerPersonaInTurn` is the ladder's
    /// catch-all: every turn that is not a read and not a grounded result gets
    /// it, which includes every greeting and every joke. It is ~150 words
    /// whose entire subject is acting, and it carries the ONLY concrete
    /// example reply anywhere in the voice prompt — "Got it — a new event on
    /// the calendar." A small model copies the exemplar it is shown, and on a
    /// chat turn that exemplar was the only model of a reply it had. Against
    /// it stood six words of the preamble: "good company first".
    ///
    /// THE COUNTERWEIGHT ALREADY EXISTED IN THE WRONG LANE. `system()`'s
    /// `registerSwitch` has long said "when they're just chatting… simply
    /// talk… leave the Skills alone unless they actually ask for something" —
    /// but that is the Skill lane's prompt, and Lane A is handed
    /// `instructions` only. Exactly the one-laned-doctrine shape called out on
    /// `seerPersonaInTurn` below, one clause over.
    ///
    /// THIRD IN THE LADDER, NOT FIRST. It renders only when the read and
    /// grounded personas have both declined, which is the plan expressing
    /// "conversational AND no read AND no grounded result" through order
    /// rather than through three guards restated inside this closure. A read
    /// or a finished action still outranks it: those turns have something to
    /// report, whatever the router made of the sentence.
    ///
    /// NO ANTI-ASKING CLAUSE, deliberately. `seerPersonaInTurn`'s exists
    /// because the Skill pipeline enforces its own confirmation boundaries and
    /// a second prose question wastes the user's breath. There is no pipeline
    /// on a converse turn, and a question back is what company does.
    static let seerPersonaConverse = PromptSection(
        id: .seerPersonaConverse,
        rationale: "The turn asked for nothing — talk, and announce no work.",
        exclusive: .seerPersona
    ) { inputs in
        guard inputs.conversational else { return "" }
        return " " + """
        This turn is CONVERSATION, not a request: a greeting, an opinion, \
        something they noticed, a joke, a question about the world. Nothing \
        was asked of your hands, so nothing is underway and there is no \
        result on its way. Do not announce work, do not acknowledge an \
        intent, and do not name something you are about to go do — no "I'm on \
        it", no "adding that now", no offering to run something they did not \
        ask for. Just talk to them: a sentence or two, warm and specific, a \
        quip if one is there. This is the register where being good company \
        IS the whole job. Your hands are still yours — if they ask for \
        something, act then, and never disclaim what you can do.
        """
    }

    /// Lane A knows Mary CAN act, but not whether this turn DID. It has no
    /// same-turn Skill receipt channel. Treating intent as execution here caused
    /// the voice to say an app mutation was underway while Lane B had no eligible
    /// Skill at all. Capability and execution state are separate facts.
    ///
    /// THE SECOND PARAGRAPH IS THE ANTI-ASKING CLAUSE, AND LANE A HAD NEVER
    /// HAD ONE. `system()` has said for a long time: "Never ask permission in
    /// prose BEFORE invoking a Skill either." That is the Skill execution lane's prompt.
    /// Lane A is handed `instructions` only and structurally cannot see it, so
    /// the doctrine was one-laned, and on the live turn the voice improvised
    /// the other half of it: "Yeah yeah exactly can you reword the whole thing
    /// for me" — `REPLACE_PASSAGE` landed correctly, and Lane A said "I'm on
    /// it, but I need a quick clarification — do you mean the whole document,
    /// or the Background section?" — a permission question about a change that
    /// had already been made.
    static let seerPersonaInTurn = PromptSection(
        id: .seerPersonaInTurn,
        rationale: "She knows Mary can act, but reports execution state only from grounded receipts.",
        exclusive: .seerPersona
    ) { _ in
        " " + """
        You are not a read-only assistant. Your hands — a Skill pipeline — \
        carry out real actions on the user's Mac: editing their code, \
        writing and revising their documents, running commands, \
        controlling apps. This ordinary voice pass does not receive a \
        same-turn execution receipt. Treat an ungrounded action request as \
        INTENT, not evidence that execution started: acknowledge it briefly \
        by naming the intended result — for example, "Got it — a new event \
        on the calendar." Reserve present-progress action language for instructions \
        that explicitly include a grounded running-action receipt, and reserve \
        completion claims for grounded results. Never claim a specific result \
        you have not seen. Never narrate the mechanics of an edit or speak \
        scripts, code, or Skill syntax aloud. Never disclaim Mary's general \
        ability to act, and never give manual step-by-step instructions for \
        something her hands handle.

        Never ask for permission and never ask a clarifying question. \
        The Skill pipeline enforces its own confirmation boundaries, so asking \
        twice wastes the user's breath. If what they said could mean two \
        things, take the reading they most likely meant and state that \
        interpretation as intent, never as work already underway, so they can \
        correct you in one word. Anything that truly needs a go-ahead stops \
        and asks by itself.
        """
    }

    // MARK: - Capability

    static let seerCapability = PromptSection(
        id: .seerCapability,
        rationale: "What her hands do in the world she is working inside."
    ) { inputs in
        inputs.capability.map { " \($0)" } ?? ""
    }

    // MARK: - Retrieval doctrine, with reach spliced inside

    /// Retrieval doctrine — the symmetric half of
    /// `PagesContextWatcher.livenessLine` ("LIVE is a claim, and it has to be
    /// earned"). That line teaches when perception may claim to be current;
    /// this one teaches that MEMORY never may. It rides whether or not live
    /// work exists, because the failure it repairs happens exactly when
    /// perception is missing: asked about a paragraph, the voice narrated the
    /// "removed 'Despite growing awareness' paragraph" out of retrieved
    /// deposits — a paragraph the user had already deleted.
    ///
    /// THE REACH CLAUSE IS A CHILD, spliced into the final sentence rather
    /// than following as a sibling. It is stated to the voice because this is
    /// the lane that speaks and the one lane with no plugin roster at all —
    /// `seerInstructions` never lists plugins, so until this clause existed,
    /// nothing whatsoever told it Calendar exists. THE FAILURE (the user's
    /// words: "Mary doesn't conduct tasks for Calendar and Reminders now
    /// because she can't see them"): on a calendar turn the voice held a Pages
    /// capability line, a Pages ground-truth block, and an instruction to
    /// announce when it can't see something — so it announced blindness about
    /// a question that never needed eyes.
    /// THE SIGHT CLAUSE IS THE REACH CLAUSE'S SIBLING, for the same failure
    /// in a different sense: the reach clause exists because nothing told the
    /// voice Calendar exists; until this clause, nothing told it EYES exist.
    /// Asked "what building is that" over a video, the voice held no live
    /// section, a doctrine ordering it to admit blindness, and zero mention
    /// of the look faculty — so it said "I can't see that" while the hands
    /// were looking. Always-on, ~300 bytes: the price of never denying sight.
    static let seerRetrieval = PromptSection(
        id: .seerRetrieval,
        rationale: "Memory is the past, never the document now — plus the eyeless reach list and the sight clause."
    ) { _ in
        let reach = " " + """
        Separately from anything on screen: you reach the rest of this Mac \
        DIRECTLY — \(MaryPrompts.ambientReachList) — and none of it has to be open, \
        visible or focused for you to use it. If they ask what is on their \
        calendar, to add a reminder, to play something or to check their mail, \
        your hands do it and you answer with the real result. Never say you \
        can't see those, and never treat whatever document happens to be in \
        front of them as a limit on what you can do.
        """
        let sight = " " + """
        You also have eyes on request: your hands can take a look at whatever \
        is on their screen — any app, an image, a video — and describe it. If \
        they ask about something visible on their screen that these \
        instructions don't cover, never say you cannot see it — say you're \
        taking a look.
        """
        return "\n\n" + """
        Anything you REMEMBER about their documents or code — retrieved \
        notes, earlier deposits, things you were told before — is a record \
        of what happened in the past, never a description of what a document \
        says now: remembered wording may already have been rewritten or \
        deleted. Never state remembered text as the document's current \
        contents. If they ask what a document or a file SAYS and you don't \
        have its live text in front of you, say so plainly and offer to read \
        it — do not fill the gap from memory.\(reach)\(sight)
        """
    }

    /// A LOOK IS UNDERWAY FOR THIS VERY TURN — the pre-lane look fired and
    /// missed its budget, so nothing is in hand yet while the hands keep
    /// looking. Rendered ONLY on that pass (empty everywhere else, which is
    /// what keeps every golden byte-identical): the voice promises the look
    /// and the spoken follow-up completes the sentence it started.
    static let seerSightPending = PromptSection(
        id: .seerSightPending,
        rationale: "A look fired for this turn with nothing in hand yet — promise it, never deny sight."
    ) { inputs in
        guard inputs.lookUnderway else { return "" }
        return "\n\n" + """
        A look at their screen is being taken RIGHT NOW for this very \
        question. Never say you cannot see it — tell them you're taking a \
        look, and the description will follow in a moment. Do not guess at \
        what the screen shows.
        """
    }

    // MARK: - The live work, and the authority ordering inside it

    /// THE ONE AUTHORITY BLOCK, and its internal order IS the ranking:
    ///
    ///   liveWork      — what is on screen NOW (ground truth)
    ///   heldFacts     — what she read EARLIER, each carrying its age
    ///   readPassages  — what she read for THIS question (last word)
    ///
    /// TERMINAL. The live text lands last on purpose: nothing may follow it,
    /// or the model reads the following doctrine as part of the document.
    static let seerLiveWork = PromptSection(
        id: .seerLiveWork,
        rationale: "What she can see, ranked: on-screen, then held, then this turn's read. Lands last.",
        ordering: .last
    ) { inputs in
        let liveBlocks = inputs.liveWork + inputs.heldFacts
            + inputs.heldMentions + inputs.readPassages
        guard !liveBlocks.isEmpty else { return "" }

        // Register follows the owning app, exactly as system()'s headers do —
        // a Pages session must never hear "file", and Scrivener's manuscript
        // is not Pages' document.
        let place: String
        let sight: String
        let windowSight = """
        What you are shown is a WINDOW onto their work, never all of it — \
        the text below says which characters of the whole it covers, and \
        everything outside those bounds is simply text you have not been \
        shown. Unseen is not absent. NEVER tell the user that a passage, \
        a section or a subject isn't in their work because it isn't in \
        this window: say plainly that it's outside the part you can see \
        and that you're pulling it up, then answer from what comes back.
        """
        // THE SIGHT CLAUSE TURNS ON WHAT THE CHANNEL HOLDS, NOT ON WHICH
        // APPLICATION IT IS. A prose surface that answers with the entire text
        // gives Mary the whole document; one that answers with the current
        // outline item gives her a window onto it. Keying on the property is
        // what stops the next whole-document place from inheriting the window
        // hedge — the bug a list of application names re-created every time
        // somebody added one to it.
        switch inputs.liveWorkWorld {
        case .document(let name, true):
            place = name.map { "document open in front of them in \($0)" }
                ?? "document open in front of them"
            // WHAT IT GAINS OVER THE WINDOW CLAIM, and what it must not lose:
            // holding ONE document whole says nothing about the other ten the
            // user has open, and a voice that forgets that will answer "it's
            // not in your notes" from the single note it happens to hold.
            sight = """
            You hold the WHOLE of that document, not a window onto it — all \
            of its text is already in hand, so there is no part of THIS one \
            that is "outside what you can see". NEVER say a passage or a \
            subject is outside your window. But the user may keep SEVERAL \
            open at once, and holding this one whole tells you nothing about \
            the others: if something isn't here, it may simply be in another \
            window. Never say it isn't in their documents — say it isn't in \
            this one, and read the one that would have it.
            """

        case .document(let name, false):
            place = name.map { "document open in front of them in \($0)" }
                ?? "document open in front of them"
            sight = windowSight

        case .application(let name):
            // AN APPLICATION OWNS THE TURN WITHOUT A LIVE DOCUMENT. It is
            // named, and named from its registration rather than guessed —
            // "in front of you in Scrivener" for a Chrome question is the
            // sentence this arm exists to make unsayable.
            place = name.map { "\($0) window open in front of them" }
                ?? "window open in front of them"
            // NO LIVE READ, SO NO WINDOW CLAIM EITHER WAY. Its facts arrive as
            // deposits rather than as a live excerpt with character bounds, so
            // neither the "this is a WINDOW onto their work" hedge nor a
            // whole-document claim is true. Say only what is known: what was
            // read is held, and the rest is unread rather than absent.
            sight = """
            What you hold of it is what you have READ — the blocks below \
            are real observations, each one stating its own age, and \
            anything you have not read is simply unread, not absent. NEVER \
            tell the user something isn't there because it isn't in what \
            you hold: look again, or read the part they mean, and answer \
            from what comes back. And never describe this as a document in \
            one of their writing apps — it is \(name ?? "this application"), \
            and calling it anything else is a claim about their screen you \
            cannot make.
            """

        case .unled:
            // NOTHING LEADS. Reached with no live work at all — only held
            // facts or this turn's read passage, both of which state their own
            // provenance below. There is no screen to claim, so this claims
            // none: the sentence names what is in hand, not a place.
            place = "work they have in front of them"
            sight = """
            You are NOT looking at their screen right now. Everything below \
            is something you read earlier or just now, and it says so \
            itself — so speak from it as something you read, never as \
            something you can currently see. Do not name an app or a \
            document as the thing in front of them: you do not know that \
            here, and guessing it is how a question about one app gets \
            answered about another.
            """
        }

        var body = inputs.liveWork.joined(separator: "\n\n")
        if !inputs.heldFacts.isEmpty || !inputs.heldMentions.isEmpty {
            var held = """
            I am also still holding these from earlier in this \
            conversation — I really read them, so they are not memories to \
            hedge about, and each one states its own age. They do NOT \
            supersede what is on screen above: where a held fact and the \
            live text cover the same words, the live text is newer and \
            wins, and anything past its stated age may have been edited \
            since — give the age rather than asserting it is the wording \
            now.
            """
            for fact in inputs.heldFacts {
                held += "\n\n\(fact)"
            }
            if !inputs.heldMentions.isEmpty {
                // Said differently HERE than in the Skill lane, and
                // deliberately: this voice does not call Skills, so it is told
                // what it may PROMISE, not which binding to reach for. The
                // offsets stay out of its mouth.
                held += "\n\n" + """
                Also still held. Each one starts with a handle like [S1], \
                which is how I pull that exact passage back up or change \
                it — so I can promise to fetch it or fix it. Say what it \
                is about, never the numbers: those are mine for finding \
                it, and they are not something to read out or to work out \
                for myself.
                """
                for mention in inputs.heldMentions {
                    held += "\n- \(mention)"
                }
            }
            body = body.isEmpty ? held : body + "\n\n" + held
        }
        if !inputs.readPassages.isEmpty {
            // ONE authority, and the read is its last word.
            let read = """
            I read this just now, for exactly what they asked about — it \
            is the authority for their question, and where it and the \
            on-screen excerpt differ, THIS is the part they asked about.

            \(inputs.readPassages.joined(separator: "\n\n"))
            """
            body = body.isEmpty ? read : body + "\n\n" + read
        }
        return "\n\n" + """
        You can see what the user is looking at right now — this is the \
        live \(place), and it is the ground truth for their work: base \
        what you say about the wording on THIS, never on a retrieved \
        memory or an earlier mention of some other file or document; it \
        supersedes them.

        \(sight)

        When they ask about a particular passage — to check it, fix it, \
        tighten it, read it back — quote it and work with it directly: \
        that IS the answer. Otherwise reference it naturally in a \
        sentence or two rather than reciting the whole thing unasked.

        \(body)
        """
    }
}
