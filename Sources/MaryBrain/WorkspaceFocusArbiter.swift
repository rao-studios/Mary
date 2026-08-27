//
//  WorkspaceFocusArbiter.swift
//  MaryBrain
//
//  WHICH PLACE GETS THE FULL PROMPT SECTION when more than one is live, and
//  what the others get instead.
//
//  Pure arbitration, mechanical rather than prompt-begging. The side matching
//  the user's evident intention rides FULL — context, doctrine, roster
//  position — and every other live place collapses to ONE ambient routing
//  line. The failure that forced this into existence: a question about a
//  manuscript answered through an editor's window text, because whichever
//  doctrine happened to be listed first always dominated.
//
//  THREE INVARIANTS, and the tests hold all three:
//    1. Two full sections never coexist.
//    2. A place that is live is never silenced ENTIRELY — full or ambient,
//       never nothing. Demotion is a change of volume, not an erasure.
//    3. No signal at all → nothing leads. Not "the first one", not "the usual
//       one": `.unled`, and a voice with no place to claim claims none.
//
//  WHAT THIS FILE DOES NOT DO ANY MORE. It used to arbitrate between four
//  NAMED editors and one NAMED IDE, with a hand-ordered list and an asymmetry
//  rule about which of them could outvote a stale tracker. Every line of that
//  was a closed enum of applications wearing a policy costume, and it produced
//  the exact bug it was written to prevent — a session in one editor handed
//  another editor's doctrine because a default field said so. Here a place is
//  a place; the roster names it, the registration declares its discipline, and
//  the arbitration is about DISCIPLINES, of which there are two, closedly.
//

import Foundation
import MaryAmbient

public enum WorkspaceFocusArbiter {

    /// What the prompt renders, decided here rather than re-derived by
    /// whoever renders it.
    public struct PromptSections: Sendable, Equatable {
        /// The lead place's own lines, in full.
        public var leadContext: [String]
        /// One routing line per live place that did not lead. Never empty when
        /// a second place was live — see invariant 2.
        public var ambientNotes: [String]
        /// WHO OWNS `leadContext`. Nil exactly when `leadContext` is empty.
        public var leadPlace: AmbientPlace?
        /// WHERE THE LIVE WORK CAME FROM — stated by the branch that decided
        /// it.
        ///
        /// DELIBERATELY NOT DEFAULTED, and that is the point of the type. The
        /// version this replaces gave the equivalent field a default, four of
        /// five return paths never assigned it, and a downstream ternary read
        /// that silence as an answer — which is how a browser turn came to
        /// claim it was looking at a manuscript. A field with no default
        /// cannot be forgotten: the compiler asks every branch, including the
        /// next one somebody adds.
        public var liveWorld: LiveWorkWorld

        public init(
            leadContext: [String] = [],
            ambientNotes: [String] = [],
            leadPlace: AmbientPlace? = nil,
            liveWorld: LiveWorkWorld
        ) {
            self.leadContext = leadContext
            self.ambientNotes = ambientNotes
            self.leadPlace = leadPlace
            self.liveWorld = liveWorld
        }
    }

    /// One live place's contribution, as its own watcher rendered it.
    ///
    /// THE LINES ARRIVE ALREADY RENDERED, because turning a live document into
    /// a sentence needs to know what that document looks like and only the
    /// adapter behind the place does. The prompt layer that consumes this must
    /// not learn a single application's shape, and taking strings is how that
    /// stays true.
    public struct Contribution: Sendable, Equatable {
        public var place: AmbientPlace
        /// The discipline this place registers for. Nil when the roster does
        /// not know — such a place can be ambient but can never lead, because
        /// leading means answering "is the user writing or coding" and an
        /// unknown discipline answers neither.
        public var discipline: WorkspaceFocus?
        /// The full section, if this place leads.
        public var full: [String]
        /// The one-line version, if it does not. Nil collapses to silence,
        /// which invariant 2 forbids for a live place — so a watcher that can
        /// contribute a full section must be able to contribute a line.
        public var ambient: String?
        /// This place has a LIVE DOCUMENT open, rather than a pile of
        /// deposits — and whether Mary holds the whole of it or a window onto
        /// part of it. Nil means deposits. See `LiveWorkWorld.document`.
        public var liveDocumentIsWhole: Bool?
        /// The user NAMED this place this turn (a literal name, or a routed
        /// selection that settled it).
        public var wasNamed: Bool

        public init(
            place: AmbientPlace,
            discipline: WorkspaceFocus? = nil,
            full: [String] = [],
            ambient: String? = nil,
            liveDocumentIsWhole: Bool? = nil,
            wasNamed: Bool = false
        ) {
            self.place = place
            self.discipline = discipline
            self.full = full
            self.ambient = ambient
            self.liveDocumentIsWhole = liveDocumentIsWhole
            self.wasNamed = wasNamed
        }

        /// A place with nothing to say is not live. Merely being OPEN is not a
        /// contribution — see `writingInPlay`.
        public var isLive: Bool { !full.isEmpty || ambient != nil }
    }

    // MARK: - Which discipline leads

