//
//  TypingMode.swift
//
//  How a typing verb should treat what is already there. Named by the
//  runtime when it fills in a caret-write argument, so it is contract.
//

import Foundation

/// How the text at the live writing surface should change.
public enum TypingMode: String, Sendable {
    case compose
    case replaceSelection = "replace_selection"
}
