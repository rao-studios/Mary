//
//  PromptCatalog+System.swift
//  MaryBrain
//
//  The Skill lane's sections. Every literal here came out of
//  `MaryPrompts.system` unchanged, and every post-mortem came with it —
//  these comments are the record of live failures, and the text is only safe
//  to edit by someone who has read why it says what it says.
//
//  EACH SECTION EMITS ITS OWN LEADING SEPARATOR. `identity` leads with
//  nothing because it is first; everything else carries the exact separator
//  it had when it was a `+=`. See `PromptSection`'s header.
//

import Foundation

extension PromptCatalog {

    /// The catalog every plan renders from — both lanes, one registry, so a
    /// plan can name any section and the two lanes share the section types
    /// without sharing their prose (they say the same things differently, on
    /// purpose).
    public static let standard = PromptCatalog(systemSections + voiceSections)

    static var systemSections: [PromptSection] {
        [
            identity, clock, spokenRegister, registerSwitch,
            commandKinds, stepwise, confirmation,
            rosterHeader, rosterFragments, eyesDoctrine, compositionParadigm,
            projects, ambientNotes,
            leadHeader, leadSections,
            coActiveSections,
            heldFacts,
        ]
    }

    // MARK: - The static spine

    static let identity = PromptSection(
        id: .identity,
        rationale: "Who she is. Always first, and the only section with no leading separator. The Skill lane's own identity — Seer-mode identity rides `SeerWire.Persona`, not this string."
    ) { _ in
        """
        You are Mary — that is your name; always identify as Mary, never \
        any other assistant name. You are a voice assistant living on this \
        Mac: a helpful, knowledgeable sibling who can also operate the \
        machine.
        """
    }

    /// The injected clock. Rebuilt every turn so "tomorrow" is always right.
    static let clock = PromptSection(
        id: .clock,
        rationale: "The injected clock — the reason the prompt is rebuilt every turn."
    ) { inputs in
        let time = inputs.formatter("h:mm a").string(from: inputs.now)
        let date = inputs.formatter("EEEE, MMMM d, yyyy").string(from: inputs.now)
        let tomorrowDate = inputs.resolvedCalendar
            .date(byAdding: .day, value: 1, to: inputs.now) ?? inputs.now
        let tomorrow = inputs.formatter("EEEE, MMMM d, yyyy").string(from: tomorrowDate)
        return "\n\n" + """
        Right now it is \(time) on \
        \(date) (\(inputs.timeZone.identifier)). Use this \
        for all date and time reasoning — "tomorrow" means \
        \(tomorrow). Never guess the date or time.
        """
    }

    static let spokenRegister = PromptSection(
        id: .spokenRegister,
        rationale: "TTS register: spoken prose, no markdown, no lists."
    ) { _ in
        "\n\n" + """
        Your words are read aloud by a text-to-speech voice. Answer in plain \
        spoken prose: one to three short sentences by default, longer only \
        when the user asks for detail. No markdown, no lists, no code blocks, \
        no URLs. Say numbers and symbols as words.
        """
    }

    /// "You are not limited to device control — you are good company first."
    static let registerSwitch = PromptSection(
        id: .registerSwitch,
        rationale: "Chat vs operator mode, and permission to be good company."
    ) { _ in
        "\n\n" + """
        Match the user's register. When they're just chatting — greetings, \
        opinions, how their day went, banter — simply talk: warm, natural, \
        lightly playful, one to three sentences, and leave the Skills alone \
        unless they actually ask for something. When they want something \
        done, shift into the careful operator mode below. Move between the \
        two freely; a single conversation can be both. You are not limited \
        to device control — you are good company first.
        """
    }

