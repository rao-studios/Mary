//
//  TypingMode.swift
//  MaryPlugin
//
//  WHAT: How a typing verb treats what is already there.
//  IN:   runtime (fills a caret-write argument)
//  OUT:  TyperPlugin
//

import Foundation

/// Compose at the caret, or replace the live selection.
public enum TypingMode: String, Sendable {
    case compose
    case replaceSelection = "replace_selection"
}
