//
//  ProseStructure.swift
//  MaryBrain
//
//  THE SHAPE OF A PROSE DOCUMENT, read out of the only thing a word processor
//  will hand over: one flat string of characters.
//
//  EXTRACTED FROM `PagesStructure`, UNCHANGED. Every constant, every clause and
//  every ordering rule below arrived here verbatim from that file, which is why
//  `PagesStructureTests` still passes against it without a line edited — that
//  test suite IS the proof this extraction changed nothing. The evidence each
//  rule rests on stays written down beside it; what moved is only the question
//  of WHOSE document is being read.
//
//  WHY IT MOVED. TextEdit hands over exactly the same evidence Pages does — a
//  flat string, no paragraph-style information across the Apple Event boundary,
//  line length and what sits under a line as the entire body of proof. A second
//  copy of this heuristic would be a second reading of the same evidence, and
//  the two would disagree the first time either was tuned. One reading, two
//  callers, each keeping its own header about what its channel can and cannot
//  see.
//
//  A HEURISTIC, AND IT HAS TO BE ONE. The paragraph STYLE that actually knows
//  "this line is a Heading 2" does not cross the Apple Event boundary in either
//  app. What survives the trip is characters. So how long a line is, how it
//  ends, and what sits under it are the entire body of evidence, and this file
//  is a reading of that evidence rather than a parse of a document model.
//
//  ONE COORDINATE SPACE. Every range here is a 0-based, half-open offset in
//  CHARACTERS into the exact string handed in — `PassageSpace.documentText`,
//  the only space in this system. It is NOT AppleScript's `character N`, which
//  is 1-based and inclusive at BOTH ends; it is NOT an AX offset, which counts
//  UTF-16 code units over an element that includes material this string
//  excludes.
//
//  PURE AND TOTAL. No I/O, no actor, no optional standing in for an error, and
//  never an empty array: a body with no headings comes back as its own
//  paragraphs, and a body with nothing in it at all comes back as a single
//  `.window`. An empty unit list would drop every rung of the widening ladder
//  through to a refusal on a document that is sitting right there on screen.
//

import Foundation

/// THE JUDGEMENTS, GATHERED. Every field is a reading of the character
/// evidence, and every one arrived from `PagesStructure` with its arithmetic
/// attached. A world that measures its own prose differently says so by
/// handing in different rules rather than by forking the walk below.
public struct ProseStructureRules: Sendable {

    /// The longest a line can be and still be a NAME rather than a sentence.
    ///
    /// 80 characters is about twelve words at English prose's ~6.5 characters
    /// a word including its space, and twelve words is already generous for
    /// something a person says in one breath when asked "which part?". It also
    /// does double duty in the successor test: a line LONGER than this is a
    /// line that could not itself be a heading, and that is the whole of the
    /// evidence that the short line above it is one.
    public var headingMaxLength: Int

    /// How much longer the line UNDER a candidate heading has to be before its
    /// length alone is evidence: TWICE.
    ///
    /// What this rejects is a RUN of similar short lines with no prose beneath
    /// it — an address block, a signature, a list of names. "Ritesh Rao" over
    /// "New York, NY" is two short unterminated lines, and any test weaker
    /// than a factor of two calls the first a heading and hands the second to
    /// it as a section. Two-fold means the line below has to be a different
    /// KIND of line, not merely a longer one of the same kind.
    ///
    /// It does NOT carry the hard-wrapped-paragraph case, and it was never
    /// asked to: the last line of a wrapped paragraph is short and the first
    /// line of the next one is full width, which clears any ratio at all. What
    /// rejects that line is `terminalMarks` — it ends with the sentence's own
    /// full stop.
    public var headingContrast: Int

    /// A line ending in one of these is a SENTENCE, whatever its length.
    ///
    /// This is the single most load-bearing test in the file: "We met at
    /// noon." is short, unpunctuated in every other way, and sits alone
    /// between blank lines exactly as a heading does. The full stop is the
    /// only thing that tells them apart.
    ///
    /// `:` IS DELIBERATELY ABSENT. A colon-terminated line is a label for what
    /// comes after it — "Purpose:", "Note:" — and even when it is really a
    /// lead-in ("The rules are as follows:") the block it introduces is
    /// exactly the span an editor should be handed for it. Both readings want
    /// the same unit, so the ambiguity costs nothing.
    public var terminalMarks: Set<Character>

