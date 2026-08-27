//
//  MaryRuntime+Focus.swift
//  MaryRuntime
//
//  THE TURN'S ONE FOCUS DECISION, made once and read by everything.
//
//  The prompt sections, the roster hoist and the deposit subject all derive
//  from the SAME contributions and the SAME effective focus, so they cannot
//  disagree. The divergence that rule exists to prevent was real and looked
//  like this: the prompt led with one place off a stale watcher line while the
//  roster hoisted a different place's Skills, and the model was handed one
//  application's document and another application's verbs.
//
//  WHAT THIS FILE USED TO BE. Five named watchers — an IDE, three editors, a
//  presentation app — each with its own support-plugin list, threaded through
//  a nine-field context struct so a nested closure could capture them. Every
//  application Mary learned meant a field here, a watcher there, and a branch
//  in the resolution. None of that survives, because none of it can be true
//  in a system where applications arrive as declarations: there is no fixed
//  set to have a field per member of.
//
//  WHAT REPLACES IT is one loop over the observers that actually contributed
//  something this turn, handed to the arbiter as `Contribution` values. An
//  observer knows which place it speaks for and what it can say; the arbiter
//  decides which one leads. Adding an application adds nothing to either.
//

import AppKit
import Foundation
import MaryAdapters
import MaryAmbient
import MaryBrain
import MaryFoundation

/// What the focus decision needs beyond the live ambient layer.
///
/// ONE FIELD. Its predecessor had nine, eight of which named an application.
struct FocusResolutionContext: Sendable {
    /// Every activated observer, in catalog order. Which of them CONTRIBUTED
    /// is a per-turn question, asked below rather than frozen here.
    let observers: [any MaryObserver]
}

extension MaryRuntime {

    /// The turn's focus decision.
    ///
    /// - Parameter assertedFocus: the utterance's own override, when the turn
    ///   named a discipline outright. It beats the ambient signal for this
    ///   turn only — "if I do say it, it must work" — and never touches the
    ///   persistent tracker.
    static func resolveFocus(
        assertedFocus: WorkspaceFocus? = nil,
        deps: FocusResolutionContext
    ) -> (
        sections: WorkspaceFocusArbiter.PromptSections,
        leadOwner: String?,
        subject: DepositSubject,
        /// WHERE the turn leads, as ONE value. Nil when nothing leads, which
        /// is a real turn rather than a failure to decide.
        leadPlace: AmbientPlace?
    ) {
        let tracker = WorkspaceFocusTracker.shared
        let index = AmbientApplicationIndexProvider.current
        let signal = tracker.signal()

        // WHO SPOKE THIS TURN. An observer contributes because it had
        // something to say, not because its application is running — the
        // distinction `writingInPlay` exists for, one layer down.
        let contributions: [WorkspaceFocusArbiter.Contribution] = deps.observers
            .compactMap { observer -> WorkspaceFocusArbiter.Contribution? in
                guard let place = observer.observedPlace else { return nil }
                let registration = index.registration(place: place)
                let full = observer.promptContribution().map { [$0] } ?? []
                guard !full.isEmpty || observer.ambientLine != nil else { return nil }
                return WorkspaceFocusArbiter.Contribution(
                    place: place,
                    discipline: place.focus,
                    full: full,
                    ambient: observer.ambientLine,
                    // WHOLE OR A WINDOW, asked of the declaration. A prose
                    // surface that answers with the entire text holds the
                    // whole document; one that answers with the current
                    // outline item holds a window onto it.
                    liveDocumentIsWhole: registration?.observesDocuments == true
                        ? observer.holdsWholeDocument : nil,
                    wasNamed: false)
            }

        let sections = WorkspaceFocusArbiter.sections(
            focus: assertedFocus ?? signal.lead?.focus,
            contributions: contributions)

        let lead = sections.leadPlace ?? signal.lead
        return (
            sections: sections,
            leadOwner: lead?.application,
            subject: depositSubject(for: lead, index: index),
            leadPlace: lead)
    }

    /// What a deposit made this turn is FILED UNDER.
    ///
    /// UNFOCUSED IS A REAL ANSWER. A turn with no leading place produced no
    /// document-scoped knowledge, and filing it under whatever was open last
    /// is how a calendar answer ends up attached to somebody's manuscript.
    static func depositSubject(
        for place: AmbientPlace?, index: any AmbientApplicationIndex
    ) -> DepositSubject {
        guard let place, let id = place.application else { return .unfocused }
        return DepositSubject(
            app: id,
            documentIdentity: nil,
            contentKind: .document,
            capturedAt: Date())
    }
}
