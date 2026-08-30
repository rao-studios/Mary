//
//  MaryBrain+Types.swift
//  MaryBrain
//
//  WHAT: Nested judgement types — RevisionVeto, LocatedArtifact, WorldVeto.
//  IN:   MaryBrain.swift
//  OUT:  locateTarget / revisionReport consumers
//  PIN:  Instance methods stay with the actor's turn machinery.
//
import MaryVoice
import Foundation

extension MaryBrain {

    /// G3, factored — the revision veto, as a judgement rather than as a copy.
    struct RevisionVeto {
        private let target: LocatedPassage?
        private var spent = false

        init(target: LocatedPassage?) {
            self.target = target
        }

        /// The synthetic Skill result to answer this call with INSTEAD of dispatching it, or nil to dispatch normally. Consumes the single allowance when it answers.
        mutating func redirect(for skillName: String) -> String? {
            guard let target, !spent,
                  MaryBrain.caretWriteSkills.contains(skillName) else { return nil }
            spent = true
            return target.brief.redirect
        }
    }

    /// G3 FOR THE WORLD BOUNDARY — `RevisionVeto`'s third sibling.
    /// Same two bounds as both siblings: no arming, no veto (a turn that is not writing-led, or a lead with no targeted read
    struct WorldVeto {
        struct Arming: Sendable {
            /// The leading writing world this turn belongs to.
            var lead: AmbientWorld
            /// Worlds this turn's words re-admitted — named, referent, or
            /// mentioned. A call into any of these is the user's own ask.
            var admitted: Set<AmbientWorld>
            /// The lead's targeted read, for the redirect sentence.
            var read: (binding: String, parameter: String)
        }

        private let arming: Arming?
        private var spent = false

        init(arming: Arming?) {
            self.arming = arming
        }

        /// The synthetic Skill result to answer this call with INSTEAD of dispatching it, or nil to dispatch normally.
        mutating func redirect(for skillName: String, world: AmbientWorld?) -> String? {
            guard let arming, !spent, let world, world.hasEyes,
                  world != arming.lead,
                  !arming.admitted.contains(world) else { return nil }
            spent = true
            return "Nothing ran in \(world.displayName) — the user's work this turn is "
                + "the \(arming.lead.displayName) document in front of them. Look there "
                + "instead: call \(arming.read.binding) with \(arming.read.parameter) set "
                + "to the words they used, or without it for the whole document."
        }
    }

    // What an invocation needs of its target is DECLARED now — the domain's
    // `verbRequirements` table, consumed through the turn lexicon's
    // `requirements(forUtterance:)`. The engine carries no verb table.

    /// THE SKILLS THAT WRITE AT THE CARET — the whole set, named explicitly.
    static let caretWriteSkills: Set<String> = ["type_at_cursor", "resume_typing"]
}