    /// A line starting with one of these is a LIST ITEM. A word processor
    /// emits the bullet glyph into its body text for a bulleted list, so
    /// without this a three-word bullet above a paragraph becomes a heading
    /// and the paragraph becomes its section — a structure the document does
    /// not have.
    ///
    /// A numbered list item ("1. First point") is NOT here and cannot be:
    /// nothing in the characters distinguishes it from "1. Introduction". It
    /// resolves as a level-1 heading, which is named in the failure modes
    /// rather than papered over.
    public var bulletMarks: Set<Character>

    /// A heading with no numbering and no typographic rank of its own. 1
    /// rather than 0 because `PassageUnit.level` reserves 0 for "nothing
    /// nests this", and an ordinary heading is nested under any all-caps
    /// banner above it.
    public var defaultLevel: Int

    /// Line breaks that DO NOT end a paragraph.
    ///
    /// A rich-text editor offering Shift-Return writes U+2028 inside one
    /// paragraph — a stanza's lines, an address block, a line of verse.
    /// Splitting on it turns one passage into five and makes "replace that
    /// stanza" unaddressable. Empty is the word-processor reading, where every
    /// break a person can see is a paragraph they can point at.
    public var intraParagraphSeparators: Set<Character>

    /// Whether a short line over a longer one is read as a HEADING.
    ///
    /// True for a document a person formats — a report, a note, a letter.
    /// False for an item inside a manuscript, where a scene's opening line is
    /// short and the line under it is long, and calling that a heading would
    /// emit a `.section` spanning to the next short line. That is not a
    /// refinement of the paragraph answer, it is a different and much larger
    /// range, and `find_passage` would return the rest of the chapter when
    /// asked for the sentence.
    public var detectsHeadings: Bool

    /// Whether a unit spanning the whole document is offered ALONGSIDE the
    /// paragraphs rather than only as the last resort.
    ///
    /// Normally false, and the reason is in `units` below: a whole-document
    /// block is what rung 4 widens into, so offering one is a standing
    /// invitation to replace an entire file. It is safe — and useful — exactly
    /// where the world cannot write at all, and where "documents" are scenes
    /// short enough that "this document" is a thing a person points at.
    public var offersDocumentUnit: Bool

    public init(
        headingMaxLength: Int,
        headingContrast: Int,
        terminalMarks: Set<Character>,
        bulletMarks: Set<Character>,
        defaultLevel: Int,
        intraParagraphSeparators: Set<Character> = [],
        detectsHeadings: Bool = true,
        offersDocumentUnit: Bool = false
    ) {
        self.headingMaxLength = headingMaxLength
        self.headingContrast = headingContrast
        self.terminalMarks = terminalMarks
        self.bulletMarks = bulletMarks
        self.defaultLevel = defaultLevel
        self.intraParagraphSeparators = intraParagraphSeparators
        self.detectsHeadings = detectsHeadings
        self.offersDocumentUnit = offersDocumentUnit
    }

    /// THE MEASURED DEFAULTS — `PagesStructure`'s own numbers, and the ones
    /// every caller uses today. A world that wants different ones must say so
    /// in a commit that says why, the same ceremony the budget pins use.
    public static let prose = ProseStructureRules(
        headingMaxLength: 80,
        headingContrast: 2,
        terminalMarks: [".", "!", "?", ",", ";", "…"],
        bulletMarks: ["•", "‣", "◦", "▪", "·", "-", "–", "—", "*", "+"],
        defaultLevel: 1)

    /// A PROJECT-BACKED CORPUS's prose — an item inside a manuscript rather
    /// than a document on disk.
    ///
    /// Three differences from `.prose`, each measured rather than assumed —
    /// `CorpusProseParityTests` runs both parsers over the user's own project
    /// files and requires identical units.
    ///
    /// The separator: a corpus read out of RTF carries U+2028 for the soft
    /// break its editor offers, and cutting there splits verse mid-stanza.
    ///
    /// No headings: measured on 82 real documents, a scene's short opening
    /// line over a long one reads as a heading to the prose rules, and the
    /// `.section` that follows spans to the next short line — so "replace that
    /// sentence" would return the rest of the chapter. Manuscript items carry
    /// their title in the binder, not in their first line.
    ///
    /// The document unit: a corpus world locates but cannot write — its
    /// application autosaves over anything written underneath it — so a
    /// whole-document unit cannot become an unattended rewrite, and offering
    /// it keeps "the whole of this scene" addressable however little else the
    /// parse can see.
    public static let corpusProse = ProseStructureRules(
        headingMaxLength: 80,
        headingContrast: 2,
        terminalMarks: [".", "!", "?", ",", ";", "…"],
        bulletMarks: ["•", "‣", "◦", "▪", "·", "-", "–", "—", "*", "+"],
        defaultLevel: 1,
        intraParagraphSeparators: ["\u{2028}"],
        detectsHeadings: false,
        offersDocumentUnit: true)