    /// Which side leads.
    ///
    /// Focus wins only when its side actually CONTRIBUTED something this turn;
    /// otherwise the other side takes over. `hasCoding`/`hasWriting` must come
    /// from the contribution result rather than from "is such an app running",
    /// because a watcher can contribute with no live document (a stale-build
    /// warning) and an open application can contribute nothing at all.
    ///
    /// `writingInPlay` separates "the user is writing" from "a writing app is
    /// open". THE FAILURE IT FIXES, traced: writing watchers contribute
    /// whenever their application is RUNNING, so with nothing pointing at
    /// coding, a document nobody had touched took the full lead on every turn
    /// — handing the voice a live-document authority block, scoping retrieval
    /// to that document's group, and filing deposits under it, on questions
    /// that had nothing to do with it. Being open is not evidence of intent.
    ///
    /// It only ever governs the FALL-THROUGH. An explicit `.writing` focus —
    /// window truth, a pin, or the turn's own "add a scene…" override — still
    /// leads unconditionally, so "if I do name it, it must work" is untouched.
    /// A gated-out side is never silenced; it gets its ambient line like any
    /// collapsed place.
    public static func lead(
        focus: WorkspaceFocus?, hasCoding: Bool, hasWriting: Bool,
        writingInPlay: Bool = true,
        strictFocus: Bool = false
    ) -> WorkspaceFocus? {
        switch focus {
        case .writing:
            return hasWriting ? .writing : (strictFocus ? nil : (hasCoding ? .coding : nil))
        case .coding:
            if hasCoding { return .coding }
            return !strictFocus && hasWriting && writingInPlay ? .writing : nil
        case nil:
            if hasCoding { return .coding }
            return (hasWriting && writingInPlay) ? .writing : nil
        }
    }

    // MARK: - Which place leads

    /// The place that owns the lead discipline's full section.
    ///
    /// A NAME IS AN ADDRESS, NOT A SIGNAL, and that is the one asymmetry left
    /// in this file. Contribution presence is evidence about where the user
    /// is, and evidence can be outvoted; a place the user NAMED is not
    /// evidence at all. THE FAILURE THIS FIXES, from a live transcript: "no no
    /// no can you do it in Pages", with that application closed and another
    /// editor open. The closed one contributed nothing — a closed application
    /// has no watcher — so the open one was the sole contributor, took the
    /// turn, failed, and only a recovery round reached the place the user had
    /// actually said. Absence of a contribution is exactly what naming a
    /// closed application looks like, so a named place wins even with nothing
    /// to show for itself.
    public static func leadPlace(
        among contributions: [Contribution],
        discipline: WorkspaceFocus?
    ) -> Contribution? {
        guard let discipline else { return nil }
        let eligible = contributions.filter { $0.discipline == discipline }
        if let named = eligible.first(where: \.wasNamed) { return named }
        // A full section beats a one-liner; among equals, the first in the
        // caller's order. FIXED ORDER, NOT A DICTIONARY: ambient notes render
        // in list order and the golden prompts compare bytes, so a hash-seeded
        // iteration would make the prompt's own text vary between launches.
        return eligible.first(where: { !$0.full.isEmpty }) ?? eligible.first
    }

    // MARK: - The whole arbitration

    /// - Parameters:
    ///   - contributions: every live place, in a stable caller-chosen order.
    ///   - suppressFullSections: a place outside this arbitration owns the
    ///     turn. Watchers may still contribute one-line reachability notes,
    ///     but none may assert that its document is the live work Mary is
    ///     looking at.
    public static func sections(
        focus: WorkspaceFocus?,
        contributions: [Contribution],
        writingInPlay: Bool = true,
        strictFocus: Bool = false,
        suppressFullSections: Bool = false,
        /// The place that owns the turn when full sections are suppressed, and
        /// what the user calls it. Resolving a display name needs the roster,
        /// which the prompt layer must not learn — so it arrives rendered.
        suppressingPlace: AmbientPlace? = nil,
        suppressingName: String? = nil
    ) -> PromptSections {
        let live = contributions.filter(\.isLive)

        // EVERY LIVE PLACE SPEAKS, at one volume or the other. Built first so
        // that no return path below can forget it — invariant 2 is a property
        // of this function, not a habit of its branches.
        func ambientLines(excluding lead: AmbientPlace?) -> [String] {
            live.compactMap { contribution in
                contribution.place == lead ? nil : contribution.ambient
            }
        }

        if suppressFullSections {
            return PromptSections(
                leadContext: [],
                ambientNotes: ambientLines(excluding: nil),
                leadPlace: suppressingPlace,
                liveWorld: .application(suppressingName))
        }

        let hasCoding = live.contains { $0.discipline == .coding }
        let hasWriting = live.contains { $0.discipline == .writing }
        let leadDiscipline = lead(
            focus: focus, hasCoding: hasCoding, hasWriting: hasWriting,
            writingInPlay: writingInPlay, strictFocus: strictFocus)

        guard let owner = leadPlace(among: live, discipline: leadDiscipline) else {
            // NOTHING LEADS. Every live place still gets its line; what nobody
            // gets is the claim to be the work in front of the user.
            return PromptSections(
                leadContext: [],
                ambientNotes: ambientLines(excluding: nil),
                leadPlace: nil,
                liveWorld: .unled)
        }

        // A LEAD WITH NOTHING TO SHOW still leads — that is what a named but
        // closed application looks like — and it takes its own ambient line
        // with it rather than appearing twice.
        return PromptSections(
            leadContext: owner.full,
            ambientNotes: ambientLines(excluding: owner.place),
            leadPlace: owner.place,
            liveWorld: liveWorld(for: owner))
    }

    static func liveWorld(for contribution: Contribution) -> LiveWorkWorld {
        let name = AmbientApplicationIndexProvider.current
            .registration(id: contribution.place.memoryToken)?.displayName
        guard let whole = contribution.liveDocumentIsWhole else {
            return .application(name)
        }
        return .document(name: name, whole: whole)
    }
}
