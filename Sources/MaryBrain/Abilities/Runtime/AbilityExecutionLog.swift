//
//  AbilityExecutionLog.swift
//  MaryBrain
//
//  The session's Ability execution ledger: every REAL execution — binding, primitive
//  script, delegate-coding completion — lands here exactly once, with the
//  target it acted on and how it went. The Home header's log sheet reads it
//  to debug silent action turns and to offer conversational undo. In-memory
//  and session-scoped by design; the totem archive is the durable record.
//

import Foundation

/// One executed Skill: what ran, who owned it, what it touched, how it went.
public struct AbilityExecutionRecord: Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    /// The machine binding name that ran, e.g. "move_binder_item".
    public let skillName: String
    /// Frozen schema identity; nil only for execution predating or outside an
    /// Ability package.
    public let reference: AbilitySkillReference?
    /// The owning plugin id ("scrivener", "music", …); "mac" for primitives.
    public let owner: String
    /// What it acted on, derived from the arguments (document, song, path…).
    public let target: String?
    public let ok: Bool
    public let summary: String
    /// True when the action was of a mutating kind — pure reads never are.
    /// The sheet offers Undo only on rows that are undoable AND ok.
    public let undoable: Bool
    /// `SkillOutcome.foundNothing`, carried the last hop so the ROW can say
    /// what the outcome already said: the binding looked, and what was asked for
    /// is not in what it can read.
    ///
    /// THE FAILURE THIS FIXES: `find_passage` on a searched-and-missed read
    /// answers `ok: true, foundNothing: true`, which is CORRECT — `ok: false`
    /// would make the turn speak the miss aloud as a breakage and invite the
    /// orchestrator to retry a read that already ran. The CHIP was the wrong
    /// part: it rendered the miss green, identical to a passage found and
    /// changed, so the one row a person opens the log to understand looked like
    /// the one row that needed no explaining. `ok` alone cannot tell them
    /// apart, because both are `ok`.
    public let foundNothing: Bool
    /// The raw arguments, JSON-encoded — the debug detail.
    public let argumentsJSON: String?
    /// WHICH CONTAINER THIS ACTION TOUCHED, in that world's own key terms.
    ///
    /// Defaulted, following the precedent `foundNothing` set: every existing
    /// construction site keeps compiling. It exists so "the note you just
    /// changed" is answerable — `target` is a raw argument VALUE with no world
    /// and no identity attached, which is why nothing could ever resolve
    /// against it.
    public let containerKey: String?

    /// Spelled out rather than left to the memberwise synthesis, so
    /// `foundNothing` can carry a default: every existing construction site —
    /// and every test built around one — keeps compiling and keeps meaning
    /// exactly what it meant, which is "this row is not a miss".
    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        skillName: String,
        reference: AbilitySkillReference? = nil,
        owner: String,
        target: String?,
        ok: Bool,
        summary: String,
        undoable: Bool,
        foundNothing: Bool = false,
        argumentsJSON: String? = nil,
        containerKey: String? = nil
    ) {
        self.id = id
        self.date = date
        self.skillName = skillName
        self.reference = reference
        self.owner = owner
        self.target = target
        self.ok = ok
        self.summary = summary
        self.undoable = undoable
        self.foundNothing = foundNothing
        self.argumentsJSON = argumentsJSON
        self.containerKey = containerKey
    }
}

/// Lock-boxed ring buffer, newest first. `.shared` is what the app reads;
/// tests inject their own so parallel suites never share state.
public final class AbilityExecutionLog: @unchecked Sendable {

    public static let shared = AbilityExecutionLog()

    private let lock = NSLock()
    private var buffer: [AbilityExecutionRecord] = []
    private let capacity: Int

    public init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    public func record(
        skillName: String,
        reference: AbilitySkillReference? = nil,
        owner: String,
        target: String?,
        ok: Bool,
        summary: String,
        undoable: Bool,
        foundNothing: Bool = false,
        argumentsJSON: String? = nil,
        containerKey: String? = nil
    ) {
        let record = AbilityExecutionRecord(
            id: UUID(), date: Date(), skillName: skillName,
            reference: reference, owner: owner,
            target: target, ok: ok, summary: summary,
            undoable: undoable, foundNothing: foundNothing,
            argumentsJSON: argumentsJSON,
            containerKey: containerKey)
        lock.lock()
        defer { lock.unlock() }
        buffer.insert(record, at: 0)
        if buffer.count > capacity {
            buffer.removeLast(buffer.count - capacity)
        }
    }

    /// Newest first.
    public func entries() -> [AbilityExecutionRecord] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll()
    }

    /// The argument keys the binding roster actually uses to name its object,
    /// in preference order — first present wins.
    private static let targetKeys = [
        "document", "file", "path", "project", "playlist", "song",
        "title", "folder", "destination", "album", "query", "name", "purpose",
    ]

    /// Derive the human "what it acted on" from a binding's arguments.
    public static func target(from arguments: [String: String]) -> String? {
        for key in targetKeys {
            if let value = arguments[key], !value.isEmpty { return value }
        }
        return nil
    }
}
