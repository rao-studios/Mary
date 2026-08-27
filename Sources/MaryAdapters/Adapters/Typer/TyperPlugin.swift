//
//  TyperPlugin.swift
//  MaryBrain
//
//  The writing hands: types prose at the user's cursor via the KeyboardTyper
//  engine. Reader plugins (Scrivener, Pages) open and reference documents;
//  when the user wants words on the page, this types them — where the caret
//  is, in the app they're looking at.
//
//  Any ordinary text surface is a target. App plugins enrich the context and
//  offer their own document Skills, but they do not gate the keyboard Ability.
//  Code and terminal surfaces are NEVER typed: code edits go through
//  delegate_coding, and terminal input could execute a command.
//
//  Concurrency posture:
//  - The typing loop runs INLINE in the binding closure: long prose blows the
//    250ms lane grace and detaches into the routine machinery, so a bare
//    "stop" cancels the routine task, which the typer checks every chunk.
//  - It holds THE STAGE (StageArbiter) while typing: a stage-claiming binding
//    from a parallel turn (open_music, a Scrivener ceremony) PREEMPTS it —
//    typing pauses resumably instead of dying to a focus steal. Background
//    actions (delegate_coding, git, playback) share nothing and run freely.
//  - A pause (preemption or the user switching apps) saves the untyped
//    remainder AND its target in TypingSession; resume_typing picks up
//    exactly there, in the right app.
//

import AppKit
import Foundation
import os

public struct TyperPlugin: MaryAdapter {
    public let name = "typer"
    public let summary = "Type prose at the user's cursor."

    public init() {
        // THE FIVE PASSAGE VERBS ARE REGISTERED EXCLUSIVELY BY THIS PLUGIN,
        // so any process that can dispatch them has — by construction —
        // installed the world→backing resolver they route through. Without
        // this, a process that assembled TyperPlugin without touching
        // MaryAdapterCatalog dispatched into a nil resolver and every edit
        // refused with "I can't work with passages there yet."
        _ = PassageRecipes.hasBackingResolver
    }

    /// The hands, described as the ACT they perform. The old line said only
    /// "type_at_cursor TYPES prose at the user's cursor" — true, and read
    /// alongside a doctrine that banned replacing text it meant "the caret is
    /// the only way to write anything", which is how "replace the Purpose
    /// section" landed at the caret with the Purpose section untouched. The
    /// paradigm itself is stated once, with the roster, in
    /// `BonniePrompts.system`; this says which half of it these hands are.
    public var promptFragment: String? {
        """
        The Writing Ability's type_at_cursor Skill writes prose in any ordinary \
        text surface. replace_selection changes only the user's live highlight. \
        App adapters add context, not limits. Use passage Skills for named \
        passages. Never type code or terminal commands. Adapter names are not \
        callable Skill names.
        """
    }

    /// FETCH-FIRST'S ENTRY POINT, and the slot key for a passage read.
    ///
    /// It is declared for the SECOND of those two jobs. `AbilityRuntime
    /// .readPhrase` uses this parameter name to key the ambient fact a read
    /// registers, and without it a `find_passage` would key on the RECIPE NAME
    /// — so every passage the user ever asked for would supersede the last one
    /// and the prompt would call it "the part about find_passage". `target` is
    /// the phrase they actually used, which is exactly what that slot means
    /// everywhere else.
    ///
    /// The pre-read never routes here in practice: `focusProvider` answers with
    /// a WORKSPACE owner, and `typer` is `.service`. If it ever did, the call
    /// would be correct anyway — `find_passage` reads a named part of whatever
    /// the user is working in, which is what this property promises.
    public var targetedRead: (binding: String, parameter: String)? {
        ("find_passage", "target")
    }

}
/// The paused passage — one slot, newest wins. Saved on pause/lostFocus with
/// its TARGET (resume must type into the same app), consumed by
/// resume_typing, cleared by "stop" and by a fresh passage.
final class TypingSession: @unchecked Sendable {

    /// Answers `PausedTypingSession.clear()` for the reasoning core, which must
    /// be able to forget a superseded write without naming this type.
    static let installClearHook: Void = {
        PausedTypingSession.installClear { TypingSession.shared.clear() }
    }()

    static let shared = TypingSession()

    private let box = OSAllocatedUnfairLock<(remainder: String, target: TypingSurface)?>(initialState: nil)

    func save(remainder: String, target: TypingSurface) {
        box.withLock { $0 = (remainder, target) }
    }

    func take() -> (remainder: String, target: TypingSurface)? {
        box.withLock { value -> (remainder: String, target: TypingSurface)? in
            defer { value = nil }
            return value
        }
    }

    var hasRemainder: Bool { box.withLock { $0 != nil } }

    func clear() {
        box.withLock { $0 = nil }
    }
}
