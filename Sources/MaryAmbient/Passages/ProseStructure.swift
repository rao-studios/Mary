//
//  ProseStructure.swift
//  MaryBrain
//
//  WHAT: Shape of a prose document from one flat string of characters.
//  IN:   extracted from PagesStructure, unchanged
//  OUT:  PassageUnit[]. Callers: Pages / TextEdit
//  PIN:  One heuristic for the same evidence. PagesStructureTests still pass against it.
//

import Foundation

/// THE JUDGEMENTS, GATHERED. Every field is a reading of the character evidence, and every
/// one arrived from `PagesStructure` with its arithmetic attached.
public struct ProseStructureRules: Sendable {

    /// The longest a line can be and still be a NAME rather than a sentence. 80 characters is
    /// about twelve words at English prose's ~6.5 characters a word including its space.
    public var headingMaxLength: Int

    /// How much longer the line UNDER a candidate heading has to be before its length alone is
    /// evidence: TWICE. What this rejects is a RUN of similar short lines with no prose beneath
    /// it — an address block, a signature, a list of names.
    public var headingContrast: Int

    /// A line ending in one of these is a SENTENCE, whatever its length. This is the single
    /// most load-bearing test in the file: "We met at noon." is short, unpunctuated in every
    /// other way.
    public var terminalMarks: Set<Character>

    /// A line starting with one of these is a LIST ITEM.
    public var bulletMarks: Set<Character>

    /// A heading with no numbering and no typographic rank of its own. 1 rather than 0 because
    /// `PassageUnit.level` reserves 0 for "nothing nests this", and an ordinary heading is
    /// nested under any all-caps banner above it.
    public var defaultLevel: Int

    /// Line breaks that DO NOT end a paragraph. A rich-text editor offering Shift-Return writes
    /// U+2028 inside one paragraph.
    public var intraParagraphSeparators: Set<Character>

    /// Whether a short line over a longer one is read as a HEADING. True for a document a
    /// person formats — a report, a note, a letter.
    public var detectsHeadings: Bool

    /// Whether a unit spanning the whole document is offered ALONGSIDE the paragraphs rather
    /// than only as the last resort. Normally false.
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

    /// A PROJECT-BACKED CORPUS's prose.
    public static let corpusProse = ProseStructureRules(
        headingMaxLength: 80,
        headingContrast: 2,
        terminalMarks: [".", "!", "?", ",", ";", "…"],
        bulletMarks: ["•", "‣", "◦", "▪", "·", "-", "–", "—", "*", "+"],
        defaultLevel: 1,
        intraParagraphSeparators: ["\u{2028}"],
        detectsHeadings: false,
        offersDocumentUnit: true)

    /// A SCRATCHPAD: every non-empty line is its own unit and nothing is a heading. For an
    /// editor a person keeps lists and jottings in rather than prose.
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

    /// The units of `body`, ordered by where they start. Sections and the paragraphs inside
    /// them BOTH appear — they are different answers to "which part?", and `PassageWidening`
    /// picks between them with a total order rather than being handed a pre-made choice.
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

        // Levels once, for the heading lines only: the section walk below asks for them repeatedly
        // and re-parsing a heading per comparison is the difference between a linear file and a
        // quadratic one on a document whose every line is a heading.
        var levels = [Int](repeating: rules.defaultLevel, count: lines.count)
        for index in lines.indices where headings[index] {
            levels[index] = level(of: lines[index].text, rules: rules)
        }

        var units: [PassageUnit] = []

        // A SECTION runs from its heading to the last line of real text before the next heading of
        // the same or higher rank.
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

        // A PARAGRAPH is a line of real text that is not a heading.
        for index in lines.indices where !headings[index] && !lines[index].isBlank {
            units.append(PassageUnit(range: lines[index].range, kind: .paragraph))
        }

        // THE WHOLE OF IT, when the world asked for it. The single-paragraph case is excluded on
        // purpose. Two units over one identical range make `PassageWidening.named`'s first-match a
        // coin toss, and `confidence` reports `.contested` against a twin of itself.
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
        // A world that OFFERS a document unit has already had its chance above, and declined
        // because there was nothing but whitespace.
        guard !rules.offersDocumentUnit else { return [] }

        // THE LAST-RESORT UNIT, and why it is last resort.
        return [PassageUnit(range: 0..<characters.count, kind: .window)]
    }

    // MARK: - Lines

    /// One line of the body, with the whitespace already off both ends. The range is TRIMMED
    /// because it is the range an edit would replace: a paragraph unit that carried its own
    /// trailing spaces would hand them to the replacement.
    public struct Line: Equatable, Sendable {
        /// 0-based, half-open, in the body handed to `units(in:)`.
        public var range: Range<Int>
        /// The line's text, trimmed. Empty means a blank line.
        public var text: String

        public var isBlank: Bool { text.isEmpty }
    }

    /// Split on line boundaries, keeping every line including the blank ones.
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

    /// Could this line be a NAME at all, before anything under it is consulted? Short, not a
    /// sentence, not a bullet, and with at least one letter or digit in it — a rule of
    /// asterisks is a separator, not a heading.
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

    /// WHICH LINES ARE HEADINGS. Backwards, in one pass.
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

    /// HOW HIGH THIS HEADING RANKS — lower outranks higher, and a section runs until the next
    /// heading of the same or higher rank. NUMBERING FIRST, because it is the author saying it
    /// outright: "5.2" is two components deep and therefore level 2.
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
