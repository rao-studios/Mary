//
//  LiveWorkWorld.swift
//  MaryBrain
//
//  WHERE THE LIVE WORK CAME FROM — stated by the arbiter that decided it,
//  never inferred downstream.
//
//  THE BUG THIS TYPE EXISTS TO KILL, observed live: the user said "update this
//  document in chrome", and Mary answered "I'm looking at the live text in
//  front of you in Scrivener right now" — an application the user had not
//  named, about a document that was not there. The voice prompt picked its
//  place claim from a two-valued test standing in for a three-valued question,
//  reading a field that four of the arbiter's five return paths never assigned,
//  so it held its struct default. The invariant broke without the inference
//  being told.
//
//  ABSENCE IS A CASE, NOT AN `Optional`, and that is the whole defence: Swift
//  gives an optional `var` an implicit `nil` in the memberwise initializer, so
//  `liveWorld: LiveWorkWorld?` would silently default and reintroduce exactly
//  the forgettable field this type replaces. A case with no default cannot be
//  skipped, and `.unled` says out loud what a nil would have said quietly.
//
//  ONLY THREE CASES, because Mary has no compiled applications. The version
//  this is descended from carried `.coding` for Xcode and `.writing(WritingApp)`
//  for four named editors, and both were the same mistake in different
//  clothing: a closed enum of applications, which goes stale the moment
//  somebody installs a fifth. Here every application is named at runtime by
//  its registration, so an editor and an IDE reach this type the same way.
//
//  WHY `.corpus` IS STILL SEPARATE. It is not another application, it is a
//  different SIGHT CLAIM, and the voice can be heard making the wrong one:
//  `.application` holds DEPOSITS — what Mary has read — while `.corpus` holds
//  a live window onto one document. Telling a manuscript application that its
//  own open chapter is merely something Mary once read is wrong in a way the
//  user notices immediately.
//

import Foundation
import MaryAmbient

/// The place that produced this turn's live-work block, as the arbiter
/// resolved it.
public enum LiveWorkWorld: Sendable, Equatable {
    /// An application owns the turn, carrying the display name the user would
    /// use for it ("Chrome", "TextEdit"). Nil when the registration has no
    /// better word than its id — the voice then says "window" and names
    /// nothing, which is honest rather than wrong.
    case application(String?)
    /// A LIVE DOCUMENT is open and Mary is reading it — named, and saying
    /// whether she holds the WHOLE of it or a window onto part of it.
    ///
    /// `whole` decides the sight claim, and it is a fact about the CHANNEL
    /// rather than about any product: a prose surface that answers with the
    /// entire text holds the whole thing, and one that answers with the
    /// current outline item genuinely holds a window. Keying the claim on the
    /// property instead of on a list of application names is what stops the
    /// next whole-document place from silently inheriting the window hedge —
    /// which is the exact bug the arm this replaces was written to undo, and
    /// which a closed enum of applications re-created every time one was
    /// added.
    case document(name: String?, whole: Bool)
    /// NOTHING LEADS. No place contributed live work this turn — Mary may
    /// still hold facts and read passages, but she has no place to claim and
    /// must claim none. Distinct from `.application(nil)`, which is "something
    /// leads and I don't know its name".
    case unled

    /// Bridge from the pin vocabulary.
    ///
    /// The name comes from the registration, and nil is the honest answer when
    /// the roster has not caught up with the pin yet.
    public init(_ pinned: PinnedWorld) {
        self = .application(
            AmbientApplicationIndexProvider.current
                .registration(id: pinned.applicationID)?.displayName)
    }
}