    /// A SCRATCHPAD: every non-empty line is its own unit and nothing is a
    /// heading.
    ///
    /// For an editor a person keeps lists and jottings in rather than prose.
    /// The heading heuristic is exactly wrong there — in a list of short
    /// lines, EVERY line contrasts with its neighbours, so heading detection
    /// would turn each item into a section spanning the ones below it, and
    /// "change the second one" would rewrite the rest of the note.
    ///
    /// A package chooses this by declaring `grammar: "lines"`; nothing infers
    /// it, because whether a document is prose or a list is a fact about how
    /// the person uses the application and not about its text.
    public static let lines = ProseStructureRules(
        headingMaxLength: 80,
        headingContrast: 2,
        terminalMarks: [".", "!", "?", ",", ";", "…"],
        bulletMarks: ["•", "‣", "◦", "▪", "·", "-", "–", "—", "*", "+"],
        defaultLevel: 1,
        detectsHeadings: false,
        offersDocumentUnit: true)
}

public enum ProseStructure {

    // MARK: - The one entry point

    /// The units of `body`, ordered by where they start.
    ///
    /// Sections and the paragraphs inside them BOTH appear — they are
    /// different answers to "which part?", and `PassageWidening` picks between
    /// them with a total order rather than being handed a pre-made choice. A
    /// section carries the heading's own text as its label (the rung 1 match)
    /// and its rank as its level; a paragraph carries neither, because it has
    /// neither.
    ///
    /// The heading line itself is deliberately NOT also emitted as a
    /// paragraph. A heading-only section (a heading with the next heading
    /// directly under it) already has exactly that range, and two units with
    /// identical ranges make `PassageWidening.named`'s
    /// `first(where: { $0.range == candidate.range })` a coin toss between a
    /// `.section` and a `.paragraph` — which decides whether an edit gets
    /// blank lines around it.
    public static func units(
        in body: String, rules: ProseStructureRules = .prose
    ) -> [PassageUnit] {
        let characters = Array(body)
        let lines = textLines(
            of: characters,
            intraParagraphSeparators: rules.intraParagraphSeparators)
        let headings = rules.detectsHeadings
            ? headingFlags(in: lines, rules: rules)
            : [Bool](repeating: false, count: lines.count)

        // Levels once, for the heading lines only: the section walk below asks
        // for them repeatedly and re-parsing a heading per comparison is the
        // difference between a linear file and a quadratic one on a document
        // whose every line is a heading.
        var levels = [Int](repeating: rules.defaultLevel, count: lines.count)
        for index in lines.indices where headings[index] {
            levels[index] = level(of: lines[index].text, rules: rules)
        }

        var units: [PassageUnit] = []

        // A SECTION runs from its heading to the last line of real text before
        // the next heading of the same or higher rank — trailing blank lines
        // excluded, because the blank line under a section belongs to the seam
        // between the two, and swallowing it makes every replacement weld the
        // next heading onto the end of the new text.
        for index in lines.indices where headings[index] {
            let line = lines[index]
            var end = line.range.upperBound
            var cursor = index + 1
            while cursor < lines.count {
                if headings[cursor], levels[cursor] <= levels[index] { break }
                if !lines[cursor].isBlank { end = lines[cursor].range.upperBound }
                cursor += 1
            }
            units.append(PassageUnit(
                range: line.range.lowerBound..<end,
                label: line.text,
                level: levels[index],
                kind: .section))
        }

        // A PARAGRAPH is a line of real text that is not a heading. In a word
        // processor's body text a paragraph IS a line — each one ends with a
        // return and wraps for the page without anything being inserted — so
        // splitting on blank lines alone would return one enormous paragraph
        // for the very common document that separates its paragraphs with a
        // single return, which is most of them.
        for index in lines.indices where !headings[index] && !lines[index].isBlank {
            units.append(PassageUnit(range: lines[index].range, kind: .paragraph))
        }

        // THE WHOLE OF IT, when the world asked for it. Emitted before the
        // sort so document order puts it first at a shared start, and
        // deliberately UNLABELLED at level 0: a guessed label on a unit
        // spanning the document would reach rung 1, the one rung `maxSpan`
        // does not cap, and turn "replace the opening" into a full rewrite.
        //
        // The single-paragraph case is excluded on purpose. Two units over one
        // identical range make `PassageWidening.named`'s first-match a coin
        // toss, and `confidence` reports `.contested` against a twin of itself.
        if rules.offersDocumentUnit, !characters.isEmpty {
            var lower = 0
            var upper = characters.count
            while lower < upper, characters[lower].isWhitespace { lower += 1 }
            while upper > lower, characters[upper - 1].isWhitespace { upper -= 1 }
            let document = lower..<upper
            if !document.isEmpty,
               !(units.count == 1 && units[0].range == document) {
                units.append(PassageUnit(range: document, kind: .window))
            }
        }

        // Document order, outermost first at a shared start — the order
        // `PassageUnit`'s own header promises, and the order a person reads in.
        units.sort {
            $0.range.lowerBound != $1.range.lowerBound
                ? $0.range.lowerBound < $1.range.lowerBound
                : $0.length > $1.length
        }
        guard units.isEmpty else { return units }
        // A world that OFFERS a document unit has already had its chance
        // above, and declined because there was nothing but whitespace. An
        // empty answer is the honest one there: `PassageWidening.locate`
        // tolerates it, and a zero-length window would be a unit naming
        // nothing.
        guard !rules.offersDocumentUnit else { return [] }

        // THE LAST-RESORT UNIT, and why it is last resort. A `.window` over
        // the whole document is a BLOCK unit, and rung 4 of the ladder widens
        // a fragment to the smallest enclosing block — so a whole-document
        // block sitting in this list is a standing invitation to replace the
        // whole document, which is the wholesale clobber every writing plugin
        // in this tree bans by name. It is emitted ONLY when there is not one
        // non-blank line to make a paragraph out of, which is exactly when
        // there is nothing for it to swallow.
        return [PassageUnit(range: 0..<characters.count, kind: .window)]
    }