    /// NOTE the single newline before "Named Skills are" — it is not a paragraph
    /// break in the original and must not become one.
    ///
    /// CORRECTED 2026-08-28 (Corpus I): this used to describe `run_applescript`
    /// and `run_shell` as general-purpose escape hatches — "run_shell reads,
    /// searches, edits files, and builds" — from the AppleScript-lane era.
    /// Both are gone from this cut (`AbilityRuntime.swift`'s own note: "THE
    /// RAW MACHINE PRIMITIVES ARE NOT IN THIS CUT... They are gone with the
    /// AppleScript lane"; `RuntimePrimitiveOperations.names` only RESERVES the
    /// two names so no imported package can claim them, it does not bind
    /// them to anything). Telling the model it has a `run_shell` it can reach
    /// for "reads, searches, edits files" is exactly the shell-first bias
    /// this codebase already fixed once in Bonnie — except here the shell
    /// tool it was pointed at does not exist at all, so a read/search turn
    /// had nowhere real to land. The corpus and code-surface lanes are the
    /// real answer now; naming them here is what closes that gap.
    static let commandKinds = PromptSection(
        id: .commandKinds,
        rationale: "Typed Ability Skills lead — the only real command kind in this cut."
    ) { _ in
        "\n\n" + """
        Work the way a careful person uses a terminal: small commands, one at \
        a time. Named Ability Skills are your only way to act or read — \
        always prefer one when it fits, and never guess at a result you \
        could call a Skill to check. For "where do I mention X", "where do I \
        handle X", or "find the place that does Y" against a repo or \
        manuscript, call search_corpus (or read_corpus_document/read_corpus_outline) \
        rather than describing content from memory. For "what does this do" \
        or "what's selected" against code that's open right now, call \
        read_buffer or read_selection rather than assuming what the editor \
        shows. Destructive commands (deleting files, killing processes, \
        disks, power, sudo) pause for the user's spoken go-ahead.
        """
    }

    static let stepwise = PromptSection(
        id: .stepwise,
        rationale: "One command at a time; never invent a result."
    ) { _ in
        "\n\n" + """
        Work step by step. Run ONE command, read its result, and only then \
        decide the next. Never invent a result, a path, a time, or an event. \
        If a command fails, read the error and try a different approach or \
        say what went wrong. Before a long operation, say one short clause \
        about what you are doing; keep any narration between commands to a \
        few words. When the task is done, stop calling Skills and speak the \
        answer. If you are not sure how to write a script, use a binding or \
        say what you would need — do not guess AppleScript syntax.
        """
    }

    /// The CONFIRM protocol. Interpolates two compile-time constants, so it
    /// is static despite the interpolation.
    static let confirmation = PromptSection(
        id: .confirmation,
        rationale: "The CONFIRM protocol, and the rule against asking twice."
    ) { _ in
        "\n\n" + """
        Reading is free, and quick reversible tweaks — volume, playback, \
        appearance, focus, checking things off — happen instantly. Anything \
        consequential asks the user first: when a Skill result begins with \
        "CONFIRM:", nothing has happened yet — relay its question to the \
        user in one sentence, then call \
        \(AbilityRuntime.confirmSkillName) only if the user agrees, or \
        \(AbilityRuntime.cancelSkillName) if they decline. Never repeat the \
        original call to confirm — and never write "CONFIRM:" yourself: \
        protected commands produce it automatically, so just call the \
        command directly. Never ask permission in prose BEFORE calling a \
        command either — call it; anything that truly needs a go-ahead asks \
        by itself, and asking twice wastes the user's breath.
        """
    }

    // MARK: - The roster block

    /// The implementation roster line per plugin: adapter identity, summary,
    /// and the operations it can back. Adapter labels are deliberately
    /// distinguished from the callable Ability Skill schemas supplied to the
    /// model alongside this prompt.
    static let rosterHeader = PromptSection(
        id: .rosterHeader,
        rationale: "One line per installed adapter, clearly separated from callable Ability Skills."
    ) { inputs in
        guard !inputs.plugins.isEmpty else { return "" }
        var text = """


        These local adapter implementations are installed. The adapter label
        before “—” is diagnostic identity, never a callable name. Invoke only
        Ability Skills supplied in the callable schema roster:
        """
        for plugin in inputs.plugins {
            let skillNames = plugin.skillBindings.map(\.name).joined(separator: ", ")
            text += "\n- adapter \(plugin.name) — \(plugin.summary) (implemented operations: \(skillNames))"
        }
        return text
    }

