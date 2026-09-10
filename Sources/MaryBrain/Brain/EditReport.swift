//
//  EditReport.swift
//  MaryBrain
//
//  WHAT: What she says after she changes the user's words.
//  IN:   joined revision outcomes + LocatedPassage
//  OUT:  spoken report (or nil = this turn has nothing to report)
//  PIN:  Confirmed edits only; a silent miss is still a miss.
//
import Foundation

/// The deterministic sentence a revision speaks about itself, and the shape it
/// speaks it in.
public struct EditReport: Sendable, Equatable {

    public enum Shape: String, Sendable, Equatable {
        /// Their own words named one thing and it matched whole.
        case replaced
        /// Same act, but WE chose which passage it was — `LocatedPassage.widened`.
        /// The only shape that offers the way back.
        case replacedAfterChoosing
        case inserted
        case deleted
        case moved
        /// A change was SENT and nothing confirmed it — neither "Done" nor a
        /// failure, and it may not borrow either one's words.
        case unconfirmedEdit
        /// She meant to revise, could not find the part, and typed instead.
        case couldNotLocate
    }

    public var shape: Shape
    /// Spoken as-is. One sentence in the ordinary case, two when she chose.
    public var sentence: String

    public init(shape: Shape, sentence: String) {
        self.shape = shape
        self.sentence = sentence
    }

    // MARK: - Which skills count as a revision

    /// THE PASSAGE EDIT VERBS, named explicitly rather than sniffed from a description
    static let replaceSkill = "replace_passage"
    static let insertSkill = "insert_passage"
    static let deleteSkill = "delete_passage"
    static let editSkills: Set<String> = [replaceSkill, insertSkill, deleteSkill]

    // MARK: - Building it

    /// The one entry point. Nil means THIS TURN HAS NOTHING TO REPORT, and nil is the common answer — every ordinary action turn, every read, every conversation.
    /// PIN: `performed`'s own comment below already argued the opposite principle
    static func report(
        intent: EditIntent?,
        target: LocatedPassage?,
        writingTarget: AmbientWritingTarget? = nil,
        acceptedOffer: Bool = false,
        outcomes: [MaryBrain.LaneOutcome]
    ) -> EditReport? {
        if writingTarget == .selection,
           outcomes.contains(where: {
               $0.ok && !$0.deferred && $0.skillName == "type_at_cursor"
           }) {
            return EditReport(
                shape: .replaced,
                sentence: "Done — I revised the selected text.")
        }
        // CONFIRMED edits only. `ok` alone let this filter fabricate "Done
        let edits = outcomes.filter {
            $0.ok && !$0.deferred && editSkills.contains($0.skillName)
        }
        let landed = edits.filter {
            $0.editDisposition != .unconfirmed && $0.editDisposition != .unchanged
        }
        guard landed.isEmpty else {
            return performed(landed, target: target)
        }
        if edits.contains(where: { $0.editDisposition == .unconfirmed }) {
            let whereItIs = target.map {
                $0.documentTitle.isEmpty ? "" : " in \($0.documentTitle)"
            } ?? ""
            return EditReport(
                shape: .unconfirmedEdit,
                sentence: "I sent that change\(whereItIs) and couldn't confirm "
                    + "it landed — take a look before going on.")
        }

        // Nothing was revised. The ONE case still worth a sentence is the shipped failure's own shape: she meant to revise, had no passage to revise
        guard intent != nil, target == nil,
              outcomes.contains(where: {
                  $0.ok && MaryBrain.caretWriteSkills.contains($0.skillName)
              })
        else {
            // THE ACCEPTED-OFFER SILENT MISS. An offer the user said yes to, followed by a turn that landed no edit and typed nothing
            guard acceptedOffer else { return nil }
            return EditReport(
                shape: .couldNotLocate,
                sentence: "I couldn't find the passage we were talking about again — "
                    + "nothing was changed. Select it, or name the part, and I'll do it.")
        }
        // On an accepted offer the synthesized intent's one target is the
        // whole discussed paragraph — `missSentence` must not recite it.
        return EditReport(
            shape: .couldNotLocate,
            sentence: acceptedOffer
                ? missSentence(intent: nil, called: "the passage we were discussing")
                : missSentence(intent: intent))
    }

