//
//  ContentUndoStore.swift
//  MaryBrain
//
//  A reusable, plugin-agnostic "prior content" store with hash-guarded
//  revert semantics: record what a document looked like before an edit, and
//  only hand it back if the current content still matches what the edit
//  produced (the user hasn't worked on top of it since).
//
//  The Xcode peer-coder records into it during direct-mode edits; its spoken
//  undo story is git. Content-app plugins WITHOUT version control underneath
//  (Scrivener-class writing Skills, Notes) build their own revert Skills on
//  this store — that's why it lives in Shared/.
//

import CryptoKit
import Foundation
import os

public struct ContentUndoEntry: Sendable {
    public var priorContent: String
    public var priorHash: String
    public var appliedHash: String
}

public final class ContentUndoStore: Sendable {

    private let box = OSAllocatedUnfairLock<[String: ContentUndoEntry]>(initialState: [:])

    public init() {}

    public static func hash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Remember what `key` (a path, a document id) held before an edit.
    public func record(key: String, prior: String, applied: String) {
        box.withLock {
            $0[key] = ContentUndoEntry(
                priorContent: prior,
                priorHash: Self.hash(prior),
                appliedHash: Self.hash(applied))
        }
    }

    /// The prior content — but ONLY if the current content still matches the
    /// applied edit (hash guard: never clobber work done since). Consumes the
    /// entry on success.
    public func take(for key: String, currentHash: String) -> String? {
        box.withLock { entries in
            guard let entry = entries[key], entry.appliedHash == currentHash else { return nil }
            entries[key] = nil
            return entry.priorContent
        }
    }

    /// Peek without consuming (for honest "I can't undo" messages).
    public func entry(for key: String) -> ContentUndoEntry? {
        box.withLock { $0[key] }
    }

    public func clear(key: String) {
        box.withLock { $0[key] = nil }
    }
}