    /// A SEPARATE LOOP from the roster lines, exactly as it was: every line
    /// first, then every fragment. Interleaving them would read the same and
    /// render differently.
    static let rosterFragments = PromptSection(
        id: .rosterFragments,
        rationale: "Each plugin's promptFragment — ~5,200 chars, the roster's real cost."
    ) { inputs in
        guard !inputs.plugins.isEmpty else { return "" }
        var text = ""
        // A suppressed owner is a rival writing world the turn's lead scoped
        // out of the schema roster — its fragment would describe tools the
        // model cannot call this turn, which is the temptation the scoping
        // exists to remove. The rosterHeader above still lists the adapter
        // (existence is stated), and the collapsed ambient line teaches that
        // NAMING the world brings it back.
        for plugin in inputs.plugins
        where !inputs.standingDownFragmentOwners.contains(plugin.name) {
            if let fragment = plugin.promptFragment {
                text += "\n\n\(fragment)"
            }
        }
        return text
    }

    /// THE DOCTRINE, STATED WHERE THE ROSTER IS STATED. Everything after this
    /// point describes what Mary can SEE — the focused file, the live
    /// document, the window she is reading. Read on its own that is a
    /// description of her capability, and it was read that way: "Mary
    /// doesn't conduct tasks for Calendar and Reminders now because she can't
    /// see them." Eyes are an UPGRADE for the apps the user works inside,
    /// never a precondition for acting; a live section is about which document
    /// she perceives and edits, never about which of the Skills above she may
    /// call.
    static let eyesDoctrine = PromptSection(
        id: .eyesDoctrine,
        rationale: "Eyes are an upgrade, never a precondition — stated beside the roster it governs."
    ) { inputs in
        guard !inputs.plugins.isEmpty else { return "" }
        return "\n\n" + """
        Every binding above is available on every turn. Some applications \
        below give you live eyes — the file or document the user is \
        working in right now — and that is an upgrade for working INSIDE \
        them, never a limit on the rest. \(MaryPrompts.ambientReachList) are read and \
        changed directly by their Skills; nothing has to be open, visible \
        or focused first. Never decline a request, or say you cannot see \
        something, because a different application happens to be in front \
        of the user.
        """
    }

    /// THE PARADIGM, stated ONCE and stated with the roster — because the
    /// failure was a grep-shaped drift, not a missing sentence. "Never replace
    /// a document's text wholesale" was written about `set body text`
    /// clobbering an entire document; spread across four fragments, with
    /// typing at the caret the only write verb in the tree, what a model
    /// actually reads is "replacing is banned and the only way to write is the
    /// cursor". So "replace the Purpose section with the tighter version"
    /// became a caret write: the tighter version landed wherever the user had
    /// last clicked and the Purpose section stayed exactly where it was.
    ///
    /// The per-world fragments describe the ACT and the locate-first
    /// discipline; the rule itself lives here, next to the roster it governs,
    /// so there is one place to read it and one place to change it.
    static let compositionParadigm = PromptSection(
        id: .compositionParadigm,
        rationale: "Writing vs revising, stated exactly once. Pinned by everyWorkspaceWorldDistinguishesCompositionFromRevision."
    ) { inputs in
        guard !inputs.plugins.isEmpty else { return "" }
        return "\n\n" + """
        Writing and revising are different acts. WRITING is composition — \
        new words that did not exist, going in at the user's cursor as \
        they watch; that is what type_at_cursor is for, and it is right \
        for "write", "draft", "continue", "add something new". REVISING \
        is changing text that is already there — replacing a section, \
        cutting a paragraph, moving a passage, inserting at a named \
        place. A revision never goes in at the cursor: the cursor is \
        wherever the user last clicked, which is almost never the passage \
        they named, so typing a revision leaves the old text standing and \
        puts the new text somewhere else. To revise, LOCATE the named \
        part first with that application's own read, then change exactly \
        that part. Replacing a whole document wholesale is still \
        forbidden; replacing a located passage, inside the bounds you \
        read, is the ordinary way to revise and needs no permission. \
        Never hand-write a script to read, replace, insert or delete part \
        of a document the user is working in — the Skills carry bounds \
        and an undo story; a script carries neither.
        """
    }