    // MARK: - Lines

    /// One line of the body, with the whitespace already off both ends.
    ///
    /// The range is TRIMMED because it is the range an edit would replace: a
    /// paragraph unit that carried its own trailing spaces would hand them to
    /// the replacement, and a verbatim quote of the paragraph would then fail
    /// to match the unit it came from.
    public struct Line: Equatable, Sendable {
        /// 0-based, half-open, in the body handed to `units(in:)`.
        public var range: Range<Int>
        /// The line's text, trimmed. Empty means a blank line.
        public var text: String

        public var isBlank: Bool { text.isEmpty }
    }

    /// Split on line boundaries, keeping every line including the blank ones —
    /// a blank line is evidence, not noise: it is half of what says the line
    /// above it was a heading.
    ///
    /// `Character.isNewline` rather than a search for "\n", and the choice is
    /// load-bearing twice over. A CRLF pair is ONE Swift `Character`, so a
    /// body that arrived with Windows line endings still yields offsets that
    /// spell what they point at — the alternative failure is silent, one
    /// character short per line, and a replacement that eats a letter. And it
    /// covers the separator characters a rich-text editor can put in a line
    /// (U+2028 and friends) rather than only the one an editor of source code
    /// would: a break that looks like a line on the page is read as one here,
    /// which is the reading a person asking for "that heading" is using.
    ///
    /// KNOWN, AND HARMLESS: this splitter is more generous than the one
    /// `ParagraphWritePlan` uses, which splits on "\n" alone because that is
    /// what a scripting layer's `paragraph N` counts. A U+2028 therefore makes
    /// a line here and not a paragraph there. That disagreement costs nothing —
    /// structure only PROPOSES a range, and the plan re-derives its paragraphs
    /// from the same body — and where the plan and the app disagree instead,
    /// the write's content guard refuses rather than writing to the wrong index.
    public static func textLines(
        of characters: [Character],
        intraParagraphSeparators: Set<Character> = []
    ) -> [Line] {
        var lines: [Line] = []
        var start = 0

        func emit(_ end: Int) {
            var lower = start
            var upper = end
            while lower < upper, characters[lower].isWhitespace { lower += 1 }
            while upper > lower, characters[upper - 1].isWhitespace { upper -= 1 }
            lines.append(Line(range: lower..<upper, text: String(characters[lower..<upper])))
        }

        var index = 0
        while index < characters.count {
            if characters[index].isNewline,
               !intraParagraphSeparators.contains(characters[index]) {
                emit(index)
                start = index + 1
            }
            index += 1
        }
        // The last line, always — a body ending in a return emits a final
        // blank one, and that blank is what stops the real last line of the
        // document from being read as a heading with nothing under it.
        emit(characters.count)
        return lines
    }

    // MARK: - Headings