    /// A change that landed. WHICH change is read off the skills that ran, not off the intent
    private static func performed(
        _ landed: [MaryBrain.LaneOutcome], target: LocatedPassage?
    ) -> EditReport {
        let skills = Set(landed.map(\.skillName))
        // A MOVE HAS NO RECIPE OF ITS OWN, and that is not an oversight: moving a passage IS taking it out of one place and putting it in another
        let shape: Shape
        if skills.contains(deleteSkill) && skills.contains(insertSkill) {
            shape = .moved
        } else if skills.contains(deleteSkill) {
            shape = .deleted
        } else if skills.contains(insertSkill) {
            shape = .inserted
        } else if target?.widened == true {
            shape = .replacedAfterChoosing
        } else {
            shape = .replaced
        }

        let part = edgePhrase(target)
        let whereItIs = target.map { $0.documentTitle.isEmpty ? "" : " in \($0.documentTitle)" } ?? ""
        var sentence: String
        switch shape {
        case .replaced, .replacedAfterChoosing:
            sentence = "Done — I replaced \(part)\(whereItIs)."
        case .inserted:
            sentence = "Done — I added the new wording next to \(part)\(whereItIs)."
        case .deleted:
            sentence = "Done — I took out \(part)\(whereItIs)."
        case .moved:
            sentence = "Done — I moved \(part)\(whereItIs)."
        case .couldNotLocate, .unconfirmedEdit:
            sentence = ""   // unreachable: this arm only runs on a landed edit
        }
        // THE OFFER, and ONLY here. `widened` is false on exactly one shape — the first thing they called it, matched once and matched whole.
        if target?.widened == true {
            sentence += " Their words matched more than one place and I took that one — say undo if I picked wrong."
        }
        return EditReport(shape: shape, sentence: sentence)
    }

    // MARK: - The edges

    /// How many words at each end. Five is what it takes to recognise a
    /// sentence you wrote and short enough that two of them fit inside one
    /// spoken clause without the clause becoming a recitation.
    static let edgeWords = 5

    /// The passage said as a person would say it: what it started with, what it ended with, and roughly how much.
    static func edgePhrase(_ target: LocatedPassage?) -> String {
        guard let target else { return "the part they meant" }
        let words = target.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return "the part they meant" }
        if words.count <= edgeWords * 2 {
            return "the part that read \"\(words.joined(separator: " "))\""
        }
        let opening = words.prefix(edgeWords).joined(separator: " ")
        let closing = words.suffix(edgeWords).joined(separator: " ")
        return "the part starting \"\(opening)\" and ending \"\(closing)\", \(extent(words.count))"
    }

    /// ROUGHLY HOW MUCH — `LocatedPassage.boundsLabel`'s arithmetic, reached through its own constant rather than copied.
    static func extent(_ wordCount: Int) -> String {
        let counted = wordCount <= LocatedPassage.exactWordCount
            ? wordCount
            : Int((Double(wordCount) / 10).rounded()) * 10
        return "about \(counted) word\(counted == 1 ? "" : "s")"
    }

    // MARK: - The miss

    /// `PagesPlugin.targetedOutcome`'s honest miss names the two reasons a perfectly real passage fails to be found
    static func missSentence(intent: EditIntent?, called override: String? = nil) -> String {
        let named = intent?.target.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let called = override ?? (named.isEmpty ? "the part you meant" : "\"\(named)\"")
        return "I couldn't find \(called) to change — the wording may differ from what you said, "
            + "or it may sit in a header, a text box or a table cell I can't read from here. "
            + "I've put the new words in at your cursor instead, so take a look before you keep going."
    }
}