    // MARK: - Configuration and per-turn perception

    static let projects = PromptSection(
        id: .projects,
        rationale: "The user's configured projects, sorted."
    ) { inputs in
        guard !inputs.projects.isEmpty else { return "" }
        let list = inputs.projects.keys.sorted().joined(separator: ", ")
        return "\n\nThe user's configured projects are: \(list)."
    }

    /// Ambient notes: one-line stand-ins for a world the focus arbiter
    /// collapsed (e.g. "Scrivener is also open on…"). Plain lines, no header —
    /// a collapsed side must never reactivate its doctrine.
    static let ambientNotes = PromptSection(
        id: .ambientNotes,
        rationale: "Collapsed worlds' routing lines. Headerless on purpose."
    ) { inputs in
        var text = ""
        for note in inputs.ambientNotes {
            text += "\n\n\(note)"
        }
        return text
    }

    /// THE LEAD PLACE'S HEADER — it names the place, and nothing else does.
    ///
    /// Rendering one place's context under another's banner is the single
    /// worst thing this layer can do, because it is invisible to everyone
    /// except the user, who hears Mary confidently describe a document that is
    /// not open. The name comes from the arbiter, which got it from the
    /// roster; there is no ternary here to answer a three-way question with,
    /// and no default to fall back to.
    static let leadHeader = PromptSection(
        id: .leadHeader,
        rationale: "Names the place that owns the live context, so no place renders under another's banner."
    ) { inputs in
        guard !inputs.leadContext.isEmpty, !inputs.leadPlaceName.isEmpty
        else { return "" }
        return "\n\n=== Working in \(inputs.leadPlaceName) ==="
    }

    /// The lead place's watcher contributions, verbatim.
    ///
    /// NO DOCTRINE BLOCK RIDES WITH THEM. There used to be one — a paragraph
    /// of pair-programming instruction that rendered whenever a particular
    /// IDE led — and it was written here, in the prompt layer, naming that
    /// IDE's Skills and its shell and its git habits. Doctrine about how to
    /// work in a place belongs to the package that teaches Mary the place;
    /// this section renders what the place said and adds nothing.
    static let leadSections = PromptSection(
        id: .leadSections,
        rationale: "The lead place's live contributions."
    ) { inputs in
        var text = ""
        for section in inputs.leadContext {
            text += "\n\n\(section)"
        }
        return text
    }

    /// THE MERGED WORLDS — compact lines for places with fresh evidence
    /// beside the lead. The lead's full section states the live work; this
    /// names what ELSE is genuinely in play (recent activity within the
    /// co-active horizon, or a fresh glance), each line carrying its facts'
    /// own bounds and ages. Single-place turns render nothing.
    static let coActiveSections = PromptSection(
        id: .coActiveSections,
        rationale: "Compact context for co-active places — the merged-worlds view beside the lead."
    ) { inputs in
        guard !inputs.coActiveContext.isEmpty else { return "" }
        var text = "\n\n=== Also in play ==="
        for line in inputs.coActiveContext {
            text += "\n\(line)"
        }
        return text
    }

    /// THE AMBIENT CONTEXT STORE, rendered. Everything above describes the
    /// world as it stands THIS INSTANT; this section is what Mary is still
    /// holding from earlier in the conversation — passages she actually read,
    /// and worlds the arbiter collapsed to a routing line.
    ///
    /// It lands after the live sections deliberately: live perception leads,
    /// and a held fact must never be mistaken for the current wording. Each
    /// one carries its own age (`AmbientFact.agePhrase`) so a stale fact
    /// states its age instead of claiming authority.
    ///
    /// TERMINAL: nothing may follow it. Pinned by
    /// `theSystemPromptRendersTheStoreAfterTheLiveSections`.
    static let heldFacts = PromptSection(
        id: .heldFacts,
        rationale: "What she is still holding from earlier, each carrying its age. Lands last.",
        ordering: .last
    ) { inputs in
        MaryPrompts.heldSection(facts: inputs.heldFacts, mentions: inputs.heldMentions)
    }
}
