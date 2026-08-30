//
//  MaryRuntime+Focus.swift
//  MaryRuntime
//
//  WHAT: The turn's one focus decision — prompt, roster, deposit all read this.
//  IN:   observers that contributed this turn → WorkspaceFocusArbiter
//  OUT:  PromptSections, leadPlace, DepositSubject
//  PIN:  One loop over contributions. Adding an application adds nothing here.
//

import AppKit
import Foundation
import MaryPlugin
import MaryAmbient
import MaryBrain
import MaryFoundation

/// What the focus decision needs beyond the live ambient layer.
struct FocusResolutionContext: Sendable {
    /// Activated observers, catalog order. Who contributed is asked per turn.
    let observers: [any MaryObserver]
}

extension MaryRuntime {

    /// The turn's focus decision.
    /// - Parameter assertedFocus: utterance override for this turn only.
    static func resolveFocus(
        assertedFocus: WorkspaceFocus? = nil,
        deps: FocusResolutionContext
    ) -> (
        sections: WorkspaceFocusArbiter.PromptSections,
        leadOwner: String?,
        subject: DepositSubject,
        /// Where the turn leads. Nil is a real turn, not a failed decision.
        leadPlace: AmbientPlace?
    ) {
        let tracker = WorkspaceFocusTracker.shared
        let index = AmbientApplicationIndexProvider.current
        let signal = tracker.signal()

        // Observer contributes because it had something to say, not because the app is running.
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
                    // Whole document vs window — asked of the declaration.
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

    /// Deposit filing. Unfocused is real — do not attach to last-open document.
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
