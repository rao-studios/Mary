//
//  TyperPlugin.swift
//  MaryBrain
//
//  WHAT: Type prose at the user's cursor via KeyboardTyper.
//  IN:   TyperPlugin+Typing / KeyboardTyper / StageArbiter
//  OUT:  TypingSession / PassageRecipes / PausedTypingSession
//  PIN:  Ordinary text surfaces only — never code or terminal.
//        Loop runs inline; holds the stage; pause saves remainder + target.
//

import AppKit
import Foundation
import os

public struct TyperPlugin: MaryAdapter {
    public let name = "typer"
    public let summary = "Type prose at the user's cursor."

    public init() {
        // Passage verbs register here, so any dispatcher has the world→backing resolver.
        _ = PassageRecipes.hasBackingResolver
    }

    /// Which half of writing these hands are: caret compose, not named-passage revise.
    public var promptFragment: String? {
        """
        The Writing Ability's type_at_cursor Skill writes prose in any ordinary \
        text surface. replace_selection changes only the user's live highlight. \
        App adapters add context, not limits. Use passage Skills for named \
        passages. Never type code or terminal commands. Adapter names are not \
        callable Skill names.
        """
    }

    /// Fetch-first slot key for a passage read. PIN: AbilityRuntime.readPhrase
    /// keys the ambient fact on this parameter, not the recipe name.
    public var targetedRead: (binding: String, parameter: String)? {
        ("find_passage", "target")
    }

}
/// Paused passage — one slot, newest wins. Saved with its target; resume_typing consumes it.
final class TypingSession: @unchecked Sendable {

    /// Answers PausedTypingSession.clear() without the core naming this type.
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