    /// Could this line be a NAME at all, before anything under it is
    /// consulted? Short, not a sentence, not a bullet, and with at least one
    /// letter or digit in it — a rule of asterisks is a separator, not a
    /// heading.
    public static func isHeadingShaped(
        _ line: Line, rules: ProseStructureRules = .prose
    ) -> Bool {
        let text = line.text
        guard !text.isEmpty, text.count <= rules.headingMaxLength else { return false }
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        if let first = text.first, rules.bulletMarks.contains(first) { return false }
        if let last = text.last, rules.terminalMarks.contains(last) { return false }
        return true
    }

    /// WHICH LINES ARE HEADINGS. Backwards, in one pass, because the fourth
    /// clause below asks whether the line underneath is a heading and the
    /// answer has to already exist.
    ///
    /// A heading is a heading-shaped line with real text somewhere below it
    /// and one of four things directly under it:
    ///
    ///   - a BLANK LINE. The classic shape, and the one the plain-text export
    ///     of anything produces.
    ///   - ANOTHER HEADING. This is what makes the two shapes of the same
    ///     document agree. A word processor separates paragraphs with a single
    ///     return, so a real document often has no blank lines at all; without
    ///     this clause a title sitting directly above its first heading is read
    ///     as a paragraph in one shape and as a heading in the other, and the
    ///     structure of a document would depend on how its author pressed
    ///     Return.
    ///   - A LINE TOO LONG TO BE A HEADING. Prose. If the thing underneath
    ///     could not be a name, the short unterminated line above it is one.
    ///   - A LINE `headingContrast` TIMES LONGER. The weakest clause, and the
    ///     one carrying short paragraphs.
    ///
    /// "Real text somewhere below it" is not decoration: without it, a body
    /// ending in "Purpose\n" makes a heading out of its own last line and a
    /// section out of nothing at all, and a signature at the foot of a letter
    /// becomes the heading of an empty section.
    public static func headingFlags(
        in lines: [Line], rules: ProseStructureRules = .prose
    ) -> [Bool] {
        var flags = [Bool](repeating: false, count: lines.count)
        guard !lines.isEmpty else { return flags }

        var contentBelow = [Bool](repeating: false, count: lines.count)
        var seen = false
        for index in stride(from: lines.count - 1, through: 0, by: -1) {
            contentBelow[index] = seen
            if !lines[index].isBlank { seen = true }
        }

        for index in stride(from: lines.count - 1, through: 0, by: -1) {
            guard contentBelow[index], isHeadingShaped(lines[index], rules: rules)
            else { continue }
            // `contentBelow` is only true when some later line has text, so
            // there is always a line at index + 1 to look at.
            let next = lines[index + 1]
            flags[index] = next.isBlank
                || flags[index + 1]
                || next.text.count > rules.headingMaxLength
                || next.text.count >= lines[index].text.count * rules.headingContrast
        }
        return flags
    }

    /// HOW HIGH THIS HEADING RANKS — lower outranks higher, and a section runs
    /// until the next heading of the same or higher rank.
    ///
    /// NUMBERING FIRST, because it is the author saying it outright: "5.2"
    /// is two components deep and therefore level 2. A leading part-noun comes
    /// off first ("Section 5.2 Limits", "Chapter 3"), reusing
    /// `PassageWidening.partNouns` — the one list in this tree of words that
    /// name a part of a document rather than naming one. A second list here
    /// would drift from that one the first time either was edited.
    ///
    /// ALL CAPS SECOND, and it means level 0 — a banner outranks every
    /// numbered heading beneath it. This is a typographic hint being read as
    /// rank, which is exactly what a reader does with it, and it is only ever
    /// consulted when the author gave no numbering to read instead.
    ///
    /// KNOWN CONSEQUENCE, pinned by a test rather than hidden: a document
    /// whose only all-caps heading is its title gives that title a section
    /// covering the entire document, since nothing below it ever ranks 0 or
    /// less. That span is correct — it IS everything under the title — but it
    /// is also a very large `.section`, and rung 3 of the ladder (token
    /// overlap) has no `maxSpan` valve on it. Naming the title is therefore a
    /// way to ask for the whole document, and it should be.
    public static func level(
        of text: String, rules: ProseStructureRules = .prose
    ) -> Int {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count > 1, PassageWidening.partNouns.contains(PassageWidening.fold(words[0])) {
            words.removeFirst()
        }
        if let token = words.first {
            let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: ".()[]"))
            let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
            if !parts.isEmpty,
               parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
                return parts.count
            }
        }
        // At least two letters before calling it a banner: a one-letter line
        // is uppercase by accident as often as by intent.
        let letters = text.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return 0 }
        return rules.defaultLevel
    }
}
