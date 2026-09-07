//
//  PromptCatalog+System.swift
//  MaryBrain
//
//  WHAT: Skill-lane prompt sections.
//  IN:   MaryPrompts.system literals (byte-identical)
//  OUT:  PromptPlan.full
//  PIN:  Each section emits its own leading separator. Do not edit """ bodies.
//
import Foundation

extension PromptCatalog {

    /// Both lanes, one registry. Shared section types; different prose on purpose.
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
        rationale: "Who she is. Always first; no leading separator. Sewn identity rides SewnWire.Persona."
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

    /// Named Ability Skills lead. Single newline before "Named Skills are" is not a paragraph break.
    /// PIN: Do not describe run_shell / run_applescript as reachable — reserved names only.
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
        shows. A generic look at the open project — "what's this", "how is \
        this laid out", "explore the codebase" — already has the file \
        neighbourhood in the live section from the corpus crawl; widen with \
        search_corpus or read_corpus_outline rather than guessing past it. Destructive commands (deleting files, killing processes, \
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

    /// CONFIRM protocol. Static despite interpolating two compile-time constants.
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

    /// Adapter roster lines. Labels are diagnostic identity, never callable names.
    static let rosterHeader = PromptSection(
        id: .rosterHeader,
        rationale: "One line per installed adapter; not a callable Skill name."
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

    /// Every fragment after every roster line — same order as the original `+=`.
    /// PIN: Interleaving would read the same and render differently.
    static let rosterFragments = PromptSection(
        id: .rosterFragments,
        rationale: "Each plugin promptFragment — the roster's real cost."
    ) { inputs in
        guard !inputs.plugins.isEmpty else { return "" }
        var text = ""
        // Skip fragments for owners the lead scoped out of the schema roster.
        for plugin in inputs.plugins
        where !inputs.standingDownFragmentOwners.contains(plugin.name) {
            if let fragment = plugin.promptFragment {
                text += "\n\n\(fragment)"
            }
        }
        return text
    }

    /// Eyes are an upgrade, never a precondition. Stated beside the roster it governs.
    static let eyesDoctrine = PromptSection(
        id: .eyesDoctrine,
        rationale: "Eyes are an upgrade, never a precondition."
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

    /// Writing vs revising, stated once beside the roster.
    /// PIN: A revision never goes in at the cursor.
    static let compositionParadigm = PromptSection(
        id: .compositionParadigm,
        rationale: "Writing vs revising, stated once beside the roster."
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

    /// Ambient notes: one-line stand-ins for a collapsed world. Headerless on purpose.
    /// PIN: A collapsed side must never reactivate its doctrine.
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

    /// Lead place header — it names the place, and nothing else does.
    static let leadHeader = PromptSection(
        id: .leadHeader,
        rationale: "Names the place that owns the live context."
    ) { inputs in
        guard !inputs.leadContext.isEmpty, !inputs.leadPlaceName.isEmpty
        else { return "" }
        return "\n\n=== Working in \(inputs.leadPlaceName) ==="
    }

    /// Lead place watcher contributions, verbatim. No doctrine block rides with them.
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

    /// Compact lines for co-active places beside the lead. Single-place turns render nothing.
    static let coActiveSections = PromptSection(
        id: .coActiveSections,
        rationale: "Co-active places — compact lines beside the lead."
    ) { inputs in
        guard !inputs.coActiveContext.isEmpty else { return "" }
        var text = "\n\n=== Also in play ==="
        for line in inputs.coActiveContext {
            text += "\n\(line)"
        }
        return text
    }

    /// Held facts from earlier. Live perception leads; each fact carries its age.
    /// PIN: Terminal — `theSystemPromptRendersTheStoreAfterTheLiveSections`.
    static let heldFacts = PromptSection(
        id: .heldFacts,
        rationale: "Held facts from earlier, each with its age. Lands last.",
        ordering: .last
    ) { inputs in
        MaryPrompts.heldSection(facts: inputs.heldFacts, mentions: inputs.heldMentions)
    }
}
